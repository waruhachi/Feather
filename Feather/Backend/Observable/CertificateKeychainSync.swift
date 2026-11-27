import CryptoKit
import Foundation
import Security

@MainActor
enum CertificateKeychainSync {
	static let enabledKey = "Feather.iCloudCertificateSync"
	private static let removedKey = "Feather.iCloudCertificateSync.removed"
	private static let service = "Feather.CertificateSync"
	private static var working = false
	private static var lastAutomaticSync: Date?

	struct Result {
		var added = 0
		var uploaded = 0
		var problems: [String] = []
	}

	static func syncIfDue() async {
		guard UserDefaults.standard.bool(forKey: enabledKey), !working,
			Date().timeIntervalSince(lastAutomaticSync ?? .distantPast) >= 3600 else { return }
		lastAutomaticSync = Date()
		_ = try? await sync()
	}

	static func sync() async throws -> Result {
		guard UserDefaults.standard.bool(forKey: enabledKey), !working else { throw CancellationError() }
		working = true
		defer { working = false }
		let defaults = UserDefaults.standard
		let remote = try items()
		var result = Result()
		var known = Set<String>()
		for certificate in Storage.shared.getAllCertificates() where canSync(certificate) {
			guard defaults.bool(forKey: enabledKey) else { throw CancellationError() }
			do {
				guard var identity = try FeatherBackup.captureIdentity(certificate) else { continue }
				let account = fingerprint(identity)
				known.insert(account)
				if let previous = remote[account] {
					var profiles = Set(identity.additionalProfiles ?? [])
					identity.additionalProfiles = (identity.additionalProfiles ?? [])
						+ (previous.additionalProfiles ?? []).filter { profiles.insert($0).inserted }
					result.problems += try await FeatherBackup.restoreIdentity(identity).problems
				}
				guard defaults.bool(forKey: enabledKey) else { throw CancellationError() }
				if try save(identity, account: account, previous: remote[account]) { result.uploaded += 1 }
			} catch is CancellationError {
				throw CancellationError()
			} catch {
				result.problems.append(error.localizedDescription)
			}
		}
		for (account, identity) in remote where !known.contains(account) {
			guard defaults.bool(forKey: enabledKey) else { throw CancellationError() }
			if (defaults.stringArray(forKey: removedKey) ?? []).contains(account) { continue }
			do {
				let restored = try await FeatherBackup.restoreIdentity(identity)
				if restored.added { result.added += 1 }
				result.problems += restored.problems
			} catch {
				result.problems.append(error.localizedDescription)
			}
		}
		return result
	}

	static func forget(_ certificate: CertificatePair) {
		guard UserDefaults.standard.bool(forKey: enabledKey), canSync(certificate),
			let identity = try? FeatherBackup.captureIdentity(certificate) else { return }
		let account = fingerprint(identity)
		let defaults = UserDefaults.standard
		var removed = Set(defaults.stringArray(forKey: removedKey) ?? [])
		removed.insert(account)
		defaults.set(Array(removed), forKey: removedKey)
	}

	private static func canSync(_ certificate: CertificatePair) -> Bool {
		guard !certificate.isDefault, !certificate.revoked else { return false }
		#if os(iOS) && !targetEnvironment(macCatalyst)
		return !AppleIDProvisioning.isLocalIdentity(certificate)
		#else
		return true
		#endif
	}

	private static func fingerprint(_ identity: FeatherBackup.Identity) -> String {
		var hasher = SHA256()
		hasher.update(data: Data(SHA256.hash(data: identity.certificate)))
		hasher.update(data: Data(SHA256.hash(data: identity.provision)))
		return hasher.finalize().map { String(format: "%02x", $0) }.joined()
	}

	private static var query: [String: Any] {
		[kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
		 kSecAttrSynchronizable as String: true, kSecUseDataProtectionKeychain as String: true]
	}

	private static func items() throws -> [String: FeatherBackup.Identity] {
		var filter = query
		filter[kSecMatchLimit as String] = kSecMatchLimitAll
		filter[kSecReturnAttributes as String] = true
		filter[kSecReturnData as String] = true
		var response: CFTypeRef?
		let status = SecItemCopyMatching(filter as CFDictionary, &response)
		if status == errSecItemNotFound { return [:] }
		try check(status)
		var items: [String: FeatherBackup.Identity] = [:]
		for entry in response as? [[String: Any]] ?? [] {
			guard let account = entry[kSecAttrAccount as String] as? String,
				let data = entry[kSecValueData as String] as? Data,
				let identity = try? PropertyListDecoder().decode(FeatherBackup.Identity.self, from: data),
				account == fingerprint(identity) else { continue }
			items[account] = identity
		}
		return items
	}

	private static func save(_ identity: FeatherBackup.Identity, account: String, previous: FeatherBackup.Identity?) throws -> Bool {
		if let previous, Set(previous.additionalProfiles ?? []) == Set(identity.additionalProfiles ?? []) { return false }
		let data = try PropertyListEncoder().encode(identity)
		var filter = query
		filter[kSecAttrAccount as String] = account
		let values = [kSecValueData as String: data]
		let status = SecItemUpdate(filter as CFDictionary, values as CFDictionary)
		if status == errSecItemNotFound {
			filter[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
			filter[kSecValueData as String] = data
			let added = SecItemAdd(filter as CFDictionary, nil)
			if added == errSecDuplicateItem { return false }
			try check(added)
		} else {
			try check(status)
		}
		return true
	}

	private static func check(_ status: OSStatus) throws {
		guard status == errSecSuccess else {
			throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
				NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? .localized("iCloud Keychain is unavailable.")
			])
		}
	}
}
