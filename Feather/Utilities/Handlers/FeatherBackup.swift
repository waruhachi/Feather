import CommonCrypto
import CoreData
import CryptoKit
import Foundation
import Zip

enum FeatherBackup {
	private static let header = Data("FEATHER-BACKUP-1\n".utf8)
	private static let maximumBytes = 128 * 1024 * 1024
	private static let settingKeys = [
		"Feather.userInterfaceStyle", "Feather.userTintColor", "Feather.shouldTintIcons",
		"Feather.storeCellAppearance", "Feather.favoriteSources", "Feather.openImportOnLaunch",
		"Feather.libraryImportAction", "Feather.navigationHaptics", "Feather.actionHaptics",
		"Feather.resultHaptics", "Feather.installationMethod", "Feather.serverMethod",
		"Feather.ipFix", "Feather.compressionLevel", "Feather.useShareSheetForArchiving",
		"Feather.deleteOlderSignedCopies", "Feather.deleteEqualSignedCopies", "Feather.deleteNewerSignedCopies",
		"Feather.deleteInstalledSignedCopy", "Feather.clearCacheAfterInstall", "Feather.openImportOnReopen",
		"Feather.dismissInstallAfterFinish", "Feather.openImportAfterInstall", "Feather.certificateSort",
		"Feather.ignoredReleaseTags",
	]

	enum Component: String, CaseIterable, Hashable {
		case certificates, sources, tweaks, preferences

		var title: String {
			switch self {
			case .certificates: .localized("Certificates")
			case .sources: .localized("Sources")
			case .tweaks: .localized("Saved Tweaks")
			case .preferences: .localized("Preferences")
			}
		}
	}

	private struct Manifest: Codable {
		var version = 1
		let sources: [Source]
		let certificates: [Identity]
		let preferences: Data
		let signing: Data
		var pairing: Data?
		var migrationManifest: Data?

		struct Source: Codable {
			let url: URL
			let name: String?
			let identifier: String
			let icon: URL?
		}
	}

	struct Identity: Codable {
		let certificate: Data
		let provision: Data
		let password: String
		let name: String?
		var additionalProfiles: [Data]? = nil
	}

	@MainActor
	static func export(password: String, components: Set<Component>, includePairing: Bool = false, migrationManifest: Data? = nil) async throws -> Data {
		guard password.count >= 8 else { throw BackupError.passwordLength }
		guard !components.isEmpty else { throw BackupError.invalid }
		let sourceRecords = (components.contains(.sources) ? Storage.shared.getSources() : []).compactMap { source -> Manifest.Source? in
			guard let url = source.sourceURL, let identifier = source.identifier else { return nil }
			return .init(url: url, name: source.name, identifier: identifier, icon: source.iconURL)
		}
		let identities = try (components.contains(.certificates) ? Storage.shared.getAllCertificates() : []).compactMap { try captureIdentity($0) }
		let values = Dictionary(uniqueKeysWithValues: (components.contains(.preferences) ? settingKeys : []).compactMap { key in
			UserDefaults.standard.object(forKey: key).map { (key, $0) }
		})
		var signing = OptionsManager.shared.options
		signing.injectionFiles = []
		signing.tweakInjectionRules = nil
		signing.injectionFrameworks = []
		signing.injectedAppExtensions = []
		signing.appEntitlementsFile = nil
		signing.appInfoPlist = nil
		let pairingFile = URL.documentsDirectory.appendingPathComponent("pairingFile.plist")
		let pairing = includePairing && FileManager.default.fileExists(atPath: pairingFile.path) ? try load(pairingFile) : nil
		let manifest = Manifest(
			sources: sourceRecords,
			certificates: identities,
			preferences: try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0),
			signing: components.contains(.preferences) ? try JSONEncoder().encode(signing) : Data(),
			pairing: pairing, migrationManifest: migrationManifest
		)

		return try await Task.detached(priority: .utility) {
			let manager = FileManager.default
			let workspace = try workspace()
			defer { try? manager.removeItem(at: workspace) }
			let manifestURL = workspace.appendingPathComponent("Manifest.json")
			try JSONEncoder().encode(manifest).write(to: manifestURL, options: [.atomic, .completeFileProtection])
			var entries = [manifestURL]
			if components.contains(.tweaks), manager.fileExists(atPath: TweakLibrary.directory.path) {
				entries.append(TweakLibrary.directory)
			}
			let zip = workspace.appendingPathComponent("Backup.zip")
			try Zip.zipFiles(paths: entries, zipFilePath: zip, password: nil, compression: .DefaultCompression, progress: nil)
			let salt = try randomSalt()
			let sealed = try AES.GCM.seal(load(zip), using: key(password: password, salt: salt))
			guard let combined = sealed.combined else { throw BackupError.invalid }
			let data = header + salt + combined
			guard data.count <= maximumBytes else { throw BackupError.tooLarge }
			return data
		}.value
	}

	@MainActor
	static func restore(file: URL, password: String, components: Set<Component>, restorePairing: Bool = false, expectedMigrationManifest: Data? = nil) async throws -> [String] {
		guard !password.isEmpty else { throw BackupError.passwordLength }
		guard !components.isEmpty else { throw BackupError.invalid }
		let (workspace, manifest) = try await Task.detached(priority: .utility) { () throws -> (URL, Manifest) in
			let access = file.startAccessingSecurityScopedResource()
			defer { if access { file.stopAccessingSecurityScopedResource() } }
			let data = try load(file)
			guard data.starts(with: header), data.count > header.count + 16 else { throw BackupError.invalid }
			let salt = Data(data.dropFirst(header.count).prefix(16))
			let zip: Data
			do {
				zip = try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst(header.count + 16)), using: key(password: password, salt: salt))
			} catch { throw BackupError.wrongPassword }

			let workspace = try Self.workspace()
			do {
				let payload = workspace.appendingPathComponent("Backup.zip")
				try zip.write(to: payload, options: [.atomic, .completeFileProtection])
				let content = workspace.appendingPathComponent("Contents")
				try FileManager.default.createDirectoryIfNeeded(at: content)
				try IPAExtraction.extract(payload, to: content, control: ImportControl(), progress: { _ in }, maximumExtractedBytes: UInt64(maximumBytes))
				let manifestURL = content.appendingPathComponent("Manifest.json")
				let manifest = try JSONDecoder().decode(Manifest.self, from: load(manifestURL))
				guard manifest.version == 1,
					expectedMigrationManifest == nil || expectedMigrationManifest == manifest.migrationManifest
				else { throw BackupError.invalid }
				return (workspace, manifest)
			} catch {
				try? FileManager.default.removeItem(at: workspace)
				throw error
			}
		}.value
		defer { try? FileManager.default.removeItem(at: workspace) }

		let restoredOptions = if components.contains(.preferences), !manifest.signing.isEmpty {
			try JSONDecoder().decode(Options.self, from: manifest.signing)
		} else {
			nil as Options?
		}
		guard let settings = try PropertyListSerialization.propertyList(from: manifest.preferences, options: [], format: nil) as? [String: Any] else { throw BackupError.invalid }
		var problems: [String] = []

		if restorePairing, let pairing = manifest.pairing {
			let url = URL.documentsDirectory.appendingPathComponent("pairingFile.plist")
			if !FileManager.default.fileExists(atPath: url.path) {
				do {
					guard pairing.count <= 4 * 1024 * 1024,
						(try PropertyListSerialization.propertyList(from: pairing, format: nil)) is [String: Any]
					else { throw BackupError.invalid }
					try pairing.write(to: url, options: [.atomic, .completeFileProtection])
				} catch { problems.append(error.localizedDescription) }
			}
		}

		for source in (components.contains(.sources) ? manifest.sources : []) where ["https", "http"].contains(source.url.scheme?.lowercased() ?? "") {
			Storage.shared.addSource(source.url, name: source.name, identifier: source.identifier, iconURL: source.icon) { error in
				if let error { problems.append(error.localizedDescription) }
			}
		}
		var knownTweakNames = Set(TweakLibrary.files().map(\.lastPathComponent))
		let tweaks = workspace.appendingPathComponent("Contents").appendingPathComponent(TweakLibrary.directory.lastPathComponent)
		for file in (components.contains(.tweaks) ? TweakLibrary.files(in: tweaks) : []) where !knownTweakNames.contains(file.lastPathComponent) {
			do {
				try TweakLibrary.add(file, metadata: TweakLibrary.metadata(for: file))
				knownTweakNames.insert(file.lastPathComponent)
			} catch { problems.append(file.lastPathComponent + " — " + error.localizedDescription) }
		}

		for identity in (components.contains(.certificates) ? manifest.certificates : []) {
			do {
				let result = try await restoreIdentity(identity)
				problems.append(contentsOf: result.problems)
			} catch { problems.append((identity.name ?? .localized("Certificate")) + " — " + error.localizedDescription) }
		}

		guard var signing = restoredOptions else { return problems }
		for name in settingKeys {
			if let value = settings[name] { UserDefaults.standard.set(value, forKey: name) }
		}
		let current = OptionsManager.shared.options
		signing.injectionFiles = current.injectionFiles
		signing.tweakInjectionRules = current.tweakInjectionRules
		signing.injectionFrameworks = current.injectionFrameworks
		signing.injectedAppExtensions = current.injectedAppExtensions
		signing.appEntitlementsFile = current.appEntitlementsFile
		signing.appInfoPlist = current.appInfoPlist
		OptionsManager.shared.options = signing
		return problems
	}

	@MainActor
	static func captureIdentity(_ cert: CertificatePair) throws -> Identity? {
		let storage = Storage.shared
		guard let p12 = storage.getFile(.certificate, from: cert),
			let profile = storage.getFile(.provision, from: cert)
		else { return nil }
		let profiles = try storage.signingProfiles(for: cert).filter { !$0.isOriginal }.map { try load($0.url) }
		return try Identity(certificate: load(p12), provision: load(profile), password: cert.password ?? "", name: cert.nickname, additionalProfiles: profiles)
	}

	@MainActor
	static func restoreIdentity(_ identity: Identity) async throws -> (added: Bool, problems: [String]) {
		let storage = Storage.shared
		let matching = storage.getAllCertificates().first { certificate in
			guard let p12 = storage.getFile(.certificate, from: certificate),
				let profile = storage.getFile(.provision, from: certificate)
			else { return false }
			return (try? load(p12)) == identity.certificate && (try? load(profile)) == identity.provision
		}
		let certificate: CertificatePair
		if let matching {
			certificate = matching
		} else {
			let workspace = try workspace()
			defer { try? FileManager.default.removeItem(at: workspace) }
			let key = workspace.appendingPathComponent("Restore.p12")
			let profile = workspace.appendingPathComponent("Restore.mobileprovision")
			try identity.certificate.write(to: key, options: [.atomic, .completeFileProtection])
			try identity.provision.write(to: profile, options: [.atomic, .completeFileProtection])
			guard FR.checkPasswordForCertificate(for: key, with: identity.password, using: profile) else { throw BackupError.invalid }
			let handler = CertificateFileHandler(key: key, provision: profile, password: identity.password, nickname: identity.name)
			try await handler.copy()
			try await handler.addToDatabase()
			guard let imported = storage.getAllCertificates().first(where: { $0.uuid == handler.identifier }) else {
				throw BackupError.invalid
			}
			certificate = imported
		}
		var problems: [String] = []
		var existing = Set(storage.signingProfiles(for: certificate).compactMap { try? load($0.url) })
		for extra in identity.additionalProfiles ?? [] where existing.insert(extra).inserted {
			do { try storage.addSigningProfile(extra, to: certificate) }
			catch { problems.append((identity.name ?? .localized("Certificate")) + " — " + error.localizedDescription) }
		}
		return (matching == nil, problems)
	}

	private static func workspace() throws -> URL {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("FeatherBackup-" + UUID().uuidString)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
		return url
	}

	private static func load(_ file: URL) throws -> Data {
		let metadata = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
		guard metadata.isRegularFile == true, metadata.isSymbolicLink != true else { throw BackupError.invalid }
		guard let size = metadata.fileSize, size <= maximumBytes else { throw BackupError.tooLarge }
		return try Data(contentsOf: file, options: .mappedIfSafe)
	}

	static func randomSalt() throws -> Data {
		var salt = Data(count: 16)
		let status = salt.withUnsafeMutableBytes { bytes in
			SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
		}
		guard status == errSecSuccess else { throw BackupError.invalid }
		return salt
	}

	static func key(password: String, salt: Data, rounds: UInt32 = 600_000) throws -> SymmetricKey {
		let passwordBytes = Array(password.utf8)
		var key = Data(count: 32)
		let status = key.withUnsafeMutableBytes { output in
			salt.withUnsafeBytes { input in
				CCKeyDerivationPBKDF(
					CCPBKDFAlgorithm(kCCPBKDF2),
					passwordBytes, passwordBytes.count,
					input.bindMemory(to: UInt8.self).baseAddress, input.count,
					CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
					output.bindMemory(to: UInt8.self).baseAddress, output.count
				)
			}
		}
		guard status == kCCSuccess else { throw BackupError.invalid }
		return SymmetricKey(data: key)
	}

	private enum BackupError: LocalizedError {
		case invalid, wrongPassword, passwordLength, tooLarge

		var errorDescription: String? {
			switch self {
			case .invalid: .localized("This is not a valid Feather backup.")
			case .wrongPassword: .localized("Incorrect password or damaged backup.")
			case .passwordLength: .localized("Enter a backup password of at least eight characters.")
			case .tooLarge: .localized("This backup exceeds 128 MB.")
			}
		}
	}
}
