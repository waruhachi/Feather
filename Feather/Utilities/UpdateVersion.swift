import Foundation

/// Compares numeric release versions separately from prerelease and build suffixes.
enum UpdateVersion {
	static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
		let left = components(lhs)
		let right = components(rhs)
		for index in 0..<max(left.release.count, right.release.count) {
			let a = index < left.release.count ? left.release[index] : "0"
			let b = index < right.release.count ? right.release[index] : "0"
			let order = a.compare(b, options: .numeric)
			if order != .orderedSame { return order }
		}
		if left.prerelease.isEmpty != right.prerelease.isEmpty {
			return left.prerelease.isEmpty ? .orderedDescending : .orderedAscending
		}
		for (a, b) in zip(left.prerelease, right.prerelease) {
			if a == b { continue }
			let aNumeric = a.allSatisfy(\.isNumber)
			let bNumeric = b.allSatisfy(\.isNumber)
			if aNumeric != bNumeric { return aNumeric ? .orderedAscending : .orderedDescending }
			let order = a.compare(b, options: aNumeric ? .numeric : [])
			if order != .orderedSame { return order }
		}
		if left.prerelease.count == right.prerelease.count { return .orderedSame }
		return left.prerelease.count < right.prerelease.count ? .orderedAscending : .orderedDescending
	}

	static func isPrerelease(_ version: String) -> Bool {
		!components(version).prerelease.isEmpty
	}

	private static func components(_ version: String) -> (release: [String], prerelease: [String]) {
		let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		let start = trimmed.firstIndex(where: \.isNumber) ?? trimmed.startIndex
		let value = trimmed[start...].split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
		let core = value.prefix { $0.isNumber || $0 == "." }
		let release = core.split(separator: ".").map(String.init)
		let suffix = value.dropFirst(core.count)
		var prerelease: [String] = []
		var token = ""
		for character in suffix {
			if !character.isLetter && !character.isNumber {
				if !token.isEmpty { prerelease.append(token); token = "" }
			} else {
				if let last = token.last, last.isNumber != character.isNumber {
					prerelease.append(token); token = ""
				}
				token.append(character)
			}
		}
		if !token.isEmpty { prerelease.append(token) }
		return (release, prerelease)
	}
}
