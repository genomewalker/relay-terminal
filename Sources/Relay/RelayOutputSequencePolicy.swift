import Foundation

/// Durable output records are delivered once, in sequence order. Sequence zero
/// is reserved for worker presentation/mode state and never advances the cursor.
/// A worker's explicit outputReset must reset the cursor before new records.
enum RelayOutputSequencePolicy {
    static func accepts(_ sequence: UInt64, after cursor: UInt64) -> Bool {
        sequence == 0 || sequence > cursor
    }
}
