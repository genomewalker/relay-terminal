import Foundation
import Testing
@testable import Relay
@Test func wireFragmentsAssembleWithoutExposingPartialData() throws {
    var assembler = RelayWireFragmentAssembler(); assembler.enabled = true
    let first = RelayWireFragmentAssembler.frame(id: 1, kind: .hostResponse, total: 6, offset: 0, chunk: Data("abc".utf8))
    #expect(try assembler.accept(first) == nil)
    let pulse = try assembler.accept(.init(type: .pong, payload: Data("pulse".utf8)))
    #expect(pulse?.type == .pong)
    let second = RelayWireFragmentAssembler.frame(id: 1, kind: .hostResponse, total: 6, offset: 3, chunk: Data("def".utf8))
    let complete = try assembler.accept(second)
    #expect(complete?.payload == Data("abcdef".utf8))
    #expect(throws: (any Error).self) { try assembler.accept(first) }
}
@Test func wireFragmentsRejectUnnegotiatedAndDiscontinuousFrames() throws {
    var assembler = RelayWireFragmentAssembler()
    let frame = RelayWireFragmentAssembler.frame(id: 1, kind: .output, total: 6, offset: 1, chunk: Data("abc".utf8))
    #expect(throws: (any Error).self) { try assembler.accept(frame) }
    assembler.enabled = true
    #expect(throws: (any Error).self) { try assembler.accept(frame) }
}
