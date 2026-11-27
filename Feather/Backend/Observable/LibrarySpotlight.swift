import CoreData
import CoreSpotlight
import UniformTypeIdentifiers

@MainActor
enum LibrarySpotlight {
	private static let domain = "Feather.Library"
	private static let prefix = "Feather.Library:"
	private static let storedIdentifiers = "Feather.spotlightLibraryIdentifiers"
	private static var pending = false
	private static var working = false

	static func schedule() {
		guard CSSearchableIndex.isIndexingAvailable() else { return }
		pending = true
		guard !working else { return }
		working = true
		Task {
			defer { working = false }
			while pending {
				pending = false
				try? await refresh()
			}
		}
	}

	static func appID(from activity: NSUserActivity) -> String? {
		guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
			identifier.hasPrefix(prefix) else { return nil }
		return String(identifier.dropFirst(prefix.count))
	}

	private static func refresh() async throws {
		let context = Storage.shared.context
		let imports = try context.fetch(Imported.fetchRequest())
		let signed = try context.fetch(Signed.fetchRequest())
		let apps = imports.map { $0 as AppInfoPresentable } + signed.map { $0 as AppInfoPresentable }
		let items = apps.compactMap { app -> CSSearchableItem? in
			guard let uuid = app.uuid, let name = app.name else { return nil }
			let attributes = CSSearchableItemAttributeSet(contentType: .item)
			attributes.title = name
			attributes.contentDescription = app.isSigned ? .localized("Signed in Feather") : .localized("Imported into Feather")
			return CSSearchableItem(uniqueIdentifier: prefix + uuid, domainIdentifier: domain, attributeSet: attributes)
		}
		let index = CSSearchableIndex.default()
		let defaults = UserDefaults.standard
		let current = Set(items.map(\.uniqueIdentifier))
		let previous = Set(defaults.stringArray(forKey: storedIdentifiers) ?? [])
		let deleted = Array(previous.subtracting(current))
		if !items.isEmpty { try await index.indexSearchableItems(items) }
		if !deleted.isEmpty { try await index.deleteSearchableItems(withIdentifiers: deleted) }
		defaults.set(Array(current), forKey: storedIdentifiers)
	}
}
