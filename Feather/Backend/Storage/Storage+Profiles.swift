import Foundation
import Security

extension Storage {
	struct SigningProfile: Identifiable {
		let url: URL
		let profile: Certificate
		let isOriginal: Bool

		var id: String { profile.UUID }

		private var bundleIdentifierPattern: String? {
			let identifier = (profile.Entitlements?["application-identifier"]?.value as? String)
				?? (profile.Entitlements?["com.apple.application-identifier"]?.value as? String)
			guard let identifier, let separator = identifier.firstIndex(of: ".") else { return nil }
			return String(identifier[identifier.index(after: separator)...])
		}

		var explicitBundleIdentifier: String? {
			guard let pattern = bundleIdentifierPattern, !pattern.isEmpty, !pattern.contains("*") else { return nil }
			return pattern
		}

		func matchLength(for bundleID: String) -> Int? {
			guard let pattern = bundleIdentifierPattern else { return nil }
			if pattern == bundleID { return Int.max }
			guard pattern.last == "*", bundleID.hasPrefix(pattern.dropLast()) else { return nil }
			return pattern.count - 1
		}
	}

	func signingProfiles(for certificate: CertificatePair) -> [SigningProfile] {
		guard let base = getUuidDirectory(for: certificate) else { return [] }
		let directory = base.appendingPathComponent("Profiles", isDirectory: true)
		let extras = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
		let original = getFile(.provision, from: certificate)
		return ([original].compactMap { $0 } + extras.filter { $0.pathExtension == "mobileprovision" }).compactMap { url in
			CertificateReader(url).decoded.map { SigningProfile(url: url, profile: $0, isOriginal: url == original) }
		}
	}

	func signingProfile(for certificate: CertificatePair, bundleID: String) -> SigningProfile? {
		let profiles = signingProfiles(for: certificate)
		let matching = profiles.compactMap { profile -> (SigningProfile, Int)? in
			guard profile.profile.ExpirationDate > Date(), let length = profile.matchLength(for: bundleID) else { return nil }
			return (profile, length)
		}
		let selected = matching.sorted {
			if $0.1 != $1.1 { return $0.1 > $1.1 }
			if $0.0.profile.ExpirationDate != $1.0.profile.ExpirationDate {
				return $0.0.profile.ExpirationDate > $1.0.profile.ExpirationDate
			}
			return $0.0.id < $1.0.id
		}.first?.0
		// Existing single-profile identities keep their legacy signing behavior.
		return selected ?? (profiles.count == 1 && profiles[0].isOriginal ? profiles[0] : nil)
	}

	@MainActor
	func addSigningProfile(_ data: Data, to certificate: CertificatePair) throws {
		guard data.count <= 4 * 1024 * 1024, let base = getUuidDirectory(for: certificate),
			let p12 = getFile(.certificate, from: certificate)
		else { throw ProfileError.invalid }
		let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try data.write(to: staging, options: .atomic)
		defer { try? FileManager.default.removeItem(at: staging) }
		guard let profile = CertificateReader(staging).decoded, let uuid = UUID(uuidString: profile.UUID),
			let leaf = signingCertificateData(p12: p12, password: certificate.password ?? ""),
			profile.DeveloperCertificates?.contains(leaf) == true
		else { throw ProfileError.identityMismatch }
		if signingProfiles(for: certificate).contains(where: { $0.id.caseInsensitiveCompare(profile.UUID) == .orderedSame }) {
			throw ProfileError.duplicate
		}
		let directory = base.appendingPathComponent("Profiles", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try data.write(to: directory.appendingPathComponent(uuid.uuidString + ".mobileprovision"), options: .atomic)
	}

	private func signingCertificateData(p12: URL, password: String) -> Data? {
		guard let raw = try? Data(contentsOf: p12) else { return nil }
		var options: [String: Any] = [kSecImportExportPassphrase as String: password]
		if #available(iOS 18.0, macOS 15.0, *) { options[kSecImportToMemoryOnly as String] = true }
		var result: CFArray?
		guard SecPKCS12Import(raw as CFData, options as CFDictionary, &result) == errSecSuccess,
			let items = result as? [[String: Any]],
			let chain = items.first?[kSecImportItemCertChain as String] as? [SecCertificate],
			let leaf = chain.first
		else { return nil }
		return SecCertificateCopyData(leaf) as Data
	}

	private enum ProfileError: LocalizedError {
		case invalid, identityMismatch, duplicate
		var errorDescription: String? {
			switch self {
			case .invalid: .localized("The provisioning profile is invalid.")
			case .identityMismatch: .localized("The provisioning profile does not include this signing certificate.")
			case .duplicate: .localized("This provisioning profile has already been added.")
			}
		}
	}
}
