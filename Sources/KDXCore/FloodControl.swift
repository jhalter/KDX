import Foundation

/// Original per-class request window; a zero limit disables it.
struct RequestFloodWindow {
    enum Action: Equatable { case none, warning, finalWarning, ban }
    var started: TimeInterval?
    var count = 0
    mutating func record(limit: UInt8, now: TimeInterval) -> Action {
        guard limit > 0 else { started = nil; count = 0; return .none }
        if started == nil { started = now }
        count += 1
        guard count >= Int(limit) else { return .none }
        if now - (started ?? now) >= 121 { started = now; count = 0; return .none }
        if count > Int(limit)+8 { return .ban }
        if count == Int(limit)+4 { return .finalWarning }
        return count == Int(limit) ? .warning : .none
    }
}
struct ConnectionFloodWindow {
    var started: TimeInterval
    var count = 0
    var blockedUntil: TimeInterval = 0
    mutating func accept(now: TimeInterval) -> Bool {
        guard now >= blockedUntil else { return false }
        if now-started >= 300 { started = now; count = 0 }
        count += 1
        if count > 30 { blockedUntil = now+3600; return false }
        return true
    }
}
