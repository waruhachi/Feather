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

	private struct Manifest: Codable {
		var version = 1
		let sources: [Source]
		let certificates: [Identity]
		let preferences: Data
		let signing: Data

		struct Source: Codable {
			let url: URL
			let name: String?
			let identifier: String
			let icon: URL?
		}

		struct Identity: Codable {
			let certificate: Data
			let provision: Data
			let password: String
			let name: String?
		}
	}

	@MainActor
	static func export(password: String) async throws -> Data {
		guard password.count >= 8 else { throw BackupError.passwordLength }
		let sourceRecords = Storage.shared.getSources().compactMap { source -> Manifest.Source? in
			guard let url = source.sourceURL, let identifier = source.identifier else { return nil }
			return .init(url: url, name: source.name, identifier: identifier, icon: source.iconURL)
		}
		let identities = try Storage.shared.getAllCertificates().compactMap { cert -> Manifest.Identity? in
			guard
				let p12 = Storage.shared.getFile(.certificate, from: cert),
				let profile = Storage.shared.getFile(.provision, from: cert)
			else { return nil }
			return try .init(certificate: load(p12), provision: load(profile), password: cert.password ?? "", name: cert.nickname)
		}
		let values = Dictionary(uniqueKeysWithValues: settingKeys.compactMap { key in
			UserDefaults.standard.object(forKey: key).map { (key, $0) }
		})
		var signing = OptionsManager.shared.options
		signing.injectionFiles = []
		signing.tweakInjectionRules = nil
		signing.injectionFrameworks = []
		signing.injectedAppExtensions = []
		signing.appEntitlementsFile = nil
		signing.appInfoPlist = nil
		let manifest = Manifest(
			sources: sourceRecords,
			certificates: identities,
			preferences: try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0),
			signing: try JSONEncoder().encode(signing)
		)

		return try await Task.detached(priority: .utility) {
			let manager = FileManager.default
			let workspace = try workspace()
			defer { try? manager.removeItem(at: workspace) }
			let manifestURL = workspace.appendingPathComponent("Manifest.json")
			try JSONEncoder().encode(manifest).write(to: manifestURL, options: [.atomic, .completeFileProtection])
			var entries = [manifestURL]
			if manager.fileExists(atPath: TweakLibrary.directory.path) {
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
	static func restore(file: URL, password: String) async throws -> [String] {
		guard !password.isEmpty else { throw BackupError.passwordLength }
		let (workspace, manifest) = try await Task.detached(priority: .utility) {
			let access = file.startAccessingSecurityScopedResource()
			defer { if access { file.stopAccessingSecurityScopedResource() } }
			let data = try load(file)
			guard data.starts(with: header), data.count > header.count + 16 else { throw BackupError.invalid }
			let salt = Data(data.dropFirst(header.count).prefix(16))
			let zip: Data
			do {
				zip = try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst(header.count + 16)), using: key(password: password, salt: salt))
			} catch { throw BackupError.wrongPassword }

			let workspace = try workspace()
			do {
				let payload = workspace.appendingPathComponent("Backup.zip")
				try zip.write(to: payload, options: [.atomic, .completeFileProtection])
				let content = workspace.appendingPathComponent("Contents")
				try FileManager.default.createDirectoryIfNeeded(at: content)
				try IPAExtraction.extract(payload, to: content, control: ImportControl(), progress: { _ in }, maximumExtractedBytes: UInt64(maximumBytes))
				let manifestURL = content.appendingPathComponent("Manifest.json")
				let manifest = try JSONDecoder().decode(Manifest.self, from: load(manifestURL))
				guard manifest.version == 1 else { throw BackupError.invalid }
				return (workspace, manifest)
			} catch {
				try? FileManager.default.removeItem(at: workspace)
				throw error
			}
		}.value
		defer { try? FileManager.default.removeItem(at: workspace) }

		let restoredOptions = try JSONDecoder().decode(Options.self, from: manifest.signing)
		guard let settings = try PropertyListSerialization.propertyList(from: manifest.preferences, options: [], format: nil) as? [String: Any] else { throw BackupError.invalid }
		var problems: [String] = []

		for source in manifest.sources where ["https", "http"].contains(source.url.scheme?.lowercased() ?? "") {
			Storage.shared.addSource(source.url, name: source.name, identifier: source.identifier, iconURL: source.icon) { error in
				if let error { problems.append(error.localizedDescription) }
			}
		}
		var knownTweakNames = Set(TweakLibrary.files().map(\.lastPathComponent))
		let tweaks = workspace.appendingPathComponent("Contents").appendingPathComponent(TweakLibrary.directory.lastPathComponent)
		for file in TweakLibrary.files(in: tweaks) where !knownTweakNames.contains(file.lastPathComponent) {
			do {
				try TweakLibrary.add(file, metadata: TweakLibrary.metadata(for: file))
				knownTweakNames.insert(file.lastPathComponent)
			} catch { problems.append(file.lastPathComponent + " — " + error.localizedDescription) }
		}

		for identity in manifest.certificates {
			let existing = Storage.shared.getAllCertificates().contains { certificate in
				guard let p12 = Storage.shared.getFile(.certificate, from: certificate),
					let profile = Storage.shared.getFile(.provision, from: certificate)
				else { return false }
				return (try? load(p12)) == identity.certificate && (try? load(profile)) == identity.provision
			}
			if existing { continue }
			do {
				let key = workspace.appendingPathComponent("Restore.p12")
				let profile = workspace.appendingPathComponent("Restore.mobileprovision")
				try identity.certificate.write(to: key, options: [.atomic, .completeFileProtection])
				try identity.provision.write(to: profile, options: [.atomic, .completeFileProtection])
				guard FR.checkPasswordForCertificate(for: key, with: identity.password, using: profile) else { throw BackupError.invalid }
				let failure: Error? = await withCheckedContinuation { continuation in
					FR.handleCertificateFiles(p12URL: key, provisionURL: profile, p12Password: identity.password, certificateName: identity.name ?? "") {
						continuation.resume(returning: $0)
					}
				}
				if let failure { throw failure }
			} catch { problems.append((identity.name ?? .localized("Certificate")) + " — " + error.localizedDescription) }
		}

		for name in settingKeys {
			if let value = settings[name] { UserDefaults.standard.set(value, forKey: name) }
		}
		var signing = restoredOptions
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

	private static func randomSalt() throws -> Data {
		var salt = Data(count: 16)
		let status = salt.withUnsafeMutableBytes { bytes in
			SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
		}
		guard status == errSecSuccess else { throw BackupError.invalid }
		return salt
	}

	private static func key(password: String, salt: Data) throws -> SymmetricKey {
		let passwordBytes = Array(password.utf8)
		var key = Data(count: 32)
		let status = key.withUnsafeMutableBytes { output in
			salt.withUnsafeBytes { input in
				CCKeyDerivationPBKDF(
					CCPBKDFAlgorithm(kCCPBKDF2),
					passwordBytes, passwordBytes.count,
					input.bindMemory(to: UInt8.self).baseAddress, input.count,
					CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000,
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
