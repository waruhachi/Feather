#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import Security
import UIKit

enum HostedSelfUpdate {
	static let bundleIdentifier = "thewonderofyou.Feather"

	struct Release: Decodable, Identifiable {
		struct Asset: Decodable {
			let name: String
			let size: Int
		}

		let tag_name: String
		let draft: Bool
		let prerelease: Bool
		let assets: [Asset]
		let body: String?

		var id: String { tag_name }
		var page: URL { URL(string: "https://github.com/waruhachi/Feather/releases/tag/" + tag_name)! }

		var version: String { String(tag_name.dropFirst()) }
		var isSupported: Bool {
			!draft && !prerelease
				&& tag_name.range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil
				&& assets.contains { $0.name == "Feather.ipa" && $0.size > 0 }
		}

		var isNewer: Bool {
			guard let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return false }
			return version.compare(installed, options: .numeric) == .orderedDescending
		}
	}

	private struct SignResponse: Decodable {
		let manifest: URL
	}

	struct Configuration {
		let origin: URL

		init(_ value: String) throws {
			guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
				var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
				parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
				parts.path.isEmpty || parts.path == "/",
				parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil
			else { throw Failure.invalidServer }

			parts.path = ""
			guard let origin = parts.url else { throw Failure.invalidServer }
			self.origin = origin
		}

		var signingURL: URL {
			origin.appendingPathComponent("v1/sign")
		}

		func validates(manifest: URL) -> Bool {
			manifest.scheme == origin.scheme && manifest.host == origin.host
				&& (manifest.port ?? 443) == (origin.port ?? 443)
				&& manifest.user == nil && manifest.password == nil
				&& manifest.query == nil && manifest.fragment == nil
				&& manifest.path.range(of: #"^/files/[a-f0-9]{48}/manifest\.plist$"#, options: .regularExpression) != nil
		}
	}

	static func latestRelease() async throws -> Release {
		let url = URL(string: "https://api.github.com/repos/waruhachi/Feather/releases/latest")!
		var request = URLRequest(url: url)
		request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
		let (data, response) = try await URLSession.shared.data(for: request)
		guard (response as? HTTPURLResponse)?.statusCode == 200,
			let release = try? JSONDecoder().decode(Release.self, from: data), release.isSupported
		else { throw Failure.releaseUnavailable }
		return release
	}

	static func releaseHistory(page: Int) async throws -> (releases: [Release], hasMore: Bool) {
		guard (1...100).contains(page) else { return ([], false) }
		let url = URL(string: "https://api.github.com/repos/waruhachi/Feather/releases?per_page=30&page=\(page)")!
		var request = URLRequest(url: url, timeoutInterval: 15)
		request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
		let (data, response) = try await URLSession.shared.data(for: request)
		guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.releaseUnavailable }
		let releases = try JSONDecoder().decode([Release].self, from: data)
		return (releases.filter(\.isSupported), releases.count == 30 && page < 100)
	}

	@MainActor
	static func requestInstall(
		release: Release,
		configuration: Configuration,
		token: String,
		certificate: CertificatePair
	) async throws -> URL {
		guard Bundle.main.bundleIdentifier == bundleIdentifier else { throw Failure.bundleMismatch }
		guard release.isSupported && release.isNewer else { throw Failure.releaseUnavailable }
		guard !token.isEmpty && token.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else { throw Failure.unauthorized }
		guard let p12 = Storage.shared.getFile(.certificate, from: certificate),
			let provision = Storage.shared.getFile(.provision, from: certificate)
		else { throw Failure.certificateMissing }

		if let executable = Bundle.main.executableURL,
			let current = MachOEntitlements.read(forExecutableAt: executable)?["application-identifier"] as? String,
			let currentTeam = current.split(separator: ".").first,
			let selectedTeams = Storage.shared.getProvisionFileDecoded(for: certificate)?.TeamIdentifier,
			!selectedTeams.contains(String(currentTeam))
		{
			throw Failure.signingTeamMismatch
		}

		let boundary = "Feather-\(UUID().uuidString)"
		let password = certificate.password ?? ""
		let body = try await Task.detached {
			try multipart(tag: release.tag_name, password: password, certificate: p12, provision: provision, boundary: boundary)
		}.value

		var request = URLRequest(url: configuration.signingURL, timeoutInterval: 240)
		request.httpMethod = "POST"
		request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
		defer { session.finishTasksAndInvalidate() }

		let (data, response) = try await session.upload(for: request, from: body)
		switch (response as? HTTPURLResponse)?.statusCode {
		case 200: break
		case 401, 403: throw Failure.unauthorized
		case 409, 429: throw Failure.busy
		case 422: throw Failure.signingFailed
		default: throw Failure.serverRejected
		}
		guard data.count < 8192,
			let signed = try? JSONDecoder().decode(SignResponse.self, from: data),
			configuration.validates(manifest: signed.manifest)
		else { throw Failure.serverRejected }

		var install = URLComponents()
		install.scheme = "itms-services"
		install.host = ""
		install.queryItems = [
			URLQueryItem(name: "action", value: "download-manifest"),
			URLQueryItem(name: "url", value: signed.manifest.absoluteString),
		]
		guard let url = install.url else { throw Failure.serverRejected }
		return url
	}

	private static func multipart(tag: String, password: String, certificate: URL, provision: URL, boundary: String) throws -> Data {
		func boundedData(_ url: URL, limit: Int) throws -> Data {
			let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
			guard let size, size > 0 && size <= limit else { throw Failure.certificateMissing }
			return try Data(contentsOf: url)
		}

		var body = Data()
		func add(_ name: String, data: Data, filename: String? = nil) {
			let disposition = "Content-Disposition: form-data; name=\"\(name)\""
				+ (filename.map { "; filename=\"\($0)\"" } ?? "")
			body.append(Data("--\(boundary)\r\n\(disposition)\r\n\r\n".utf8))
			body.append(data)
			body.append(Data("\r\n".utf8))
		}

		add("tag", data: Data(tag.utf8))
		add("password", data: Data(password.utf8))
		add("p12", data: try boundedData(certificate, limit: 512 * 1024), filename: "certificate.p12")
		add("provision", data: try boundedData(provision, limit: 2 * 1024 * 1024), filename: "profile.mobileprovision")
		body.append(Data("--\(boundary)--\r\n".utf8))
		return body
	}

	private final class NoRedirects: NSObject, URLSessionTaskDelegate {
		func urlSession(
			_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
			newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
		) { completionHandler(nil) }
	}

	// Scope the access token to its configured host. The signing identity remains in Feather’s certificate library.
	static func storedToken(for origin: URL) -> String? {
		var query = keychainQuery(origin)
		query[kSecReturnData as String] = true
		var value: CFTypeRef?
		guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
			let data = value as? Data else { return nil }
		return String(data: data, encoding: .utf8)
	}

	static func saveToken(_ token: String, for origin: URL) throws {
		let query = keychainQuery(origin)
		if token.isEmpty {
			let status = SecItemDelete(query as CFDictionary)
			guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain }
			return
		}
		let payload: [String: Any] = [kSecValueData as String: Data(token.utf8)]
		let update = SecItemUpdate(query as CFDictionary, payload as CFDictionary)
		if update == errSecItemNotFound {
			var entry = query.merging(payload, uniquingKeysWith: { _, new in new })
			entry[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
			guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else { throw Failure.keychain }
		} else if update != errSecSuccess { throw Failure.keychain }
	}

	private static func keychainQuery(_ origin: URL) -> [String: Any] {
		[
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: "Feather.HostedSelfUpdate",
			kSecAttrAccount as String: origin.absoluteString,
		]
	}

	enum Failure: LocalizedError {
		case invalidServer, releaseUnavailable, bundleMismatch, certificateMissing, signingTeamMismatch
		case unauthorized, busy, signingFailed, serverRejected, keychain

		var errorDescription: String? {
			switch self {
			case .invalidServer: .localized("Enter an HTTPS server address without a path.")
			case .releaseUnavailable: .localized("A compatible Feather release is unavailable.")
			case .bundleMismatch: .localized("Hosted updates replace the standard Feather bundle identifier.")
			case .certificateMissing: .localized("Choose a certificate with a valid provisioning profile.")
			case .signingTeamMismatch: .localized("Choose a certificate from the team that signed this installation.")
			case .unauthorized: .localized("The server did not accept the access token.")
			case .busy: .localized("The signing server is busy. Try again shortly.")
			case .signingFailed: .localized("The server could not sign this release with the selected certificate.")
			case .serverRejected: .localized("The signing server did not return a valid installation link.")
			case .keychain: .localized("Could not save the token to the Keychain.")
			}
		}
	}
}
#endif
