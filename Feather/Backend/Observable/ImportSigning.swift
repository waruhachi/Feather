import CoreData
import UIKit

@MainActor
enum ImportSigning {
	static let preferenceKey = "Feather.signImportsWithRecipes"
	private static var pending: [String] = []
	private static var working = false

	static func enqueue(_ uuid: String) {
		guard UserDefaults.standard.bool(forKey: preferenceKey),
			UIApplication.shared.applicationState == .active, !pending.contains(uuid)
		else { return }
		pending.append(uuid)
		guard !working else { return }
		working = true
		Task {
			defer {
				pending.removeAll()
				working = false
			}
			while let next = pending.first, UIApplication.shared.applicationState == .active,
				UserDefaults.standard.bool(forKey: preferenceKey)
			{
				await sign(next)
				pending.removeFirst()
			}
		}
	}

	private static func sign(_ uuid: String) async {
		let storage = Storage.shared
		let request = Imported.fetchRequest()
		request.predicate = NSPredicate(format: "uuid == %@", uuid)
		request.fetchLimit = 1
		guard let app = (try? storage.context.fetch(request))?.first,
			let identifier = app.identifier, let target = SigningRecipe.lastTarget(for: identifier)
		else { return }

		let name = app.name ?? identifier
		do {
			guard let recipe = try SigningRecipe.load(for: target), let identity = recipe.certificateID,
				let certificate = storage.getAllCertificates().first(where: { $0.uuid == identity }),
				!certificate.revoked, let profile = storage.signingProfile(for: certificate, bundleID: target),
				profile.matchLength(for: target) != nil, profile.profile.ExpirationDate > Date()
			else { throw SigningPreflight.savedCertificateUnavailable }
			_ = try await FR.signPackage(app, using: recipe.options, icon: recipe.icon, certificate: certificate)
			await ActivityLog.shared.record(.init(action: .localized("Auto-Sign Import"), app: name, outcome: .localized("Completed")))
		} catch {
			await ActivityLog.shared.record(.init(action: .localized("Auto-Sign Import"), app: name, outcome: error.localizedDescription))
		}
	}
}
