//
//  Storage+SourceMetadata.swift
//  Feather
//
//  Created by Dominic on 26.05.2026.
//

import AltSourceKit
import CoreData
import Foundation

enum IPAOriginKind: String {
	case featherSource
	case localFile
	case remoteURL
	case unknown
}

enum UpdateProviderKind: String {
	case featherSource
	case appStore
	case github
	case gitlab
	case none
}

struct IPAImportOrigin: Equatable {
	let kind: IPAOriginKind
	let url: URL?

	static let localFile = IPAImportOrigin(kind: .localFile, url: nil)
	static let unknown = IPAImportOrigin(kind: .unknown, url: nil)

	static func remoteURL(_ url: URL) -> IPAImportOrigin {
		IPAImportOrigin(kind: .remoteURL, url: url)
	}

	static func featherSource(_ url: URL) -> IPAImportOrigin {
		IPAImportOrigin(kind: .featherSource, url: url)
	}
}

struct SourceAppProvenance: Equatable {
	let sourceRepositoryURL: URL
	let sourceRepositoryIdentifier: String?
	let sourceRepositoryName: String?
	let sourceAppIdentifier: String
	let sourceAppName: String?
	let sourceAppVersion: String?
	let sourceAppVersionDate: Date?
	let sourceAppDownloadURL: URL?

	var sourceVersionID: String {
		[
			UpdateProviderKind.featherSource.rawValue,
			sourceRepositoryIdentifier ?? sourceRepositoryURL.absoluteString,
			sourceAppIdentifier,
			sourceAppVersion ?? "",
			sourceAppDownloadURL?.absoluteString ?? "",
		].joined(separator: "|")
	}
}

enum SourceLinkedAppKind: String {
	case imported
	case signed
}

extension SourceAppProvenance {
	init?(
		sourceURL: URL?,
		repository: ASRepository,
		app: ASRepository.App,
		version: ASRepository.App.Version? = nil
	) {
		guard
			let sourceURL,
			let appIdentifier = app.id
		else {
			return nil
		}

		self.sourceRepositoryURL = sourceURL
		self.sourceRepositoryIdentifier = repository.id
		self.sourceRepositoryName = repository.name
		self.sourceAppIdentifier = appIdentifier
		self.sourceAppName = app.currentName
		let appVersion = version?.version ?? app.currentVersion
		let appVersionDate = version?.date?.date ?? app.currentDate?.date
		let appDownloadURL = version?.downloadURL ?? app.currentDownloadUrl
		self.sourceAppVersion = appVersion
		self.sourceAppVersionDate = appVersionDate
		self.sourceAppDownloadURL = appDownloadURL
	}
}

extension Storage {
	func sourceMetadata(for appUUID: String) -> AppSourceMetadata? {
		let request: NSFetchRequest<AppSourceMetadata> =
			AppSourceMetadata.fetchRequest()
		request.fetchLimit = 1
		request.predicate = NSPredicate(format: "appUUID == %@", appUUID)
		request.sortDescriptors = [
			NSSortDescriptor(key: "updatedAt", ascending: false)
		]

		do {
			return try context.fetch(request).first
		} catch {
			return nil
		}
	}

	func sourceMetadata(for app: AppInfoPresentable) -> AppSourceMetadata? {
		guard let uuid = app.uuid else { return nil }
		return sourceMetadata(for: uuid)
	}

	func getSourceMetadata() -> [AppSourceMetadata] {
		let request: NSFetchRequest<AppSourceMetadata> =
			AppSourceMetadata.fetchRequest()
		request.sortDescriptors = [
			NSSortDescriptor(key: "updatedAt", ascending: true)
		]
		do {
			return try context.fetch(request)
		} catch {
			return []
		}
	}

	func updatesDisabled(for appUUID: String?) -> Bool {
		guard let appUUID else { return false }
		return sourceMetadata(for: appUUID)?.updatesDisabled == true
	}

	func skippedUpdateVersionID(for appUUID: String?) -> String? {
		guard let appUUID else { return nil }
		return sourceMetadata(for: appUUID)?.skippedUpdateVersionID
	}

	func addSourceMetadata(
		for appUUID: String,
		kind: SourceLinkedAppKind,
		provenance: SourceAppProvenance
	) {
		let metadata =
			sourceMetadata(for: appUUID) ?? AppSourceMetadata(context: context)
		let now = Date()

		if metadata.createdAt == nil {
			metadata.createdAt = now
		}

		metadata.appUUID = appUUID
		metadata.appKind = kind.rawValue
		metadata.originKind = IPAOriginKind.featherSource.rawValue
		metadata.originURL = provenance.sourceRepositoryURL
		metadata.sourceRepositoryURL = provenance.sourceRepositoryURL
		metadata.sourceRepositoryIdentifier =
			provenance.sourceRepositoryIdentifier
		metadata.sourceRepositoryName = provenance.sourceRepositoryName
		metadata.sourceAppIdentifier = provenance.sourceAppIdentifier
		metadata.sourceAppName = provenance.sourceAppName
		metadata.sourceAppVersion = provenance.sourceAppVersion
		metadata.sourceAppVersionDate = provenance.sourceAppVersionDate
		metadata.sourceAppDownloadURL = provenance.sourceAppDownloadURL
		metadata.sourceVersionID = provenance.sourceVersionID
		metadata.updateProviderKind = UpdateProviderKind.featherSource.rawValue
		metadata.updateProviderURL = provenance.sourceRepositoryURL
		metadata.updateProviderIdentifier = provenance.sourceAppIdentifier
		metadata.updateProviderVersionID = provenance.sourceVersionID
		metadata.updateProviderDownloadURL = provenance.sourceAppDownloadURL
		metadata.updatesDisabled = false
		metadata.updatedAt = now

		saveContext()
	}

	func addImportMetadata(
		for appUUID: String,
		kind: SourceLinkedAppKind,
		origin: IPAImportOrigin,
		appIdentifier: String?,
		appName: String?,
		appVersion: String?
	) {
		let metadata =
			sourceMetadata(for: appUUID) ?? AppSourceMetadata(context: context)
		let now = Date()

		if metadata.createdAt == nil {
			metadata.createdAt = now
		}

		metadata.appUUID = appUUID
		metadata.appKind = kind.rawValue
		metadata.originKind = origin.kind.rawValue
		metadata.originURL = origin.url
		metadata.sourceAppIdentifier = appIdentifier
		metadata.sourceAppName = appName
		metadata.sourceAppVersion = appVersion
		metadata.sourceVersionID = [
			origin.kind.rawValue,
			appIdentifier ?? appUUID,
			appVersion ?? "",
		].joined(separator: "|")
		let providerKind = _defaultUpdateProviderKind(for: origin)
		metadata.sourceRepositoryURL =
			providerKind == .featherSource ? origin.url : nil
		metadata.updateProviderKind = providerKind.rawValue
		metadata.updateProviderURL =
			providerKind == .none ? nil : origin.url
		metadata.updateProviderIdentifier = appIdentifier
		metadata.updateProviderVersionID = nil
		metadata.updateProviderDownloadURL = nil
		metadata.updatesDisabled = false
		metadata.updatedAt = now

		saveContext()
	}

	func copySourceMetadata(
		from sourceAppUUID: String?,
		to destinationAppUUID: String,
		kind: SourceLinkedAppKind
	) {
		guard
			let sourceAppUUID
		else {
			return
		}

		guard let source = sourceMetadata(for: sourceAppUUID) else {
			return
		}

		let metadata =
			sourceMetadata(for: destinationAppUUID)
			?? AppSourceMetadata(context: context)
		let now = Date()
		if metadata.createdAt == nil {
			metadata.createdAt = now
		}
		metadata.appUUID = destinationAppUUID
		metadata.appKind = kind.rawValue
		metadata.originKind = source.originKind
		metadata.originURL = source.originURL
		metadata.sourceRepositoryURL = source.sourceRepositoryURL
		metadata.sourceRepositoryIdentifier = source.sourceRepositoryIdentifier
		metadata.sourceRepositoryName = source.sourceRepositoryName
		metadata.sourceAppIdentifier = source.sourceAppIdentifier
		metadata.sourceAppName = source.sourceAppName
		metadata.sourceAppVersion = source.sourceAppVersion
		metadata.sourceAppVersionDate = source.sourceAppVersionDate
		metadata.sourceAppDownloadURL = source.sourceAppDownloadURL
		metadata.sourceVersionID = source.sourceVersionID
		metadata.updateProviderKind = source.updateProviderKind
		metadata.updateProviderURL = source.updateProviderURL
		metadata.updateProviderIdentifier = source.updateProviderIdentifier
		metadata.updateProviderVersionID = source.updateProviderVersionID
		metadata.updateProviderDownloadURL = source.updateProviderDownloadURL
		metadata.updatesDisabled = source.updatesDisabled
		metadata.updatedAt = now

		saveContext()
	}

	func deleteSourceMetadata(for appUUID: String?) {
		guard let appUUID else {
			return
		}

		let request: NSFetchRequest<AppSourceMetadata> =
			AppSourceMetadata.fetchRequest()
		request.predicate = NSPredicate(format: "appUUID == %@", appUUID)

		do {
			let metadata = try context.fetch(request)
			metadata.forEach(context.delete)
			saveContext()
		} catch {
		}
	}

	func deleteSourceMetadata(kind: SourceLinkedAppKind) {
		let request: NSFetchRequest<AppSourceMetadata> =
			AppSourceMetadata.fetchRequest()
		request.predicate = NSPredicate(format: "appKind == %@", kind.rawValue)

		do {
			let deleteRequest = NSBatchDeleteRequest(
				fetchRequest: request as! NSFetchRequest<NSFetchRequestResult>
			)
			try context.execute(deleteRequest)
		} catch {
		}
	}

	func skipUpdate(for appUUID: String?, versionID: String) {
		guard
			let appUUID,
			let metadata = sourceMetadata(for: appUUID)
		else {
			return
		}

		metadata.skippedUpdateVersionID = versionID
		metadata.updatedAt = Date()
		saveContext()
	}

	func setUpdatesDisabled(for appUUID: String?, disabled: Bool) {
		guard
			let appUUID,
			let metadata = sourceMetadata(for: appUUID)
		else {
			return
		}

		metadata.updatesDisabled = disabled
		metadata.updatedAt = Date()
		saveContext()
	}

	func clearSkippedUpdate(for appUUID: String?) {
		guard
			let appUUID,
			let metadata = sourceMetadata(for: appUUID)
		else {
			return
		}

		metadata.skippedUpdateVersionID = nil
		metadata.updatedAt = Date()
		saveContext()
	}

	func remoteUpdateProviderKind(for url: URL) -> UpdateProviderKind {
		guard let host = url.host?.lowercased() else {
			return .none
		}

		if host == "github.com" || host.hasSuffix(".github.com") {
			return .github
		}

		if host == "gitlab.com" || host.hasSuffix(".gitlab.com") {
			return .gitlab
		}

		return .none
	}

	private func _defaultUpdateProviderKind(for origin: IPAImportOrigin)
		-> UpdateProviderKind
	{
		switch origin.kind {
		case .featherSource:
			return .featherSource
		case .remoteURL:
			guard let url = origin.url else { return .none }
			return remoteUpdateProviderKind(for: url)
		case .localFile, .unknown:
			return .none
		}
	}
}
