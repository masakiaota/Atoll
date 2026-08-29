import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

var usage = LocalSendDiscoveryUsage()
let shelf = UUID()
let picker = UUID()

expect(usage.acquire(for: shelf), "the first owner starts discovery")
expect(usage.ownerCount == 1, "the first owner is retained")
expect(!usage.acquire(for: shelf), "duplicate acquisition does not restart discovery")
expect(usage.ownerCount == 1, "duplicate acquisition is idempotent")

expect(!usage.acquire(for: picker), "a second owner does not restart discovery")
expect(usage.ownerCount == 2, "both owners are retained")
expect(!usage.release(for: shelf), "releasing one owner keeps discovery active")
expect(usage.isActive, "the remaining owner keeps discovery active")
expect(usage.release(for: picker), "the last owner stops discovery")
expect(!usage.isActive, "discovery is inactive after the final release")

expect(!usage.release(for: picker), "duplicate release does not stop again")
expect(usage.acquire(for: picker), "the same owner can retry after rollback")
expect(usage.release(for: picker), "a failed start can roll back its ownership")
expect(usage.acquire(for: shelf), "another owner can retry after rollback")
expect(!usage.acquire(for: picker), "overlapping acquisition remains deduplicated")
expect(!usage.release(for: shelf), "overlapping release preserves the newer owner")
expect(usage.release(for: picker), "the newer owner can perform the final stop")

print("LocalSendDiscoveryUsageTests passed")
