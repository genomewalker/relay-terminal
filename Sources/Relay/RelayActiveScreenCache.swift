import Foundation
import GhosttyTerminal

/// Reuses the last serialized active screen while the native screen is
/// provably unchanged, so repeated prompt checks read memory instead of
/// running libghostty's write_screen_file action (a temporary file, then
/// unlink and rmdir) each time.
///
/// libghostty has no in-memory read that keeps cell attributes:
/// `ghostty_surface_read_text` returns plain text, and the prompt parser
/// needs the native faint style (RelayAgentMaintenancePrompt). The serialized
/// screen therefore still comes from the file action on a miss.
///
/// Every read, hit or miss, takes a fresh in-memory sample: screen state,
/// plain rows, screen state again. The sample is stable only when both
/// states are equal and neither has a screen mutation in flight. A screen is
/// returned only when the sample before the dump is stable, the dump
/// succeeds, and the sample after the dump is stable and equal to it (on a
/// hit, the fresh sample must equal the stored key). Anything else is
/// `.unstable`, which callers treat as a refusal: it never falls through to a
/// weaker proof. `.noSurface` means no native surface is attached; only then
/// may a caller use the hidden-pane replay proof.
///
/// The dump is not taken under the same lock as the samples. Stability is
/// inferred from libghostty's mutation counter and in-flight flag (which this
/// patch adds to the vendored session) and from the plain rows, which cover
/// binding actions and reflow that the counter does not count.
struct RelayActiveScreenCache {
    struct Key: Equatable, Sendable {
        let state: InMemoryTerminalScreenState
        let rows: [String]
    }

    enum Sample: Equatable {
        case noSurface
        case unstable
        case stable(Key)
    }

    enum Observation: Equatable {
        case noSurface
        case unstable
        case screen(String, Key)

        var screen: String? {
            if case .screen(let screen, _) = self { return screen }
            return nil
        }

        var key: Key? {
            if case .screen(_, let key) = self { return key }
            return nil
        }
    }

    private(set) var entry: (key: Key, screen: String)?
    private(set) var dumps = 0

    /// State, rows, state. A surface that disappears after the first state,
    /// rows that cannot be read, or any state change between the two reads
    /// make the sample unstable.
    static func sample(state: () -> InMemoryTerminalScreenState?, rows: () -> [String]?) -> Sample {
        guard let first = state() else { return .noSurface }
        guard !first.mutationInFlight, let rows = rows(), let second = state(), second == first else {
            return .unstable
        }
        return .stable(Key(state: first, rows: rows))
    }

    mutating func read(sample: () -> Sample, dump: () -> String?) -> Observation {
        let before = sample()
        guard case .stable(let key) = before else {
            entry = nil
            return before == .noSurface ? .noSurface : .unstable
        }
        if let entry, entry.key == key { return .screen(entry.screen, key) }
        dumps += 1
        guard let screen = dump(), sample() == .stable(key) else {
            entry = nil
            return .unstable
        }
        entry = (key, screen)
        return .screen(screen, key)
    }

    mutating func invalidate() { entry = nil }
}

extension InMemoryTerminalSession {
    /// A state, rows, state sample of this session's screen, read in memory.
    /// Safe off the main actor: both reads hold the surface alive.
    func activeScreenSample() -> RelayActiveScreenCache.Sample {
        RelayActiveScreenCache.sample(state: { screenState }, rows: { readViewportRows() })
    }
}
