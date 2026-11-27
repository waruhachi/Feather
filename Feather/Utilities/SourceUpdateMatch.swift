import AltSourceKit
import Foundation

enum SourceUpdateMatch {
	static func listing(
		in apps: [ASRepository.App],
		bundleID: String,
		importedURL: URL?,
		importedName: String?
	) -> ASRepository.App? {
		let matches = apps.filter { $0.id == bundleID }
		if let importedURL {
			let sameAsset = matches.filter { app in
				app.downloadURL == importedURL || app.currentDownloadUrl == importedURL
					|| app.versions?.contains(where: { $0.downloadURL == importedURL }) == true
			}
			if sameAsset.count == 1 { return sameAsset[0] }
			if !sameAsset.isEmpty {
				return uniqueNameMatch(in: sameAsset, name: importedName)
			}
		}

		if let importedName, !variantName(importedName).isEmpty {
			return uniqueNameMatch(in: matches, name: importedName)
		}
		return matches.count == 1 ? matches[0] : nil
	}

	static func variantName(_ title: String) -> String {
		title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
			.replacingOccurrences(of: #"\b(?:ig|ios|v|version)?\s*v?\d+(?:[.]\d+)*(?![a-z0-9])"#, with: " ", options: .regularExpression)
			.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+")).inverted)
			.filter { !$0.isEmpty }
			.joined(separator: " ")
	}

	private static func uniqueNameMatch(in apps: [ASRepository.App], name: String?) -> ASRepository.App? {
		guard let name else { return nil }
		let exact = apps.filter { $0.currentName.caseInsensitiveCompare(name) == .orderedSame }
		if exact.count == 1 { return exact[0] }
		let key = variantName(name)
		guard !key.isEmpty else { return nil }
		let variants = apps.filter { variantName($0.currentName) == key }
		return variants.count == 1 ? variants[0] : nil
	}
}
