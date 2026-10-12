import Foundation
import Security
import LocalAuthentication
import Darwin

// Private pipe protocol for the signed Relay credential helper. The caller must
// never copy the read response into a host job, terminal, log or RPC response.
let service = "dev.relay.terminal.capsule"
func reply(_ value: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}
func fail(_ code: String) -> Never {
    reply(["v": 1, "status": "failed", "code": code])
    exit(1)
}
let raw = (try? FileHandle.standardInput.read(upToCount: 4097)) ?? Data()
guard raw.count <= 4096,
      let input = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
      Set(input.keys).isSubset(of: ["v", "operation", "reference", "secret"]),
      (input["v"] as? Int) == 1,
      let operation = input["operation"] as? String,
      ["save", "read", "status", "delete"].contains(operation),
      let reference = input["reference"] as? String,
      reference.range(of: #"^[a-f0-9]{32}$"#, options: .regularExpression) != nil,
      (operation == "save") == (input["secret"] != nil) else {
    fail("invalid_credential_request")
}
let authentication = LAContext()
authentication.interactionNotAllowed = true
var query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: reference,
    kSecUseAuthenticationContext as String: authentication
]
switch operation {
case "save":
    guard let secret = input["secret"] as? String, (16...512).contains(secret.utf8.count),
          secret.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { fail("invalid_api_credential") }
    query[kSecAttrLabel as String] = "Relay Anthropic API"
    query[kSecValueData as String] = Data(secret.utf8)
    // New immutable references make an uncertain save discoverable without
    // updating another account's key. Keychain provides encrypted persistence.
    let result = SecItemAdd(query as CFDictionary, nil)
    guard result == errSecSuccess else {
        fail(result == errSecDuplicateItem ? "credential_reference_exists" : "keychain_locked_or_unavailable")
    }
    reply(["v": 1, "status": "saved", "reference": reference, "storage": "macos_keychain"])
case "read", "status":
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[(operation == "read" ? kSecReturnData : kSecReturnAttributes) as String] = true
    var value: CFTypeRef?
    let result = SecItemCopyMatching(query as CFDictionary, &value)
    guard result == errSecSuccess else {
        if operation == "status" && result == errSecItemNotFound {
            reply(["v": 1, "status": "missing", "reference": reference, "storage": "macos_keychain"])
            exit(0)
        }
        fail("keychain_locked_or_missing")
    }
    if operation == "read" {
        guard let data = value as? Data, (16...512).contains(data.count) else { fail("invalid_api_credential") }
        FileHandle.standardOutput.write(data)
    } else {
        reply(["v": 1, "status": "saved", "reference": reference, "storage": "macos_keychain"])
    }
case "delete":
    let result = SecItemDelete(query as CFDictionary)
    guard result == errSecSuccess || result == errSecItemNotFound else { fail("keychain_locked_or_unavailable") }
    reply(["v": 1, "status": "deleted", "reference": reference, "storage": "macos_keychain"])
default: fail("invalid_credential_request")
}
