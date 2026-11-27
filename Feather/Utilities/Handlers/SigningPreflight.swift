import Foundation
import UIKit

enum SigningPreflight: LocalizedError {
	case encryptedExecutable
	case incompatibleArchitecture
	case updateBundleMismatch
	case updateTeamMismatch
	case updateTeamUnknown
	case savedCertificateUnavailable
	case revokedCertificate
	case expiredProfile
	case noMatchingProfile
	case newerSystemRequired(String)

	var errorDescription: String? {
		switch self {
		case .encryptedExecutable: .localized("The app executable is encrypted. Import an unencrypted IPA to sign this app.")
		case .incompatibleArchitecture: .localized("This app does not contain an ARM64 executable for iPhone or iPad.")
		case .updateBundleMismatch: .localized("The new bundle identifier differs from the copy you are updating.")
		case .updateTeamMismatch: .localized("The selected certificate belongs to a different signing team from the copy you are updating.")
		case .updateTeamUnknown: .localized("Feather could not verify the signing team of the copy you are updating.")
		case .savedCertificateUnavailable: .localized("The certificate saved for this app is unavailable. Select a certificate before signing.")
		case .revokedCertificate: .localized("The selected signing certificate has been revoked.")
		case .noMatchingProfile: .localized("No provisioning profile matches this bundle identifier.")
		case .expiredProfile: .localized("The selected provisioning profile has expired.")
		case .newerSystemRequired(let version): String(format: .localized("This app requires iOS %@ or later."), version)
		}
	}

	static func bundleIdentifier(for app: AppInfoPresentable, options: Options) -> String? {
		options.appIdentifier ?? infoOverride(options)?["CFBundleIdentifier"] as? String ?? app.identifier
	}

	@MainActor
	static func requiredSystemVersion(for app: AppInfoPresentable, options: Options) -> String? {
		#if targetEnvironment(macCatalyst)
		return nil
		#else
		let minimum: String?
		if options.minimumAppRequirement != .default {
			minimum = options.minimumAppRequirement.rawValue
		} else if let override = infoOverride(options) {
			minimum = override["MinimumOSVersion"] as? String
		} else {
			minimum = Storage.shared.getAppDirectory(for: app).flatMap { Bundle(url: $0) }?
				.object(forInfoDictionaryKey: "MinimumOSVersion") as? String
		}
		guard let minimum, minimum.contains(where: \.isNumber),
			UpdateVersion.compare(minimum, UIDevice.current.systemVersion) == .orderedDescending
		else { return nil }
		return minimum
		#endif
	}

	static func checkExecutable(at url: URL) throws {
		let result = LCInspectIOSExecutable(url.path)
		switch result {
		case 1: throw SigningPreflight.encryptedExecutable
		case 2: throw SigningPreflight.incompatibleArchitecture
		default: break
		}
	}

	@MainActor
	static func checkReplacement(of previous: AppInfoPresentable, with input: AppInfoPresentable, options: Options, certificate: CertificatePair) throws {
		guard let identifier = previous.identifier, bundleIdentifier(for: input, options: options) == identifier else {
			throw SigningPreflight.updateBundleMismatch
		}
		if certificate.revoked { throw SigningPreflight.revokedCertificate }
		let storage = Storage.shared
		let candidate = storage.signingProfile(for: certificate, bundleID: identifier)?.profile
		guard let candidate else { throw SigningPreflight.noMatchingProfile }
		if candidate.ExpirationDate <= Date() { throw SigningPreflight.expiredProfile }
		let embedded = storage.getAppDirectory(for: previous)?.appendingPathComponent("embedded.mobileprovision")
		let embeddedProfile = embedded.flatMap { FileManager.default.fileExists(atPath: $0.path) ? CertificateReader($0).decoded : nil }
		let originalProfile = embeddedProfile ?? storage.getCertificate(from: previous).flatMap { storage.getProvisionFileDecoded(for: $0) }
		guard let originalTeam = originalProfile?.TeamIdentifier.first, let candidateTeam = candidate.TeamIdentifier.first else {
			throw SigningPreflight.updateTeamUnknown
		}
		guard originalTeam == candidateTeam else { throw SigningPreflight.updateTeamMismatch }
		if let originalPrefix = originalProfile?.ApplicationIdentifierPrefix?.first,
			let candidatePrefix = candidate.ApplicationIdentifierPrefix?.first, originalPrefix != candidatePrefix
		{
			throw SigningPreflight.updateTeamMismatch
		}
	}

	private static func infoOverride(_ options: Options) -> [String: Any]? {
		guard let data = options.appInfoPlist else { return nil }
		return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
	}
}
