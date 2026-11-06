import CryptoKit
import Foundation

/// How the input behind one submit was produced. A count-only signal: Relay
/// never keeps the keystrokes, the paste or the prompt text.
enum RelayPromptInputClass: String, Codable, Sendable {
    /// Desktop keystrokes roughly account for what was submitted.
    case typed
    /// Bracketed or clipboard paste supplied most of the submitted input.
    case pasted
    /// Little or nothing was typed or pasted: an accepted suggestion, an
    /// Enter on a ghost suggestion, or an Enter on a menu choice.
    case suggestionLikely = "suggestion_likely"
    /// Written by relay_send_command, Miko, a pane message, an approved input
    /// request or another Relay automation path. Never user-typed.
    case programmatic
    /// A provider reported a submit Relay's desktop input did not see.
    case unknown
}

/// Per-pane counters since the last submit. Counts only.
struct RelayPromptInputCounts: Codable, Equatable, Sendable {
    var printable = 0
    var pasteBytes = 0
    var tab = 0
    var rightArrow = 0
    var enter = 0
    var delete = 0

    enum CodingKeys: String, CodingKey {
        case printable, delete, tab, enter
        case pasteBytes = "paste_bytes"
        case rightArrow = "right_arrow"
    }

    var acceptedSuggestion: Bool { tab + rightArrow > 0 }
}

/// One submit, recorded without content: counts, a length and at most a
/// 12-hex-digit SHA-256 prefix of the submitted text.
struct RelayPromptSubmitRecord: Codable, Equatable, Sendable {
    var inputClass: RelayPromptInputClass
    /// "strong" only for plainly typed input; everything else is weak intent.
    var intent: String
    var counts: RelayPromptInputCounts
    var suggestionAccepted: Bool
    var submittedLength: Int?
    /// "provider" (the agent's own prompt record), "visible_input" (Relay's
    /// mirror of the input line) or "programmatic_request".
    var lengthSource: String?
    var promptSource: String?
    var promptSHA256Prefix: String?
    var programmaticSource: String?
    var submittedAt: Date
    var providerReportedAt: Date?

    enum CodingKeys: String, CodingKey {
        case intent, counts
        case inputClass = "class"
        case suggestionAccepted = "suggestion_accepted"
        case submittedLength = "submitted_length"
        case lengthSource = "length_source"
        case promptSource = "provider_prompt_source"
        case promptSHA256Prefix = "prompt_sha256_prefix"
        case programmaticSource = "programmatic_source"
        case submittedAt = "submitted_at"
        case providerReportedAt = "provider_reported_at"
    }
}

/// Content-free fingerprint of a prompt. The text is hashed and dropped.
struct RelayPromptFingerprint: Equatable, Sendable {
    static let prefixLength = 12
    let length: Int
    let sha256Prefix: String

    init(_ text: String) {
        length = text.count
        sha256Prefix = String(Self.hexDigest(text).prefix(Self.prefixLength))
    }

    static func hexDigest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Counts what reached one pane's input since the last submit and classifies
/// each submit. Holds only integers, a class, timestamps and hash prefixes.
struct RelayPromptProvenanceLog: Sendable {
    static let historyLimit = 20
    /// A provider prompt report this soon after a submit belongs to it.
    static let providerMatchWindow: TimeInterval = 60
    static let promptSourcePattern = #"^[A-Za-z0-9_.:-]{1,32}$"#

    private(set) var pending = RelayPromptInputCounts()
    private(set) var history: [RelayPromptSubmitRecord] = []
    private(set) var programmaticDepth = 0
    private var lastPasteEvent: TimeInterval?

    var latest: RelayPromptSubmitRecord? { history.last }

    // MARK: Desktop input (user keystrokes reaching the pane)

    /// Characters that are not control characters (Tab, Return and escapes
    /// are counted as keys, not text).
    static func printableCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + (CharacterSet.controlCharacters.contains($1) ? 0 : 1) }
    }

    mutating func printable(_ characters: Int) {
        guard programmaticDepth == 0, characters > 0 else { return }
        pending.printable &+= characters
    }

    /// One user paste. `event` is the NSEvent timestamp, so the key-equivalent
    /// path and the menu action for the same Cmd+V count once.
    mutating func paste(bytes: Int, event: TimeInterval?) {
        guard programmaticDepth == 0, bytes > 0 else { return }
        if let event, event == lastPasteEvent { return }
        lastPasteEvent = event
        pending.pasteBytes &+= bytes
    }

    mutating func tab() { if programmaticDepth == 0 { pending.tab &+= 1 } }
    mutating func rightArrow() { if programmaticDepth == 0 { pending.rightArrow &+= 1 } }
    mutating func delete() { if programmaticDepth == 0 { pending.delete &+= 1 } }

    /// The Enter that submits the input line. `visible` is Relay's own mirror
    /// of the line when it is reliable; it is reduced to a fingerprint here.
    @discardableResult
    mutating func userSubmit(visible: RelayPromptFingerprint?, at date: Date = Date()) -> RelayPromptSubmitRecord? {
        guard programmaticDepth == 0 else { return nil }
        var counts = pending
        counts.enter &+= 1
        let length = visible.flatMap { $0.length > 0 ? $0.length : nil }
        let verdict = Self.classify(counts, submittedLength: length)
        let record = RelayPromptSubmitRecord(inputClass: verdict.inputClass, intent: verdict.intent, counts: counts,
            suggestionAccepted: verdict.suggestionAccepted, submittedLength: length,
            lengthSource: length == nil ? nil : "visible_input", promptSource: nil,
            promptSHA256Prefix: length == nil ? nil : visible?.sha256Prefix,
            programmaticSource: nil, submittedAt: date, providerReportedAt: nil)
        append(record)
        return record
    }

    // MARK: Programmatic input

    /// Marks a Relay automation write in progress; desktop counting pauses so
    /// automation can never be credited as typing.
    mutating func beginProgrammatic() { programmaticDepth &+= 1 }
    mutating func endProgrammatic() { programmaticDepth = max(0, programmaticDepth - 1) }

    /// A Relay automation path delivered input to this pane.
    mutating func programmaticSubmit(source: String, fingerprint: RelayPromptFingerprint?, at date: Date = Date()) {
        // A provider report that arrived first, while the write was in flight.
        if var last = history.last, last.programmaticSource == nil, last.inputClass == .programmatic,
           date.timeIntervalSince(last.submittedAt) <= Self.providerMatchWindow {
            last.programmaticSource = source
            history[history.count - 1] = last
            return
        }
        let counts = pending
        pending = RelayPromptInputCounts()
        append(RelayPromptSubmitRecord(inputClass: .programmatic, intent: "weak", counts: counts,
            suggestionAccepted: false, submittedLength: fingerprint?.length,
            lengthSource: fingerprint == nil ? nil : "programmatic_request", promptSource: nil,
            promptSHA256Prefix: fingerprint?.sha256Prefix, programmaticSource: source,
            submittedAt: date, providerReportedAt: nil))
    }

    // MARK: Provider evidence

    /// The agent's own record of a submitted prompt (Claude's UserPromptSubmit
    /// hook). The length replaces the visible-line estimate and reclassifies a
    /// desktop submit; it never upgrades a programmatic one.
    mutating func providerPrompt(_ fingerprint: RelayPromptFingerprint, promptSource: String?, at date: Date = Date()) {
        let source = promptSource.flatMap {
            $0.range(of: Self.promptSourcePattern, options: .regularExpression) == nil ? nil : $0
        }
        // While automation is writing, a report belongs to the automation and
        // must not lend a provider length to an earlier desktop submit.
        if var last = history.last, last.providerReportedAt == nil,
           programmaticDepth == 0 || last.inputClass == .programmatic,
           date.timeIntervalSince(last.submittedAt) <= Self.providerMatchWindow,
           date.timeIntervalSince(last.submittedAt) >= -1 {
            last.providerReportedAt = date
            last.promptSource = source
            last.submittedLength = fingerprint.length
            last.lengthSource = "provider"
            last.promptSHA256Prefix = fingerprint.sha256Prefix
            if last.inputClass != .programmatic {
                let verdict = Self.classify(last.counts, submittedLength: fingerprint.length)
                last.inputClass = verdict.inputClass
                last.intent = verdict.intent
                last.suggestionAccepted = verdict.suggestionAccepted
            }
            history[history.count - 1] = last
            return
        }
        // No desktop Enter preceded it: a delivery outside Relay's key path.
        let counts = pending
        pending = RelayPromptInputCounts()
        append(RelayPromptSubmitRecord(inputClass: programmaticDepth > 0 ? .programmatic : .unknown, intent: "weak",
            counts: counts, suggestionAccepted: false, submittedLength: fingerprint.length, lengthSource: "provider",
            promptSource: source, promptSHA256Prefix: fingerprint.sha256Prefix, programmaticSource: nil,
            submittedAt: date, providerReportedAt: date))
    }

    /// A pane-message receipt that does not rule out delivery. Uncertain
    /// outcomes count: input that may have arrived is not typing.
    static func messageMayHaveReachedPane(_ receipt: [String: Any]) -> Bool {
        if receipt["delivered"] as? Bool == false { return false }
        if let status = receipt["status"] as? String, status.hasPrefix("rejected") { return false }
        return true
    }

    // MARK: Classification

    struct Verdict: Equatable {
        let inputClass: RelayPromptInputClass
        let intent: String
        let suggestionAccepted: Bool
    }

    /// Classifies desktop input. `submittedLength` is the provider's length
    /// when known, otherwise the visible line, otherwise nil.
    static func classify(_ counts: RelayPromptInputCounts, submittedLength: Int?) -> Verdict {
        let human = counts.printable + counts.pasteBytes
        let accepted = counts.acceptedSuggestion
        guard human > 0 else {
            // Enter or Tab/Right-arrow alone: whatever was submitted, nobody typed it.
            return Verdict(inputClass: .suggestionLikely, intent: "weak", suggestionAccepted: accepted || (submittedLength ?? 0) > 0)
        }
        if let length = submittedLength, length > 2 * human, length - human >= 8 {
            // Far more was submitted than was typed or pasted. With a typed edit
            // on top of an accepted suggestion it is an edited suggestion.
            if accepted, counts.printable > 0 {
                return Verdict(inputClass: .typed, intent: "weak", suggestionAccepted: true)
            }
            return Verdict(inputClass: .suggestionLikely, intent: "weak", suggestionAccepted: true)
        }
        if counts.pasteBytes > counts.printable {
            return Verdict(inputClass: .pasted, intent: "weak", suggestionAccepted: accepted)
        }
        return Verdict(inputClass: .typed, intent: accepted ? "weak" : "strong", suggestionAccepted: accepted)
    }

    private mutating func append(_ record: RelayPromptSubmitRecord) {
        pending = RelayPromptInputCounts()
        lastPasteEvent = nil
        history.append(record)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
    }

    // MARK: Read-only exposure

    static let rule = "Classes describe how input reached the pane, from counts only; Relay stores no keystrokes, " +
        "paste or prompt text. An approval whose submit is suggestion_likely, pasted, programmatic or unknown, " +
        "or has intent weak, is weak intent: confirm with newly typed text before install, delete, kill, restart " +
        "or relaying an approval. Known limit: typed means desktop key events reached Relay's window; key events " +
        "synthesized by computer use or other automation look the same, so typed does not prove a person pressed the keys."

    struct Snapshot: Encodable {
        let paneID: String
        let latest: RelayPromptSubmitRecord?
        let history: [RelayPromptSubmitRecord]
        let pending: RelayPromptInputCounts
        let historyLimit: Int
        let contentStored: Bool
        let rule: String
        enum CodingKeys: String, CodingKey {
            case latest, history, pending, rule
            case paneID = "pane_id"
            case historyLimit = "history_limit"
            case contentStored = "content_stored"
        }
    }

    func snapshot(paneID: UUID) -> Snapshot {
        Snapshot(paneID: paneID.uuidString.lowercased(), latest: latest, history: history.reversed(), pending: pending,
                 historyLimit: Self.historyLimit, contentStored: false, rule: Self.rule)
    }
}
