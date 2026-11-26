import Foundation

enum ManifestService {
	private static let endpoints = [
		"https://ryuksign-install.ryuksign.workers.dev/genPlist",
		"https://api.palera.in/genPlist",
	]

	static func resolve(identifier: String, name: String, version: String, payload: URL) async throws -> URL {
		for endpoint in endpoints {
			try Task.checkCancellation()
			guard var components = URLComponents(string: endpoint) else { continue }
			components.queryItems = [
				.init(name: "bundleid", value: identifier), .init(name: "name", value: name),
				.init(name: "version", value: version), .init(name: "fetchurl", value: payload.absoluteString),
			]
			guard let url = components.url else { continue }
			let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
			if let (data, response) = try? await URLSession.shared.data(for: request),
			   let http = response as? HTTPURLResponse, http.statusCode == 200,
			   http.url?.scheme == "https", http.url?.host == url.host,
			   let document = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
			   let items = document["items"] as? [[String: Any]], items.count == 1,
			   let metadata = items.first?["metadata"] as? [String: String],
			   metadata["bundle-identifier"] == identifier,
			   let assets = items.first?["assets"] as? [[String: String]],
			   assets.filter({ $0["kind"] == "software-package" }).map({ $0["url"] }) == [payload.absoluteString] {
				return url
			}
			await ActivityLog.shared.record(.init(action: .localized("Install Diagnostics"),
				app: name, outcome: "Manifest unavailable at \(url.host ?? "")"))
		}
		throw URLError(.badServerResponse)
	}
}
