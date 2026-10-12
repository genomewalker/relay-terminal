import Foundation
import Testing
@testable import Relay

@MainActor
@Test("Adding a pane preserves every existing divider proportion")
func splittingPreservesExistingProportions() {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    let outer = UUID(), inner = UUID()
    let tab = TabModel(name: "Split test", firstPane: a)
    tab.layout = .split(id: outer, axis: .horizontal, first: .pane(a),
                        second: .split(id: inner, axis: .vertical, first: .pane(b), second: .pane(c)))
    tab.splitRatios = [outer: 0.73, inner: 0.31]
    tab.layout = tab.layout.splitting(b, axis: .horizontal, with: d)
    tab.reconcileSplitRatios()
    #expect(tab.splitRatios[outer] == 0.73)
    #expect(tab.splitRatios[inner] == 0.31)
    #expect(tab.splitRatios.count == 3)
    #expect(tab.splitRatios.filter { $0.key != outer && $0.key != inner }.values.first == 0.5)
    tab.layout = tab.layout.removing(d)!
    tab.reconcileSplitRatios()
    #expect(tab.splitRatios == [outer: 0.73, inner: 0.31])
    tab.balanceSplits()
    #expect(tab.splitRatios[outer] == 1.0 / 3.0)
    #expect(tab.splitRatios[inner] == 0.5)
}

@MainActor
@Test("Ratio reconciliation removes obsolete dividers and repairs invalid values")
func splitRatioReconciliationIsBounded() {
    let a = UUID(), b = UUID(), split = UUID(), obsolete = UUID()
    let tab = TabModel(name: "Ratio test", firstPane: a)
    tab.layout = .split(id: split, axis: .vertical, first: .pane(a), second: .pane(b))
    tab.splitRatios = [split: .nan, obsolete: 0.25]
    tab.reconcileSplitRatios()
    #expect(tab.splitRatios == [split: 0.5])
}
