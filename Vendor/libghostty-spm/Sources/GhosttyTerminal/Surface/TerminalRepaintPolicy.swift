//
//  TerminalRepaintPolicy.swift
//  libghostty-spm
//
//  The repaint contract: output repaints exactly the rows it changed, and
//  every change of size, scale, scroll position, replay or visibility
//  repaints the whole viewport. See docs/TERMINAL-REPAINT-CONTRACT.md.
//

import Foundation

/// Why a whole-viewport repaint was requested.
public enum TerminalRepaintReason: String, Sendable, CaseIterable {
    case size
    case scale
    case scroll
    case replay
    case visibility
    case attach
    case inspection
    /// The self-heal after output goes quiet (or every few seconds under
    /// continuous output). It repairs a row whose damage was never reported.
    case settle
}

/// Pure decisions of the repaint contract, kept free of the surface so they
/// can be tested directly.
public enum TerminalRepaintPolicy {
    /// Quiet time after the last damage before one full rebuild.
    public static let settleDelay: TimeInterval = 0.3
    /// Under continuous damage, the longest stretch without a full rebuild.
    public static let maximumIntervalUnderDamage: TimeInterval = 2.0
    /// A size or scale change is repainted again after this delay, once the
    /// resize throttle's trailing size has landed.
    public static let trailingDelay: TimeInterval = 0.15
    /// Requests closer together than this share one rebuild.
    public static let coalesceInterval: TimeInterval = 1.0 / 120.0
    /// Damage this soon after a full rebuild may be that rebuild's own render
    /// requests coming back, so it does not schedule another settle: the
    /// settle can then never feed itself. Real output inside the window is
    /// still drawn; only its heal waits for the next damage or the overdue
    /// interval.
    public static let echoWindow: TimeInterval = 0.5

    public enum Action: Equatable, Sendable {
        /// Mark the viewport fully dirty now.
        case apply
        /// Keep it owed: the pane cannot draw, or an IME composition is in
        /// progress (an empty preedit would cancel it). Redeemed on the next
        /// frame that can apply it.
        case owe
        /// A rebuild was applied within `coalesceInterval`; owe it to the next frame.
        case coalesce
    }

    public static func action(
        canRender: Bool,
        composing: Bool,
        now: TimeInterval,
        lastApplied: TimeInterval?
    ) -> Action {
        guard canRender, !composing else { return .owe }
        if let lastApplied, now - lastApplied < coalesceInterval { return .coalesce }
        return .apply
    }

    public static func needsTrailingRepaint(_ reason: TerminalRepaintReason) -> Bool {
        reason == .size || reason == .scale
    }

    /// Whether damage observed at `now` is the echo of our own rebuild.
    public static func isEcho(now: TimeInterval, lastApplied: TimeInterval?) -> Bool {
        guard let lastApplied else { return false }
        return now >= lastApplied && now - lastApplied < echoWindow
    }

    /// Whether continuous damage has gone long enough without a full rebuild
    /// that the settle should run now instead of waiting for quiet.
    public static func settleIsOverdue(now: TimeInterval, lastApplied: TimeInterval?, damageSince: TimeInterval) -> Bool {
        let reference = max(lastApplied ?? damageSince, damageSince)
        return now - reference >= maximumIntervalUnderDamage
    }
}

/// Counters for attributing a garble after the fact.
public struct TerminalRepaintStatistics: Sendable, Equatable {
    public var requested: [TerminalRepaintReason: Int] = [:]
    public var applied = 0
    public var owed = 0
    public var skippedWhileComposing = 0
    /// Render requests that arrived inside a frame after the burst ran out
    /// and were deferred 250 ms as cursor animation.
    public var deferredAsAnimation = 0
    public var lastReason: TerminalRepaintReason?
    public var lastAppliedUptime: TimeInterval?

    public init() {}

    public var summary: String {
        let reasons = TerminalRepaintReason.allCases.compactMap { reason in
            requested[reason].map { "\(reason.rawValue)=\($0)" }
        }.joined(separator: ",")
        return "applied=\(applied) owed=\(owed) composing=\(skippedWhileComposing) deferred=\(deferredAsAnimation) last=\(lastReason?.rawValue ?? "-") requested[\(reasons)]"
    }
}
