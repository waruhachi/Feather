import Foundation

/// Tracks byte coverage across concurrent HTTP range requests for one immutable IPA.
final class OTAPayloadProgress: @unchecked Sendable {
	struct Snapshot: Sendable {
		let sent: Int
		let total: Int

		var fraction: Double { Double(sent) / Double(total) }
		var isComplete: Bool { sent == total }
	}

	let total: Int
	private let lock = NSLock()
	private var covered: [Range<Int>] = []
	private var sent = 0
	private var lastReport = -Double.infinity

	init(total: Int) {
		precondition(total > 0)
		self.total = total
	}

	var snapshot: Snapshot {
		lock.withLock { Snapshot(sent: sent, total: total) }
	}

	func record(_ range: Range<Int>, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Snapshot? {
		guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= total else { return nil }
		return lock.withLock {
			var first = 0
			while first < covered.count, covered[first].upperBound < range.lowerBound { first += 1 }

			var lower = range.lowerBound
			var upper = range.upperBound
			var end = first
			var replaced = 0
			while end < covered.count, covered[end].lowerBound <= upper {
				lower = min(lower, covered[end].lowerBound)
				upper = max(upper, covered[end].upperBound)
				replaced += covered[end].count
				end += 1
			}

			let added = upper - lower - replaced
			guard added > 0 else { return nil }
			covered.replaceSubrange(first..<end, with: [lower..<upper])
			sent += added
			guard sent == total || now - lastReport >= 0.1 else { return nil }
			lastReport = now
			return Snapshot(sent: sent, total: total)
		}
	}
}
