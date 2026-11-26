//
//  LocalCertificate.swift
//  Feather
//
//  Adapted from RyukSign by Ryuk (GPL-3.0).
//

import Foundation
import CryptoKit
import SwiftASN1
import X509

enum LocalCertificate {
	static let enabledKey = "Feather.useLocalCertificate"
	static let host = "feather.localhost"

	static var isEnabled: Bool {
		#if targetEnvironment(macCatalyst)
		false
		#else
		UserDefaults.standard.bool(forKey: enabledKey)
		#endif
	}

	private static var chainURL: URL { _directory.appendingPathComponent("server.crt") }
	private static var keyURL: URL { _directory.appendingPathComponent("server.pem") }

	private static var _directory: URL {
		URL.applicationSupportDirectory.appendingPathComponent("LocalCertificate", isDirectory: true)
	}
	private static var _authorityURL: URL { _directory.appendingPathComponent("ca.crt") }
	private static var _authorityKeyURL: URL { _directory.appendingPathComponent("ca.pem") }

	// MARK: Issuing

	// The authority is kept for good so the trust the user granted survives server certificate renewals.
	private static let lock = NSLock()

	static func identity() throws -> InstallTLSIdentity {
		lock.lock()
		defer { lock.unlock() }
		try _prepare()
		return try InstallTLSIdentity(
			certificateChain: String(contentsOf: chainURL, encoding: .utf8),
			privateKey: String(contentsOf: keyURL, encoding: .utf8),
			hostname: host
		)
	}

	private static func _prepare() throws {
		try _createDirectory()

		let (authority, authorityKey) = try _loadAuthority() ?? _createAuthority()

		if
			let server = try? _load(chainURL),
			let pem = try? String(contentsOf: keyURL, encoding: .utf8),
			let key = try? P256.Signing.PrivateKey(pemRepresentation: pem),
			server.publicKey == X509.Certificate.PublicKey(key.publicKey),
			server.subject == (try _serverName()),
			server.notValidAfter > Date().addingTimeInterval(30 * 86_400),
			try server.extensions.authorityKeyIdentifier?.keyIdentifier
				== authority.extensions.subjectKeyIdentifier?.keyIdentifier
		{
			return
		}

		try _issueServerCertificate(authority: authority, authorityKey: authorityKey)
	}

	// An unconstrained authority from an older build is replaced, so the user re-trusts a scoped one.
	private static func _loadAuthority() -> (X509.Certificate, P256.Signing.PrivateKey)? {
		guard
			let certificate = try? _load(_authorityURL),
			(try? certificate.extensions.nameConstraints) != nil,
			certificate.notValidAfter > Date().addingTimeInterval(30 * 86_400),
			let pem = try? String(contentsOf: _authorityKeyURL, encoding: .utf8),
			let key = try? P256.Signing.PrivateKey(pemRepresentation: pem),
			certificate.publicKey == X509.Certificate.PublicKey(key.publicKey)
		else {
			return nil
		}
		return (certificate, key)
	}

	// The authority key must not travel to another device through a backup.
	private static func _createDirectory() throws {
		var directory = _directory
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		var values = URLResourceValues()
		values.isExcludedFromBackup = true
		try directory.setResourceValues(values)
	}

	private static func _createAuthority() throws -> (X509.Certificate, P256.Signing.PrivateKey) {
		let key = P256.Signing.PrivateKey()
		let name = try DistinguishedName {
			CommonName("Feather Local Authority")
			OrganizationName("Feather")
		}

		let certificate = try X509.Certificate(
			version: .v3,
			serialNumber: .init(),
			publicKey: .init(key.publicKey),
			notValidBefore: Date().addingTimeInterval(-86_400),
			notValidAfter: Date().addingTimeInterval(10 * 365 * 86_400),
			issuer: name,
			subject: name,
			signatureAlgorithm: .ecdsaWithSHA256,
			extensions: try X509.Certificate.Extensions {
				Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
				Critical(KeyUsage(keyCertSign: true, cRLSign: true))
				// Trusting it must never let it vouch for real websites.
				Critical(NameConstraints(
					permittedDNSDomains: ["localhost"],
					permittedIPRanges: [ASN1OctetString(contentBytes: [127, 0, 0, 1, 255, 255, 255, 255])]
				))
				SubjectKeyIdentifier(hash: .init(key.publicKey))
			},
			issuerPrivateKey: .init(key)
		)

		try certificate.serializeAsPEM().pemString.write(to: _authorityURL, atomically: true, encoding: .utf8)
		try key.pemRepresentation.write(to: _authorityKeyURL, atomically: true, encoding: .utf8)
		return (certificate, key)
	}

	// iOS rejects TLS server certificates valid for more than 825 days.
	private static func _issueServerCertificate(authority: X509.Certificate, authorityKey: P256.Signing.PrivateKey) throws {
		let key = P256.Signing.PrivateKey()

		let certificate = try X509.Certificate(
			version: .v3,
			serialNumber: .init(),
			publicKey: .init(key.publicKey),
			notValidBefore: Date().addingTimeInterval(-86_400),
			notValidAfter: Date().addingTimeInterval(800 * 86_400),
			issuer: authority.subject,
			subject: try _serverName(),
			signatureAlgorithm: .ecdsaWithSHA256,
			extensions: try X509.Certificate.Extensions {
				Critical(BasicConstraints.notCertificateAuthority)
				Critical(KeyUsage(digitalSignature: true))
				try ExtendedKeyUsage([.serverAuth])
				SubjectAlternativeNames([
					.dnsName(host),
					.dnsName("localhost"),
					.ipAddress(ASN1OctetString(contentBytes: [127, 0, 0, 1]))
				])
				SubjectKeyIdentifier(hash: .init(key.publicKey))
				AuthorityKeyIdentifier(keyIdentifier: try authority.extensions.subjectKeyIdentifier?.keyIdentifier)
			},
			issuerPrivateKey: .init(authorityKey)
		)

		let chain = try [certificate, authority].map { try $0.serializeAsPEM().pemString }
		try chain.joined(separator: "\n").write(to: chainURL, atomically: true, encoding: .utf8)
		try key.pemRepresentation.write(to: keyURL, atomically: true, encoding: .utf8)
	}

	private static func _serverName() throws -> DistinguishedName {
		try DistinguishedName { CommonName(host) }
	}

	private static func _load(_ url: URL) throws -> X509.Certificate {
		let documents = try PEMDocument.parseMultiple(pemString: String(contentsOf: url, encoding: .utf8))
		guard let first = documents.first else { throw CocoaError(.fileReadCorruptFile) }
		return try X509.Certificate(pemDocument: first)
	}

	// MARK: Trust

	static var isTrusted: Bool {
		(try? identity().isTrusted()) ?? false
	}

	// MARK: Profile

	static func profile() throws -> Data {
		lock.lock()
		defer { lock.unlock() }
		try _prepare()
		let der = try _load(_authorityURL).serializeAsPEM().derBytes

		let payload: [String: Any] = [
			"PayloadType": "com.apple.security.root",
			"PayloadVersion": 1,
			"PayloadIdentifier": "thewonderofyou.Feather.localcertificate.authority",
			"PayloadUUID": UUID().uuidString,
			"PayloadDisplayName": "Feather Local Authority",
			"PayloadCertificateFileName": "Feather.cer",
			"PayloadContent": Data(der)
		]

		let profile: [String: Any] = [
			"PayloadType": "Configuration",
			"PayloadVersion": 1,
			"PayloadIdentifier": "thewonderofyou.Feather.localcertificate",
			"PayloadUUID": UUID().uuidString,
			"PayloadDisplayName": "Feather Local Install",
			"PayloadDescription": "Lets Feather install apps through its own server on this device.",
			"PayloadContent": [payload]
		]

		return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
	}
}
