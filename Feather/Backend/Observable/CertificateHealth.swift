import CoreData
import Foundation

@MainActor
enum CertificateHealth {
	private static let checkedKey = "Feather.certificateHealthLastChecked"

	static func checkIfDue() async {
		let defaults = UserDefaults.standard
		guard defaults.bool(forKey: FeatherAlerts.certificatesKey) else { return }
		let last = defaults.object(forKey: checkedKey) as? Date ?? .distantPast
		let checkRevocation = Date().timeIntervalSince(last) >= 24 * 3600
		let storage = Storage.shared
		for certificate in storage.getAllCertificates() {
			guard !Task.isCancelled else { return }
			if checkRevocation, !certificate.revoked {
				await storage.refreshRevocation(for: certificate)
			}
			guard !certificate.isDeleted, let uuid = certificate.uuid else { continue }
			let name = certificate.nickname ?? .localized("Certificate")
			if certificate.revoked {
				await FeatherAlerts.shared.showCertificate(id: uuid, name: name, expiry: nil, revoked: true)
			} else {
				for profile in storage.signingProfiles(for: certificate) {
					await FeatherAlerts.shared.showCertificate(
						id: uuid + "|" + profile.id,
						name: profile.profile.Name,
						expiry: profile.profile.ExpirationDate,
						revoked: false
					)
				}
			}
		}
		if checkRevocation && !Task.isCancelled { defaults.set(Date(), forKey: checkedKey) }
	}
}
