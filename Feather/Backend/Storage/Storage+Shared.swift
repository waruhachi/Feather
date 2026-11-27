//
//  Storage+Shared.swift
//  Feather
//
//  Created by samara on 17.04.2025.
//

import CoreData
import Foundation

extension Notification.Name {
	static let featherInstallApp = Notification.Name("Feather.installApp")
	static let featherImportedAppDidFinish = Notification.Name(
		"Feather.importedAppDidFinish"
	)
}

// MARK: - Class extension: Apps (Shared)
extension Storage {
	@MainActor
	func saveNewApp(inserting records: () -> Void) throws {
		let prior = context.insertedObjects
		records()
		let created = context.insertedObjects.subtracting(prior)
		do {
			try context.save()
		} catch {
			for object in created { context.delete(object) }
			throw error
		}
		FeatherHaptics.action()
	}

	func getUuidDirectory(for app: AppInfoPresentable) -> URL? {
		guard let uuid = app.uuid else { return nil }
		return app.isSigned
			? FileManager.default.signed(uuid)
			: FileManager.default.unsigned(uuid)
	}

	func getAppDirectory(for app: AppInfoPresentable) -> URL? {
		guard let url = getUuidDirectory(for: app) else { return nil }
		return FileManager.default.getPath(in: url, for: "app")
	}

	func deleteApp(for app: AppInfoPresentable) {
		do {
			if let url = getUuidDirectory(for: app) {
				try? FileManager.default.removeItem(at: url)
			}
			deleteSourceMetadata(for: app.uuid)
			if let object = app as? NSManagedObject {
				context.delete(object)
			}
			saveContext()
		}
	}

	@MainActor
	func finishInstall(_ app: AppInfoPresentable, protecting protectedIDs: Set<String>) {
		let defaults = UserDefaults.standard
		if let installed = app as? Signed, let identifier = installed.identifier, let version = installed.version {
			let request = Signed.fetchRequest()
			request.predicate = NSPredicate(format: "identifier == %@", identifier)
			for copy in (try? context.fetch(request)) ?? [] {
				guard copy.objectID != installed.objectID, let uuid = copy.uuid, !protectedIDs.contains(uuid),
					let otherVersion = copy.version else { continue }
				let key: String
				switch otherVersion.compare(version, options: .numeric) {
				case .orderedAscending: key = "Feather.deleteOlderSignedCopies"
				case .orderedSame: key = "Feather.deleteEqualSignedCopies"
				case .orderedDescending: key = "Feather.deleteNewerSignedCopies"
				}
				if defaults.bool(forKey: key) { deleteApp(for: copy) }
			}
			if defaults.bool(forKey: "Feather.deleteInstalledSignedCopy") { deleteApp(for: installed) }
		}
		if defaults.bool(forKey: "Feather.clearCacheAfterInstall") { ResetView.clearNetworkCache() }
	}

	func getCertificate(from app: AppInfoPresentable) -> CertificatePair? {
		if let signed = app as? Signed {
			return signed.certificate
		}
		return nil
	}
}

// MARK: - Helpers
struct AnyApp: Identifiable {
	let base: AppInfoPresentable
	var archive: Bool = false
	var injectAndExport: Bool = false

	var id: String {
		base.uuid ?? UUID().uuidString
	}
}

protocol AppInfoPresentable {
	var name: String? { get }
	var version: String? { get }
	var identifier: String? { get }
	var date: Date? { get }
	var icon: String? { get }
	var uuid: String? { get }
	var source: URL? { get }
	var isSigned: Bool { get }

}

extension Signed: AppInfoPresentable {
	var isSigned: Bool { true }
}

extension Imported: AppInfoPresentable {
	var isSigned: Bool { false }
}
