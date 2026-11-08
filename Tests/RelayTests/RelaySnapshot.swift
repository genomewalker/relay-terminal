import AppKit
import SwiftUI
@testable import Relay

/// Offscreen render of a SwiftUI view for review without installing the app.
/// Writes `<name>-<dark|light>.png` into `RELAY_SNAPSHOT_DIR` when it is set.
@MainActor enum RelaySnapshot {
    struct Result { let size: NSSize; let bitmap: NSBitmapImageRep }

    static func render<V: View>(_ view: V, name: String, width: CGFloat,
                                appearance: NSAppearance.Name) throws -> Result {
        let host = NSHostingView(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true)
            .background(RelayTheme.canvas))
        host.appearance = NSAppearance(named: appearance)
        let fitting = host.fittingSize
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: max(fitting.height, 1)))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["RELAY_SNAPSHOT_DIR"], !dir.isEmpty,
           let png = rep.representation(using: .png, properties: [:]) {
            let suffix = appearance == .darkAqua ? "dark" : "light"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(suffix).png"))
        }
        return Result(size: host.bounds.size, bitmap: rep)
    }
}
