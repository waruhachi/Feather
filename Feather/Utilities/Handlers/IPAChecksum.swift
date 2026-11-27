import CryptoKit
import Foundation

enum IPAChecksum: LocalizedError {
	case invalid
	case mismatch

	var errorDescription: String? {
		switch self {
		case .invalid: .localized("The source supplied an invalid SHA-256 checksum.")
		case .mismatch: .localized("The downloaded IPA does not match the source's SHA-256 checksum.")
		}
	}

	static func verify(_ file: URL, expected: String) throws {
		let expected = expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard expected.utf8.count == 64, expected.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
			throw IPAChecksum.invalid
		}
		let reader = try FileHandle(forReadingFrom: file)
		defer { try? reader.close() }
		var hash = SHA256()
		while let block = try reader.read(upToCount: 1024 * 1024), !block.isEmpty {
			try Task.checkCancellation()
			hash.update(data: block)
		}
		let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
		guard actual == expected else { throw IPAChecksum.mismatch }
	}
}
