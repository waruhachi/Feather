import CryptoKit
import Foundation
import Security

@MainActor
final class AccretionService: ObservableObject {
	static let shared = AccretionService()
	nonisolated static let website = URL(string: "https://getaccretion.app/")!
	private static let host = "bbcjpinhvlxocjxlyplt.supabase.co"
	private static let accountOrigin = URL(string: "https://" + host)!
	private static let catalogURL = website.appendingPathComponent("data/store.json")

	struct Listing: Decodable, Identifiable {
		let i: String
		let n: String
		let d: String
		let v: String
		let tw: Int?

		var id: String { i }
		var webURL: URL {
			var parts = URLComponents(url: AccretionService.website, resolvingAgainstBaseURL: false)!
			parts.fragment = "/app/" + i
			return parts.url ?? AccretionService.website
		}
	}
	private struct Catalog: Decodable {
		let apps: [Listing]
		let shards: Int
	}
	struct Build: Decodable, Identifiable {
		let v: String
		let b: String?
		let url: URL
		let notes: String?
		var id: String { v + "|" + (b ?? "") + "|" + url.absoluteString }
	}
	private struct Details: Decodable {
		let versions: [Build]?
	}
	private struct Fingerprint: Decodable {
		let version: String
		let sha256: String?
	}
	private struct Tokens: Decodable {
		let access_token: String
		let refresh_token: String
		let expires_in: Double
	}
	struct Backup: Decodable, Identifiable {
		let id: String
		let label: String
		let payload: String
		let salt: String
		let rounds: UInt32
		let created_at: String
	}

	private struct BackupIdentity: Codable {
		let p12: Data
		let mobileprovision: Data
		let password: String
		let nickname: String
		let additionalProfiles: [Data]?
	}

	@Published private(set) var email: String?
	private var configurationKey: String?
	private var tokens: Tokens?
	private var expires: Date = .distantPast
	private var refreshTask: Task<Void, Error>?
	private var catalog: Catalog?
	private var catalogDate: Date?
	private var generation = 0

	func listings() async throws -> [Listing] {
		if let catalog, Date().timeIntervalSince(catalogDate ?? .distantPast) < 900 { return catalog.apps }
		let data = try await fetch(Self.catalogURL)
		let catalog = try JSONDecoder().decode(Catalog.self, from: data)
		guard (1...4096).contains(catalog.shards) else { throw Failure.invalidResponse }
		self.catalog = catalog
		catalogDate = Date()
		return catalog.apps
	}

	func versions(for listing: Listing) async throws -> [Build] {
		_ = try await listings()
		guard let shards = catalog?.shards else { return [] }
		let hash = listing.id.utf8.reduce(UInt32(0x811C9DC5)) { ($0 ^ UInt32($1)) &* 0x01000193 }
		let shard = Int(hash % UInt32(shards))
		let url = Self.website.appendingPathComponent(String(format: "data/apps/%03d.json", shard))
		let data = try await fetch(url)
		return try JSONDecoder().decode([String: Details].self, from: data)[listing.id]?.versions ?? []
	}

	func signIn(email: String, password: String) async throws {
		generation += 1
		let generation = self.generation
		let account = email.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !account.isEmpty, !password.isEmpty else { throw Failure.signIn }
		try await setTokens(grant: "password", body: ["email": account, "password": password], generation: generation)
		self.email = account
	}

	func signOut() {
		generation += 1
		refreshTask?.cancel()
		refreshTask = nil
		tokens = nil
		expires = .distantPast
		email = nil
	}

	func backups() async throws -> [Backup] {
		let data = try await rest("certificate_backups", query: [
			URLQueryItem(name: "select", value: "id,label,payload,salt,rounds,created_at"),
			URLQueryItem(name: "order", value: "created_at.desc")
		])
		return try JSONDecoder().decode([Backup].self, from: data)
	}

	func upload(_ certificate: CertificatePair, passphrase: String) async throws {
		guard passphrase.count >= 8, let identity = try FeatherBackup.captureIdentity(certificate) else {
			throw Failure.invalidBackup
		}
		let generation = self.generation
		let data = try JSONEncoder().encode(BackupIdentity(
			p12: identity.certificate, mobileprovision: identity.provision,
			password: identity.password, nickname: identity.name ?? "", additionalProfiles: identity.additionalProfiles
		))
		let sealed = try await Task.detached(priority: .utility) {
			let salt = try FeatherBackup.randomSalt()
			let key = try FeatherBackup.key(password: passphrase, salt: salt)
			guard let combined = try AES.GCM.seal(data, using: key).combined else { throw Failure.invalidBackup }
			return (combined.base64EncodedString(), salt.base64EncodedString())
		}.value
		guard self.generation == generation, email != nil else { throw CancellationError() }
		var row: [String: Any] = [
			"label": String((identity.name ?? .localized("Certificate")).prefix(80)),
			"payload": sealed.0, "salt": sealed.1, "rounds": 600_000
		]
		if let date = certificate.expiration { row["expires"] = ISO8601DateFormatter().string(from: date) }
		_ = try await rest("certificate_backups", method: "POST", body: row)
	}

	func restore(_ backup: Backup, passphrase: String) async throws -> [String] {
		let identity = try await Task.detached(priority: .utility) {
			guard (100_000...10_000_000).contains(backup.rounds),
				backup.payload.utf8.count <= 16 * 1024 * 1024,
				let salt = Data(base64Encoded: backup.salt), (16...64).contains(salt.count),
				let ciphertext = Data(base64Encoded: backup.payload)
			else { throw Failure.invalidBackup }
			let key = try FeatherBackup.key(password: passphrase, salt: salt, rounds: backup.rounds)
			do {
				let box = try AES.GCM.SealedBox(combined: ciphertext)
				return try JSONDecoder().decode(BackupIdentity.self, from: AES.GCM.open(box, using: key))
			} catch {
				throw Failure.invalidBackup
			}
		}.value
		let result = try await FeatherBackup.restoreIdentity(.init(
			certificate: identity.p12, provision: identity.mobileprovision, password: identity.password,
			name: identity.nickname.isEmpty ? nil : identity.nickname, additionalProfiles: identity.additionalProfiles
		))
		return result.problems
	}

	func deleteBackup(_ backup: Backup) async throws {
		guard let id = UUID(uuidString: backup.id) else { throw Failure.invalidBackup }
		_ = try await rest("certificate_backups", method: "DELETE", query: [
			URLQueryItem(name: "id", value: "eq." + id.uuidString.lowercased())
		])
	}

	func importBuild(_ build: Build, for listing: Listing) async throws -> String {
		guard email != nil, let source = URLComponents(url: build.url, resolvingAgainstBaseURL: false),
			source.scheme == "https", source.host != nil, source.user == nil, source.password == nil
		else { throw Failure.download }
		let hosted = (source.host == Self.host && source.path == "/functions/v1/download")
			|| (source.host == "dl.getaccretion.app" && source.path == "/download")
		if !hosted {
			guard source.host != Self.host, source.host != "dl.getaccretion.app" else { throw Failure.download }
			return try await importBuildURL(build.url, expectedHash: nil, bundleID: listing.id)
		}
		guard source.queryItems?.first(where: { $0.name == "app" })?.value == listing.id else { throw Failure.download }
		let generation = self.generation
		let existing = try await rest("hosted_builds", query: [
			URLQueryItem(name: "select", value: "version,sha256"),
			URLQueryItem(name: "bundle_id", value: "eq." + listing.id)
		])
		let fingerprints = try JSONDecoder().decode([Fingerprint].self, from: existing)
		let version = source.queryItems?.first(where: { $0.name == "version" })?.value
		let selected = version.flatMap { version in fingerprints.first { $0.version == version } }
			?? (version == nil ? fingerprints.first(where: { $0.version == build.v }) : nil)
		let sha256 = selected?.sha256
		if sha256 == nil && (!fingerprints.isEmpty || listing.id.hasPrefix("io.github.getaccretion.") || listing.id.hasPrefix("io.github.accretionmods.")) {
			throw Failure.download
		}

		let tokenData = try await rest("rpc/my_download_key", method: "POST", body: ["rotate": false])
		let token = try JSONDecoder().decode(String.self, from: tokenData)
		guard !token.isEmpty, self.generation == generation else { throw Failure.download }
		var download = URLComponents(url: Self.accountOrigin.appendingPathComponent("functions/v1/download"), resolvingAgainstBaseURL: false)!
		download.queryItems = [
			URLQueryItem(name: "app", value: listing.id),
			URLQueryItem(name: "key", value: token),
			URLQueryItem(name: "av", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
		] + (version.map { [URLQueryItem(name: "version", value: $0)] } ?? [])
		guard let url = download.url else { throw Failure.download }

		return try await importBuildURL(url, expectedHash: sha256, bundleID: listing.id)
	}

	private func importBuildURL(_ url: URL, expectedHash: String?, bundleID: String) async throws -> String {
		let session = URLSession(configuration: .ephemeral, delegate: HTTPSRedirect(), delegateQueue: nil)
		defer { session.finishTasksAndInvalidate() }
		let (temporary, response): (URL, URLResponse)
		do { (temporary, response) = try await session.download(from: url) }
		catch is CancellationError { throw CancellationError() }
		catch { throw Failure.download }
		defer { try? FileManager.default.removeItem(at: temporary) }
		guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw Failure.download }
		if let expectedHash {
			try await Task.detached(priority: .utility) { try IPAChecksum.verify(temporary, expected: expectedHash) }.value
		}
		return try await FR.importPackage(temporary, importOrigin: .unknown, expectedBundleIdentifier: bundleID)
	}

	private func setTokens(grant: String, body: [String: String], generation: Int) async throws {
		let data = try await accountRequest(
			path: "auth/v1/token", query: [.init(name: "grant_type", value: grant)], method: "POST", body: body, bearer: nil
		)
		let tokens = try JSONDecoder().decode(Tokens.self, from: data)
		guard self.generation == generation else { throw CancellationError() }
		self.tokens = tokens
		expires = Date().addingTimeInterval(max(0, tokens.expires_in - 60))
	}

	private func validToken() async throws -> String {
		if let tokens, Date() < expires { return tokens.access_token }
		if let refreshTask {
			try await refreshTask.value
		} else {
			guard let tokens, email != nil else { throw Failure.signIn }
			let generation = self.generation
			let task = Task { try await setTokens(grant: "refresh_token", body: ["refresh_token": tokens.refresh_token], generation: generation) }
			refreshTask = task
			defer { if self.generation == generation { refreshTask = nil } }
			try await task.value
		}
		guard let tokens else { throw Failure.signIn }
		return tokens.access_token
	}

	private func rest(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Any? = nil) async throws -> Data {
		let token = try await validToken()
		return try await accountRequest(path: "rest/v1/" + path, query: query, method: method, body: body, bearer: token)
	}

	private func configuration() async throws -> String {
		if let configurationKey { return configurationKey }
		let data = try await fetch(Self.website.appendingPathComponent("config.js"))
		guard let text = String(data: data, encoding: .utf8), let start = text.firstIndex(of: "{"),
			let end = text.lastIndex(of: "}"), start <= end,
			let object = try JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
			let origin = object["supabaseUrl"] as? String, let url = URL(string: origin),
			url.scheme == "https", url.host == Self.host, url.port == nil, url.user == nil, url.password == nil,
			url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil,
			let key = object["supabaseKey"] as? String, !key.isEmpty
		else { throw Failure.invalidResponse }
		configurationKey = key
		return key
	}

	private func accountRequest(path: String, query: [URLQueryItem], method: String, body: Any?, bearer: String?) async throws -> Data {
		let key = try await configuration()
		var parts = URLComponents(url: Self.accountOrigin.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
		if !query.isEmpty { parts.queryItems = query }
		guard let url = parts.url else { throw Failure.invalidResponse }
		var request = URLRequest(url: url, timeoutInterval: 30)
		request.httpMethod = method
		request.setValue(key, forHTTPHeaderField: "apikey")
		if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
		if let body {
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
			request.httpBody = try JSONSerialization.data(withJSONObject: body)
		}
		let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
		defer { session.finishTasksAndInvalidate() }
		let (data, response) = try await session.data(for: request)
		guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
			if (response as? HTTPURLResponse)?.statusCode == 401 { throw Failure.signIn }
			throw Failure.invalidResponse
		}
		return data
	}

	private func fetch(_ url: URL) async throws -> Data {
		let (data, response) = try await URLSession.shared.data(from: url)
		guard let http = response as? HTTPURLResponse, http.statusCode == 200,
			http.url?.scheme == "https", http.url?.host == Self.website.host else { throw Failure.invalidResponse }
		return data
	}

	private final class NoRedirect: NSObject, URLSessionTaskDelegate {
		func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
			completionHandler(nil)
		}
	}

	private final class HTTPSRedirect: NSObject, URLSessionTaskDelegate {
		func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
			guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil else {
				completionHandler(nil)
				return
			}
			completionHandler(request)
		}
	}

	private enum Failure: LocalizedError {
		case signIn, invalidBackup, invalidResponse, download
		var errorDescription: String? {
			switch self {
			case .signIn: .localized("Sign in with a valid Accretion account.")
			case .invalidBackup: .localized("Could not open this backup. Check the passphrase.")
			case .invalidResponse: .localized("The Accretion service did not accept the request.")
			case .download: .localized("Accretion could not authorize or verify this download.")
			}
		}
	}
}
