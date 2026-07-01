//
//  Persistence.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//

import CoreData
import Foundation

// MARK: - Storage
final class Storage: ObservableObject {
	static let shared = Storage()
	let container: NSPersistentContainer

	private let _name: String = "Feather"

	init(inMemory: Bool = false) {
		container = NSPersistentContainer(name: _name)

		if inMemory {
			container.persistentStoreDescriptions.first?.url =
				URL(fileURLWithPath: "/dev/null")
		}

		container.persistentStoreDescriptions.first?
			.shouldMigrateStoreAutomatically = true
		container.persistentStoreDescriptions.first?
			.shouldInferMappingModelAutomatically = true

		_loadPersistentStore()
		container.viewContext.automaticallyMergesChangesFromParent = true
		container.viewContext.mergePolicy =
			NSMergeByPropertyObjectTrumpMergePolicy
	}

	var context: NSManagedObjectContext {
		container.viewContext
	}

	func saveContext() {
		context.performAndWait {
			if context.hasChanges {
				try? context.save()
			}
		}
	}

	func clearContext<T: NSManagedObject>(request: NSFetchRequest<T>) {
		let deleteRequest = NSBatchDeleteRequest(
			fetchRequest: (request as? NSFetchRequest<NSFetchRequestResult>)!
		)
		_ = try? context.execute(deleteRequest)
	}

	func countContent<T: NSManagedObject>(for type: T.Type) -> String {
		let request = T.fetchRequest()
		return "\((try? context.count(for: request)) ?? 0)"
	}

	private func _loadPersistentStore() {
		container.loadPersistentStores { _, error in
			if let error {
				fatalError("Core Data unrecoverable: \(error)")
			}
		}
	}
}
