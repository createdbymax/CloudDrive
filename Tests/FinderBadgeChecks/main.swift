import Foundation

// Standalone consumer checks: compile alongside FinderSync.swift and CloudDriveCore.
// These exercise parsing/races only, never claim a live positive Finder badge.
for value in ["remoteOnly", "downloading", "availableOffline", "attention"] {
    precondition(FinderBadgeEvidence.identifier(bytes: Array(value.utf8)) == value)
}
for bytes in [Array("unknown".utf8), [], [0xff], Array("availableOffline\n".utf8), Array("availableOffline\0".utf8), Array(repeating: UInt8(65), count: 65)] {
    precondition(FinderBadgeEvidence.identifier(bytes: bytes) == nil)
}
let token = UUID()
precondition(FinderBadgeEvidence.accepts(current: token, completed: token, requestedAt: 100, now: 104.99))
precondition(!FinderBadgeEvidence.accepts(current: token, completed: token, requestedAt: 100, now: 105))
precondition(!FinderBadgeEvidence.accepts(current: nil, completed: token, requestedAt: 100, now: 101))
precondition(!FinderBadgeEvidence.accepts(current: UUID(), completed: token, requestedAt: 100, now: 101))
precondition(!FinderBadgeEvidence.accepts(current: token, completed: token, requestedAt: 100, now: 99))
print("Finder badge parsing, freshness and superseded-request checks passed")
