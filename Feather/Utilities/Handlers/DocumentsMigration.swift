import CoreData
import CryptoKit
import Foundation

@MainActor
enum DocumentsMigration {
	private struct Manifest: Codable {
		var version = 1
		let apps: [Entry]
	}

	private struct Entry: Codable {
		let id: UUID
		let name: String?
		let identifier: String?
		let version: String?
		let date: Date?
		let icon: String?
		let signed: Bool
		let source: URL?
		let certificate: String?
		let bundle: String
		let provenance: SourceAppProvenance?
		let origin: IPAImportOrigin?
		let disabled: Bool?
		let skippedVersion: String?
		let pinnedSource: URL?
	}

	nonisolated private static let settings = "Feather.featherbackup"
	nonisolated private static let manifestName = "Migration.json"
	nonisolated private static let payload = "Library"
	nonisolated private static let archives = "Archives"

	static func export(to parent: URL, password: String) async throws -> String {
		let access = parent.startAccessingSecurityScopedResource()
		defer { if access { parent.stopAccessingSecurityScopedResource() } }
		let manager = FileManager.default
		let storage = Storage.shared
		let apps = try storage.context.fetch(Imported.fetchRequest()).map { $0 as AppInfoPresentable }
			+ storage.context.fetch(Signed.fetchRequest()).map { $0 as AppInfoPresentable }
		let entries: [(Entry, URL)] = apps.compactMap { app in
			guard let raw = app.uuid, let id = UUID(uuidString: raw),
				let bundle = storage.getAppDirectory(for: app) else { return nil }
			let metadata = storage.sourceMetadata(for: raw)
			let provenance = metadata.flatMap { metadata -> SourceAppProvenance? in
				guard let url = metadata.sourceRepositoryURL, let id = metadata.sourceAppIdentifier else { return nil }
				return SourceAppProvenance(
					sourceRepositoryURL: url, sourceRepositoryIdentifier: metadata.sourceRepositoryIdentifier,
					sourceRepositoryName: metadata.sourceRepositoryName, sourceAppIdentifier: id,
					sourceAppName: metadata.sourceAppName, sourceAppVersion: metadata.sourceAppVersion,
					sourceAppVersionDate: metadata.sourceAppVersionDate, sourceAppDownloadURL: metadata.sourceAppDownloadURL,
					expectedSHA256: nil
				)
			}
			let origin = metadata.flatMap { item in
				IPAOriginKind(rawValue: item.originKind ?? "").map { IPAImportOrigin(kind: $0, url: item.originURL) }
			}
			return (Entry(id: id, name: app.name, identifier: app.identifier, version: app.version, date: app.date,
				icon: app.icon, signed: app.isSigned, source: app.source,
				certificate: storage.getCertificate(from: app).flatMap(certificateHash), bundle: bundle.lastPathComponent,
				provenance: provenance, origin: origin, disabled: metadata?.updatesDisabled,
				skippedVersion: metadata?.skippedUpdateVersionID, pinnedSource: storage.pinnedUpdateSource(for: raw)), bundle)
		}
		let destination = parent.appendingPathComponent("Feather Migration " + UUID().uuidString.prefix(8), isDirectory: true)
		let physicalPath = parent.resolvingSymlinksInPath().path + "/"
		guard !entries.contains(where: { physicalPath.hasPrefix($0.1.resolvingSymlinksInPath().path + "/") }) else {
			throw CocoaError(.fileWriteInvalidFileName)
		}
		let completeManifest = try JSONEncoder().encode(Manifest(apps: entries.map(\.0)))
		let data = try await FeatherBackup.export(
			password: password, components: Set(FeatherBackup.Component.allCases),
			includePairing: true, migrationManifest: completeManifest
		)
		let written = try await Task.detached(priority: .utility) {
			try manager.createDirectory(at: destination, withIntermediateDirectories: false)
			do {
				let library = destination.appendingPathComponent(payload, isDirectory: true)
				try manager.createDirectory(at: library, withIntermediateDirectories: false)
				for (entry, bundle) in entries {
					let container = library.appendingPathComponent(entry.id.uuidString, isDirectory: true)
					try manager.createDirectory(at: container, withIntermediateDirectories: false)
					try manager.copyItem(at: bundle, to: container.appendingPathComponent(entry.bundle, isDirectory: true))
				}
				let archiveFolder = destination.appendingPathComponent(archives, isDirectory: true)
				try manager.createDirectory(at: archiveFolder, withIntermediateDirectories: false)
				for file in archiveFiles(in: manager.archives) {
					try manager.copyItem(at: file, to: archiveFolder.appendingPathComponent(file.lastPathComponent))
				}
				try data.write(to: destination.appendingPathComponent(settings), options: .atomic)
				try completeManifest.write(to: destination.appendingPathComponent(manifestName), options: .atomic)
				return destination.lastPathComponent
			} catch {
				try? manager.removeItem(at: destination)
				throw error
			}
		}.value
		return written
	}

	static func restore(from folder: URL, password: String) async throws -> [String] {
		let access = folder.startAccessingSecurityScopedResource()
		defer { if access { folder.stopAccessingSecurityScopedResource() } }
		let manager = FileManager.default
		let manifestURL = folder.appendingPathComponent(manifestName)
		let manifestInfo = try manifestURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
		guard manifestInfo.isRegularFile == true, manifestInfo.isSymbolicLink != true,
			let size = manifestInfo.fileSize, size <= 8 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
		let manifestData = try Data(contentsOf: manifestURL)
		let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
		guard manifest.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
		var errors = try await FeatherBackup.restore(
			file: folder.appendingPathComponent(settings), password: password,
			components: Set(FeatherBackup.Component.allCases), restorePairing: true, expectedMigrationManifest: manifestData
		)
		let storage = Storage.shared
		let imported = try storage.context.fetch(Imported.fetchRequest())
		let signed = try storage.context.fetch(Signed.fetchRequest())
		var existingIDs = Set((imported.map(\.uuid) + signed.map(\.uuid)).compactMap { $0 }.compactMap(UUID.init(uuidString:)))
		let certificates = Dictionary(storage.getAllCertificates().compactMap {
			certificate in certificateHash(certificate).map { ($0, certificate) }
		}, uniquingKeysWith: { first, _ in first })
		let library = folder.appendingPathComponent(payload, isDirectory: true)
		if !manifest.apps.isEmpty { try requireDirectory(library) }

		for entry in manifest.apps where !existingIDs.contains(entry.id) {
			let id = entry.id.uuidString
			let target = entry.signed ? manager.signed(id) : manager.unsigned(id)
			do {
				guard !entry.bundle.isEmpty, !entry.bundle.contains("/"), !entry.bundle.contains("\\"),
					entry.bundle.hasSuffix(".app") else { throw CocoaError(.fileReadCorruptFile) }
				let source = library.appendingPathComponent(id, isDirectory: true)
				try requireDirectory(source)
				let bundle = source.appendingPathComponent(entry.bundle, isDirectory: true)
				try requireDirectory(bundle)
				guard Bundle(url: bundle)?.bundleIdentifier == entry.identifier else { throw CocoaError(.fileReadCorruptFile) }
				let copied = target.appendingPathComponent(entry.bundle, isDirectory: true)
				try await Task.detached(priority: .utility) {
					guard !manager.fileExists(atPath: target.path) else { throw CocoaError(.fileWriteFileExists) }
					try manager.createDirectory(at: target, withIntermediateDirectories: true)
					do { try manager.copyItem(at: bundle, to: copied) }
					catch { try? manager.removeItem(at: target); throw error }
				}.value
				do {
					try storage.saveNewApp {
						if entry.signed {
							let record = Signed(context: storage.context)
							record.certificate = entry.certificate.flatMap { certificates[$0] }
							record.uuid = id; record.source = entry.source; record.date = entry.date
							record.identifier = entry.identifier; record.name = entry.name; record.version = entry.version; record.icon = entry.icon
						} else {
							let record = Imported(context: storage.context)
							record.uuid = id; record.source = entry.source; record.date = entry.date
							record.identifier = entry.identifier; record.name = entry.name; record.version = entry.version; record.icon = entry.icon
						}
						let kind: SourceLinkedAppKind = entry.signed ? .signed : .imported
						if let provenance = entry.provenance {
							storage.addSourceMetadata(for: id, kind: kind, provenance: provenance, deferSave: true)
						} else if let origin = entry.origin {
							storage.addImportMetadata(for: id, kind: kind, origin: origin, appIdentifier: entry.identifier,
								appName: entry.name, appVersion: entry.version, deferSave: true)
						}
						if let metadata = storage.sourceMetadata(for: id) {
							metadata.updatesDisabled = entry.disabled ?? false
							metadata.skippedUpdateVersionID = entry.skippedVersion
						}
					}
					if let pinned = entry.pinnedSource { storage.setPinnedUpdateSource(pinned, for: id) }
				} catch { try? manager.removeItem(at: target); throw error }
				existingIDs.insert(entry.id)
			} catch { errors.append((entry.name ?? entry.bundle) + " — " + error.localizedDescription) }
		}

		let archiveFolder = folder.appendingPathComponent(archives, isDirectory: true)
		if manager.fileExists(atPath: archiveFolder.path) { try requireDirectory(archiveFolder) }
		try manager.createDirectory(at: manager.archives, withIntermediateDirectories: true)
		for file in archiveFiles(in: archiveFolder) {
			let destination = manager.archives.appendingPathComponent(file.lastPathComponent)
			guard !manager.fileExists(atPath: destination.path) else { continue }
			do { try manager.copyItem(at: file, to: destination) }
			catch { errors.append(file.lastPathComponent + " — " + error.localizedDescription) }
		}
		return errors
	}

	private static func certificateHash(_ certificate: CertificatePair) -> String? {
		guard let url = Storage.shared.getFile(.certificate, from: certificate),
			let data = try? Data(contentsOf: url) else { return nil }
		return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}

	nonisolated private static func requireDirectory(_ url: URL) throws {
		let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
		guard values.isDirectory == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
	}

	nonisolated private static func archiveFiles(in directory: URL) -> [URL] {
		((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []).filter {
			guard ["ipa", "tipa"].contains($0.pathExtension.lowercased()),
				let values = try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
			return values.isRegularFile == true && values.isSymbolicLink != true
		}
	}
}
