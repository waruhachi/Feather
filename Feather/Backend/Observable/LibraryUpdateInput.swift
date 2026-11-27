import CoreData
import Foundation

@MainActor
enum LibraryUpdateInput {
	private static var active = Set<String>()

	static func acquire(_ uuid: String) -> Bool { active.insert(uuid).inserted }
	static func release(_ uuid: String) { active.remove(uuid) }

	enum Failure: LocalizedError {
		case unavailable, identifierMismatch, installUnconfirmed, inProgress

		var errorDescription: String? {
			switch self {
			case .unavailable: .localized("This update is no longer available. Check for updates again.")
			case .identifierMismatch: .localized("The downloaded app does not match the original bundle identifier. It was added to the Library without signing.")
			case .installUnconfirmed: .localized("Feather could not confirm installation.")
			case .inProgress: .localized("An update for this app is already in progress.")
			}
		}
	}

	static func checkAll() async throws -> Bool {
		let storage = Storage.shared
		let signed = try storage.context.fetch(Signed.fetchRequest())
		let imported = try storage.context.fetch(Imported.fetchRequest())
		let apps: [AppInfoPresentable] = signed.map { $0 as AppInfoPresentable } + imported.map { $0 as AppInfoPresentable }
		return await UpdateManager.shared.checkForUpdates(sources: storage.getSources(), localApps: apps)
	}

	static func download(_ update: AppUpdate, inBackground: Bool = false) async throws -> Imported {
		guard UpdateManager.shared.canApply(update), let url = update.downloadURL else { throw Failure.unavailable }
		let uuid: String
		if inBackground {
			let (file, response) = try await URLSession.shared.download(from: url)
			defer { try? FileManager.default.removeItem(at: file) }
			guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
				throw URLError(.badServerResponse)
			}
			try Task.checkCancellation()
			uuid = try await FR.importPackage(file, sourceProvenance: update.sourceProvenance, importOrigin: .remoteURL(update.sourceURL ?? url))
			Storage.shared.inheritUpdateSource(from: update.localUUID, to: uuid)
		} else {
			uuid = try await withCheckedThrowingContinuation { continuation in
				_ = DownloadManager.shared.startDownload(
					from: url,
					id: "FeatherManualDownload_Update_\(UUID().uuidString)",
					sourceProvenance: update.sourceProvenance,
					importOrigin: update.sourceProvenance == nil ? .remoteURL(update.sourceURL ?? url) : nil,
					updateFromUUID: update.localUUID,
					onImport: { continuation.resume(with: $0) }
				)
			}
		}
		let request = Imported.fetchRequest()
		request.predicate = NSPredicate(format: "uuid == %@", uuid)
		guard let imported = try Storage.shared.context.fetch(request).first else { throw Failure.unavailable }
		return imported
	}

	static func checkIdentifier(_ app: Imported, update: AppUpdate) throws {
		let original = Storage.shared.sourceMetadata(for: update.localUUID)?.sourceAppIdentifier ?? update.bundleIdentifier
		guard app.identifier == original else { throw Failure.identifierMismatch }
	}
}
