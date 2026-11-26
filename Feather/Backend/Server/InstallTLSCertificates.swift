import Foundation
import NIOSSL
import Security
import SwiftASN1
import X509

struct InstallTLSIdentity: Codable {
	let certificateChain: String
	let privateKey: String
	let hostname: String

	var host: String {
		let name = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
		return name.hasPrefix("*.") ? "local" + name.dropFirst() : name
	}

	var expiry: Date? { try? certificates().first?.notValidAfter }

	func configuration() throws -> TLSConfiguration {
		guard host.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$"#, options: .regularExpression) != nil,
			expiry.map({ $0 > Date() }) == true else {
			throw InstallTLSFailure.certificateUnavailable
		}
		let chain = try NIOSSLCertificate.fromPEMBytes(Array(certificateChain.utf8))
		let key = try NIOSSLPrivateKey(bytes: Array(privateKey.utf8), format: .pem)
		return TLSConfiguration.makeServerConfiguration(
			certificateChain: chain.map { .certificate($0) }, privateKey: .privateKey(key)
		)
	}

	func isTrusted() throws -> Bool {
		let chain = try certificates().map { certificate in
			let pem = try certificate.serializeAsPEM()
			guard let secCertificate = SecCertificateCreateWithData(nil, Data(pem.derBytes) as CFData) else {
				throw InstallTLSFailure.certificateUnavailable
			}
			return secCertificate
		}
		var trust: SecTrust?
		let policy = SecPolicyCreateSSL(true, host as CFString)
		guard !chain.isEmpty,
			SecTrustCreateWithCertificates(chain as CFArray, policy, &trust) == errSecSuccess,
			let trust
		else { return false }
		SecTrustSetNetworkFetchAllowed(trust, false)
		return SecTrustEvaluateWithError(trust, nil)
	}

	private func certificates() throws -> [X509.Certificate] {
		try PEMDocument.parseMultiple(pemString: certificateChain).map { try X509.Certificate(pemDocument: $0) }
	}
}

enum InstallTLSFailure: LocalizedError {
	case certificateUnavailable, localCertificateUntrusted, preflightFailed

	var errorDescription: String? {
		switch self {
		case .certificateUnavailable:
			.localized("No valid installation TLS certificate is available. Update SSL Certificates in Feather Settings.")
		case .localCertificateUntrusted:
			.localized("Install the Feather Local Install profile and enable full trust in iOS Certificate Trust Settings.")
		case .preflightFailed:
			.localized("Feather could not reach its local HTTPS install server.")
		}
	}
}

actor InstallTLSCertificates {
	static let shared = InstallTLSCertificates()
	private static let packURL = URL(string: "https://ryuksign-install.ryuksign.workers.dev/pack.json")!
	private static let checkedKey = "Feather.installTLSCheckedAt"
	private static var savedURL: URL {
		URL.applicationSupportDirectory.appendingPathComponent("InstallTLS.plist")
	}
	private var refreshTask: Task<Void, Error>?

	private struct Pack: Decodable {
		struct Info: Decodable { let domains: Domains }
		struct Domains: Decodable { let commonName: String }
		let cert, ca, key1, key2: String
		let info: Info

		var identity: InstallTLSIdentity {
			.init(certificateChain: [cert, ca].joined(separator: "\n"),
				  privateKey: key1 + key2, hostname: info.domains.commonName)
		}
	}

	// Preserve compatibility with older downloads and existing bundled resources.
	nonisolated static func preferredIdentity() -> InstallTLSIdentity? {
		let saved = (try? Data(contentsOf: savedURL)).flatMap {
			try? PropertyListDecoder().decode(InstallTLSIdentity.self, from: $0)
		}
		let bundled = Bundle.main.url(forResource: "server", withExtension: "crt").flatMap {
			identity(in: $0.deletingLastPathComponent())
		}
		return [saved, bundled, identity(in: .documentsDirectory)]
			.compactMap { identity -> (InstallTLSIdentity, Date)? in
				guard let identity, let expiry = identity.expiry, expiry > Date(),
					  (try? NIOSSLContext(configuration: identity.configuration())) != nil,
					  (try? identity.isTrusted()) == true
				else { return nil }
				return (identity, expiry)
			}
			.max { $0.1 < $1.1 }?.0
	}

	nonisolated private static func identity(in directory: URL) -> InstallTLSIdentity? {
		guard
			let chain = try? String(contentsOf: directory.appendingPathComponent("server.crt"), encoding: .utf8),
			let key = try? String(contentsOf: directory.appendingPathComponent("server.pem"), encoding: .utf8),
			let name = try? String(contentsOf: directory.appendingPathComponent("commonName.txt"), encoding: .utf8)
		else { return nil }
		return .init(certificateChain: chain, privateKey: key, hostname: name)
	}

	func refreshIfNeeded() async {
		guard !LocalCertificate.isEnabled else { return }
		let checked = UserDefaults.standard.object(forKey: Self.checkedKey) as? Date ?? .distantPast
		let expiry = Self.preferredIdentity()?.expiry ?? .distantPast
		guard Date().timeIntervalSince(checked) >= 86_400 || expiry < Date().addingTimeInterval(14 * 86_400) else { return }
		try? await refresh()
	}

	func refresh() async throws {
		if let refreshTask { return try await refreshTask.value }

		let task = Task {
			let request = URLRequest(url: Self.packURL, timeoutInterval: 15)
			let (data, response) = try await URLSession.shared.data(for: request)
			guard (response as? HTTPURLResponse)?.statusCode == 200 else {
				throw InstallTLSFailure.certificateUnavailable
			}
			let identity = try JSONDecoder().decode(Pack.self, from: data).identity
			let tls = try identity.configuration()
			_ = try NIOSSLContext(configuration: tls)
			guard try identity.isTrusted() else { throw InstallTLSFailure.certificateUnavailable }

			if let expiry = Self.preferredIdentity()?.expiry, let newExpiry = identity.expiry, newExpiry < expiry {
				throw InstallTLSFailure.certificateUnavailable
			}
			let url = Self.savedURL
			try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
			try PropertyListEncoder().encode(identity).write(to: url, options: .atomic)
			UserDefaults.standard.set(Date(), forKey: Self.checkedKey)
		}
		refreshTask = task
		defer { refreshTask = nil }
		try await task.value
	}
}
