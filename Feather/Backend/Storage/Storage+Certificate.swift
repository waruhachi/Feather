//
//  Storage+Certificate.swift
//  Feather
//
//  Created by samara on 16.04.2025.
//

import CoreData
import UIKit.UIImpactFeedbackGenerator

// MARK: - Class extension: certificate
extension Storage {
	@MainActor
	func addCertificate(
		uuid: String,
		password: String? = nil,
		nickname: String? = nil,
		ppq: Bool = false,
		expiration: Date,
		isDefault: Bool = false,
		completion: @escaping (Error?) -> Void
	) {


		let new = CertificatePair(context: context)
		new.uuid = uuid
		new.date = Date()
		new.password = password
		new.ppQCheck = ppq
		new.expiration = expiration
		new.nickname = nickname
		new.isDefault = isDefault
		saveContext()
		revokagedCertificate(for: new)
		FeatherHaptics.action()
		completion(nil)
	}

	func deleteCertificate(for cert: CertificatePair) {
		if let url = getUuidDirectory(for: cert) {
			try? FileManager.default.removeItem(at: url)
		}
		context.delete(cert)
		saveContext()
	}

	func getCertificate(for index: Int) -> CertificatePair? {
		let fetchRequest: NSFetchRequest<CertificatePair> =
			CertificatePair.fetchRequest()
		fetchRequest.sortDescriptors = [
			NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)
		]

		guard
			let results = try? context.fetch(fetchRequest),
			index >= 0 && index < results.count
		else {
			return nil
		}

		return results[index]
	}

	@MainActor
	func revokagedCertificate(for cert: CertificatePair) {
		Task { await refreshRevocation(for: cert) }
	}

	@MainActor
	func refreshRevocation(for cert: CertificatePair) async {
		guard !cert.revoked, let p12 = getFile(.certificate, from: cert) else { return }
		let password = cert.password ?? ""
		let certificateID = cert.objectID
		let result = await Task.detached(priority: .utility) {
			CertificateRevocation.check(p12: p12, password: password)
		}.value
		guard !Task.isCancelled, result == .revoked,
			let stored = (try? context.existingObject(with: certificateID)) as? CertificatePair,
			!stored.isDeleted
		else { return }
		stored.revoked = true
		saveContext()
		if let id = stored.uuid {
			await FeatherAlerts.shared.showCertificate(id: id, name: stored.nickname ?? .localized("Certificate"), expiry: stored.expiration, revoked: true)
		}
	}

	enum FileRequest: String {
		case certificate = "p12"
		case provision = "mobileprovision"
	}

	func getFile(_ type: FileRequest, from cert: CertificatePair) -> URL? {
		guard let url = getUuidDirectory(for: cert) else {
			return nil
		}

		return FileManager.default.getPath(in: url, for: type.rawValue)
	}

	func getProvisionFileDecoded(for cert: CertificatePair) -> Certificate? {
		guard let url = getFile(.provision, from: cert) else {
			return nil
		}

		let read = CertificateReader(url)
		return read.decoded
	}

	func getUuidDirectory(for cert: CertificatePair) -> URL? {
		guard let uuid = cert.uuid else {
			return nil
		}

		return FileManager.default.certificates(uuid)
	}

	func getAllCertificates() -> [CertificatePair] {
		let fetchRequest: NSFetchRequest<CertificatePair> =
			CertificatePair.fetchRequest()
		fetchRequest.sortDescriptors = [
			NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)
		]
		return (try? context.fetch(fetchRequest)) ?? []
	}
}
