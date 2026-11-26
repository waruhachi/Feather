import Foundation
import NimbleExtensions

enum IPALink {
	static func resolve(_ text: String) async throws -> URL {
		guard let link = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
			throw LinkError.invalid
		}
		if isDownloadURL(link) { return link }

		guard link.scheme?.lowercased() == "itms-services",
			let components = URLComponents(url: link, resolvingAgainstBaseURL: false),
			let items = components.queryItems,
			items.contains(where: { $0.name == "action" && $0.value == "download-manifest" }),
			let location = items.first(where: { $0.name == "url" })?.value,
			let manifest = URL(string: location), isDownloadURL(manifest)
		else { throw LinkError.invalid }

		let (bytes, response) = try await URLSession.shared.bytes(from: manifest)
		guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
			throw LinkError.manifestUnavailable
		}
		var data = Data()
		for try await byte in bytes {
			guard data.count < 1024 * 1024 else { throw LinkError.invalidManifest }
			data.append(byte)
		}
		return try packageURL(in: data)
	}

	static func packageURL(in data: Data) throws -> URL {
		guard let root = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
			let items = root["items"] as? [[String: Any]]
		else { throw LinkError.invalidManifest }

		for item in items {
			for asset in item["assets"] as? [[String: Any]] ?? [] {
				if asset["kind"] as? String == "software-package",
					let value = asset["url"] as? String, let url = URL(string: value), isDownloadURL(url)
				{
					return url
				}
			}
		}
		throw LinkError.invalidManifest
	}

	private static func isDownloadURL(_ url: URL) -> Bool {
		["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false
	}

	private enum LinkError: LocalizedError {
		case invalid, manifestUnavailable, invalidManifest

		var errorDescription: String? {
			switch self {
			case .invalid: .localized("Enter an HTTP or HTTPS IPA link or an itms-services install link.")
			case .manifestUnavailable: .localized("The installation manifest could not be downloaded.")
			case .invalidManifest: .localized("The installation manifest does not contain a usable IPA link.")
			}
		}
	}
}
