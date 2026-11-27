#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import NimbleExtensions
import Security
import SideSign
import UIKit

@MainActor
final class AppleIDProvisioning: ObservableObject {
	static let shared = AppleIDProvisioning()
	static let deviceKey = "Feather.appleID.deviceUDID"
	static let serverKey = "Feather.appleID.anisetteServer"
	static let defaultServer = "https://ani.sidestore.zip"

	struct AccountSession: Codable {
		let authentication: AuthSession
		let teamID: String
		let teamName: String
		let free: Bool
		let server: URL
	}
	struct DeveloperCertificate: Identifiable {
		let id: String
		let name: String
		let expires: Date
		let isCurrent: Bool
	}

	private struct SigningIdentity: Codable {
		let account: String
		let teamID: String
		let serial: String
		let p12: Data
		let password: String
		var certificateID: String?
	}
	private static let sessionKey = "apple-session"
	private static let identityKey = "apple-signing-identity"
	private static let localIdentitiesKey = "Feather.appleID.localCertificates"

	@Published private(set) var account = read(AccountSession.self, key: sessionKey)
	@Published private(set) var teams: [Team] = []
	@Published private(set) var working = false

	private let portal = DeveloperPortal.shared
	private var awaitingCode: CheckedContinuation<TwoFactorResponse, Error>?

	static func isLocalIdentity(_ certificate: CertificatePair) -> Bool {
		guard let id = certificate.uuid else { return false }
		return (UserDefaults.standard.stringArray(forKey: localIdentitiesKey) ?? []).contains(id)
			|| read(SigningIdentity.self, key: identityKey)?.certificateID == id
			|| certificate.nickname?.hasPrefix("Apple ID · ") == true
	}

	func signIn(email: String, password: String, serverAddress: String) async throws {
		guard !working else { throw Failure.busy }
		working = true
		defer { working = false }
		guard let server = URL(string: serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)),
			server.scheme?.lowercased() == "https", server.host?.isEmpty == false,
			server.user == nil, server.password == nil
		else { throw Failure.invalidServer }
		let (anisette, activeServer) = try await signInAnisette(server)
		let authentication = try await portal.authenticate(
			appleID: email.trimmingCharacters(in: .whitespacesAndNewlines),
			password: password, anisetteData: anisette, xcodeVersion: "26.0 (26A242)",
			machinePassword: nil, accountRepairHandler: DeveloperPortal.defaultAccountRepairHandler,
			verificationHandler: { request in try await self.askForCode(request) }
		)
		let available = try await portal.fetchTeams(for: authentication.account, session: authentication.session)
		guard let team = available.first(where: { $0.identifier == account?.teamID })
			?? available.first(where: { $0.type == .free }) ?? available.first
		else { throw Failure.noTeam }
		try save(authentication, team: team, server: activeServer)
		teams = available
	}

	func selectTeam(_ identifier: String) throws {
		guard let account, let team = teams.first(where: { $0.identifier == identifier }) else { return }
		try save(account.authentication, team: team, server: account.server)
	}

	func signOut() throws {
		try Self.write(nil, key: Self.sessionKey)
		try Self.write(nil, key: Self.identityKey)
		account = nil
		teams = []
	}

	func prepare(bundleID: String, name: String) async throws -> CertificatePair {
		guard !working else { throw Failure.busy }
		guard let account, !account.authentication.session.isExpired else { throw Failure.signInRequired }
		guard let udid = deviceIdentifier(),
			udid.range(of: #"^(?:[A-Fa-f0-9]{40}|[A-Fa-f0-9]{8}-[A-Fa-f0-9]{16})$"#, options: .regularExpression) != nil
		else { throw Failure.missingDevice }
		working = true
		defer { working = false }
		let authentication = account.authentication
		let (team, session) = try await developerSession()

		let certificates = try await portal.fetchCertificates(for: team, session: session)
		let email = authentication.account.appleID
		var identity: SigningIdentity
		if let previous = Self.read(SigningIdentity.self, key: Self.identityKey),
			previous.account.caseInsensitiveCompare(email) == .orderedSame, previous.teamID == team.identifier,
			certificates.contains(where: { $0.serialNumberHex.caseInsensitiveCompare(previous.serial) == .orderedSame })
		{
			identity = previous
		} else {
			let key = try await portal.addCertificate(machineName: "Feather - \(UIDevice.current.name)", type: .development, to: team, session: session)
			let password = UUID().uuidString
			identity = SigningIdentity(account: email, teamID: team.identifier, serial: key.certificate.serialNumberHex, p12: try key.exportP12(password: password), password: password)
			try Self.write(JSONEncoder().encode(identity), key: Self.identityKey)
		}

		let type: DeviceType = UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
		let devices = try await portal.fetchDevices(for: team, types: .all, session: session)
		if !devices.contains(where: { $0.identifier.caseInsensitiveCompare(udid) == .orderedSame }) {
			_ = try await portal.registerDevice(name: UIDevice.current.name, identifier: udid, type: type, team: team, session: session)
		}
		let entries = try await portal.fetchAppIDs(for: team, session: session)
		let appID = try await appID(for: bundleID, name: name, entries: entries, team: team, session: session)
		let profile = try await portal.downloadProvisioningProfile(for: appID, deviceType: type, team: team, session: session)

		let storage = Storage.shared
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
		defer { try? FileManager.default.removeItem(at: directory) }
		let provision = directory.appendingPathComponent("Feather.mobileprovision")
		try profile.data.write(to: provision, options: [.atomic, .completeFileProtection])
		if let existing = storage.getAllCertificates().first(where: { $0.uuid == identity.certificateID && !($0.revoked) }),
			let parsed = CertificateReader(provision).decoded
		{
			if !storage.signingProfiles(for: existing).contains(where: { $0.id == parsed.UUID }) {
				try storage.addSigningProfile(profile.data, to: existing)
			}
			return existing
		}

		let key = directory.appendingPathComponent("Feather.p12")
		try identity.p12.write(to: key, options: [.atomic, .completeFileProtection])
		let handler = CertificateFileHandler(key: key, provision: provision, password: identity.password, nickname: "Apple ID · " + account.teamName)
		try await handler.copy()
		try await handler.addToDatabase()
		guard let new = storage.getAllCertificates().first(where: { $0.uuid == handler.identifier }) else { throw Failure.noIdentity }
		identity.certificateID = handler.identifier
		let defaults = UserDefaults.standard
		var issued = Set(defaults.stringArray(forKey: Self.localIdentitiesKey) ?? [])
		issued.insert(handler.identifier)
		defaults.set(Array(issued), forKey: Self.localIdentitiesKey)
		try Self.write(JSONEncoder().encode(identity), key: Self.identityKey)
		return new
	}

	func prepareExtensionProfiles(in app: URL, rootID: String, certificate: CertificatePair) async throws -> [URL] {
		let bundles = try extensionBundles(in: app, rootID: rootID)
		guard !bundles.isEmpty else { return [] }

		guard !working else { throw Failure.busy }
		guard let udid = deviceIdentifier(),
			let account, let identity = Self.read(SigningIdentity.self, key: Self.identityKey),
			let certificateID = certificate.uuid, certificateID == identity.certificateID,
			identity.account.caseInsensitiveCompare(account.authentication.account.appleID) == .orderedSame,
			identity.teamID == account.teamID
		else { throw Failure.noIdentity }
		working = true
		defer { working = false }
		let storage = Storage.shared
		let properties = storage.signingProfiles(for: certificate)
		var profiles: [URL] = []
		let (team, session) = try await developerSession()
		let entries = try await portal.fetchAppIDs(for: team, session: session)
		let type: DeviceType = UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone

		for extensionBundle in bundles {
			try Task.checkCancellation()
			if let existing = properties.first(where: {
				$0.explicitBundleIdentifier == extensionBundle.id && $0.profile.ExpirationDate > Date()
					&& $0.profile.ProvisionedDevices?.contains(where: { $0.caseInsensitiveCompare(udid) == .orderedSame }) == true
			}) {
				profiles.append(existing.url)
				continue
			}
			let id = try await appID(for: extensionBundle.id, name: extensionBundle.name, entries: entries, team: team, session: session)
			let profile = try await portal.downloadProvisioningProfile(for: id, deviceType: type, team: team, session: session)
			try storage.addSigningProfile(profile.data, to: certificate)
			guard let saved = storage.signingProfiles(for: certificate).first(where: {
				$0.explicitBundleIdentifier == extensionBundle.id && $0.profile.ExpirationDate > Date()
					&& $0.profile.ProvisionedDevices?.contains(where: { $0.caseInsensitiveCompare(udid) == .orderedSame }) == true
			}) else { throw Failure.invalidExtension(extensionBundle.name) }
			profiles.append(saved.url)
		}
		return profiles
	}

	private func extensionBundles(in app: URL, rootID: String) throws -> [(id: String, name: String)] {
		let manager = FileManager.default
		var enumerationError: Error?
		let files = manager.enumerator(
			at: app, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]
		) { _, error in
			enumerationError = error
			return false
		}
		guard let files else { throw CocoaError(.fileReadUnknown) }
		var bundles: [(id: String, name: String)] = []
		var seen = Set<String>()
		for case let url as URL in files {
			let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
			if values.isSymbolicLink == true { files.skipDescendants(); continue }
			guard values.isDirectory == true, ["appex", "app"].contains(url.pathExtension) else { continue }
			guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
				id.hasPrefix(rootID + "."), seen.insert(id).inserted
			else { throw Failure.invalidExtension(url.lastPathComponent) }
			bundles.append((id, bundle.name))
		}
		if let enumerationError { throw enumerationError }
		return bundles
	}

	private func appID(for bundleID: String, name: String, entries: [AppID], team: Team, session: Session) async throws -> AppID {
		if let entry = entries.first(where: { $0.bundleIdentifier == bundleID }) { return entry }
		let allowed = CharacterSet.alphanumerics.union(.whitespaces)
		let cleaned = String(name.unicodeScalars.filter { allowed.contains($0) }).trimmingCharacters(in: .whitespaces)
		let name = cleaned.isEmpty ? "Feather App" : String(cleaned.prefix(50))
		return try await portal.addAppID(withName: name, bundleIdentifier: bundleID, team: team, session: session)
	}

	func developerCertificates() async throws -> [DeveloperCertificate] {
		guard !working else { throw Failure.busy }
		working = true
		defer { working = false }
		let (team, session) = try await developerSession()
		let identity = Self.read(SigningIdentity.self, key: Self.identityKey)
		return try await portal.fetchCertificates(for: team, session: session).map { cert in
			DeveloperCertificate(
				id: cert.serialNumberHex,
				name: cert.name,
				expires: cert.expiryDate,
				isCurrent: identity?.teamID == team.identifier && identity?.serial == cert.serialNumberHex
			)
		}
	}

	func revokeDeveloperCertificate(_ certificate: DeveloperCertificate) async throws {
		guard !working else { throw Failure.busy }
		working = true
		defer { working = false }
		let (team, session) = try await developerSession()
		let certificates = try await portal.fetchCertificates(for: team, session: session)
		guard let selected = certificates.first(where: { $0.serialNumberHex == certificate.id }) else { return }
		guard try await portal.revokeCertificate(selected, for: team, session: session) else {
			throw Failure.revokeFailed
		}

		let identity = Self.read(SigningIdentity.self, key: Self.identityKey)
		if identity?.teamID == team.identifier, identity?.serial == certificate.id {
			let storage = Storage.shared
			if let id = identity?.certificateID,
				let stored = storage.getAllCertificates().first(where: { $0.uuid == id })
			{
				stored.revoked = true
				storage.saveContext()
				await FeatherAlerts.shared.showCertificate(
					id: id, name: stored.nickname ?? .localized("Certificate"), expiry: nil, revoked: true
				)
			}
			try Self.write(nil, key: Self.identityKey)
		}
	}

	private func developerSession() async throws -> (Team, Session) {
		guard let account, !account.authentication.session.isExpired else { throw Failure.signInRequired }
		let team = Team(
			identifier: account.teamID, name: account.teamName,
			type: account.free ? .free : .individual, account: account.authentication.account
		)
		var session = account.authentication.session
		session.anisetteData = try await fetchAnisette(account.server)
		return (team, session)
	}

	private func save(_ authentication: AuthSession, team: Team, server: URL) throws {
		let session = AccountSession(authentication: authentication, teamID: team.identifier, teamName: team.name, free: team.type == .free, server: server)
		try Self.write(JSONEncoder().encode(session), key: Self.sessionKey)
		account = session
	}

	private func deviceIdentifier() -> String? {
		if let manual = UserDefaults.standard.string(forKey: Self.deviceKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !manual.isEmpty {
			return manual
		}
		let pairing = URL.documentsDirectory.appendingPathComponent("pairingFile.plist")
		guard let data = try? Data(contentsOf: pairing),
			let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
		return (plist["UDID"] as? String) ?? (plist["UniqueDeviceID"] as? String)
	}

	private func signInAnisette(_ server: URL) async throws -> (AnisetteData, URL) {
		do {
			return (try await fetchAnisette(server), server)
		} catch {
			try Task.checkCancellation()
			guard server.absoluteString == Self.defaultServer else { throw error }
			for address in ["https://ani.sidestore.io", "https://ani.sidestore.app"] {
				guard let fallback = URL(string: address) else { continue }
				if let data = try? await fetchAnisette(fallback) { return (data, fallback) }
				try Task.checkCancellation()
			}
			throw error
		}
	}

	private func fetchAnisette(_ server: URL) async throws -> AnisetteData {
		let key = "anisette|" + server.absoluteString
		let id = Self.read(UUID.self, key: key + "|id") ?? UUID()
		try Self.write(JSONEncoder().encode(id), key: key + "|id")
		let (anisette, blob) = try await AnisetteDataManager.shared.fetchAnisetteData(
			mode: .remote(server: server), identifier: id, existingAdiBlob: Self.data(key), headers: nil, onError: nil
		)
		if let blob { try Self.write(blob, key: key) }
		return anisette
	}

	private func askForCode(_ request: TwoFactorRequest) async throws -> TwoFactorResponse {
		if case .selectDeliveryMethod(let preferred, let phones) = request {
			if preferred == .sms, let phone = phones.first { return .requestSMS(phoneID: phone.id) }
			if preferred == .voice, let phone = phones.first { return .requestVoice(phoneID: phone.id) }
			return .requestTrustedDevice
		}
		guard let presenter = UIApplication.topViewController() else { throw Failure.signInRequired }
		return try await withCheckedThrowingContinuation { continuation in
			awaitingCode = continuation
			let alert = UIAlertController(title: .localized("Two-Factor Authentication"), message: request.error, preferredStyle: .alert)
			alert.addTextField { field in
				field.keyboardType = .numberPad
				field.textContentType = .oneTimeCode
			}
			alert.addAction(UIAlertAction(title: .localized("Verify"), style: .default) { [weak self, weak alert] _ in
				guard let continuation = self?.awaitingCode else { return }
				self?.awaitingCode = nil
				continuation.resume(returning: .verificationCode(alert?.textFields?.first?.text ?? ""))
			})
			alert.addAction(UIAlertAction(title: .localized("Cancel"), style: .cancel) { [weak self] _ in
				guard let continuation = self?.awaitingCode else { return }
				self?.awaitingCode = nil
				continuation.resume(throwing: CancellationError())
			})
			presenter.present(alert, animated: true)
		}
	}

	private static func query(_ key: String) -> [String: Any] {
		[kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Feather.AppleID", kSecAttrAccount as String: key]
	}

	private static func data(_ key: String) -> Data? {
		var request = query(key)
		request[kSecReturnData as String] = true
		var item: CFTypeRef?
		return SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess ? item as? Data : nil
	}

	private static func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
		data(key).flatMap { try? JSONDecoder().decode(type, from: $0) }
	}

	private static func write(_ data: Data?, key: String) throws {
		let request = query(key)
		var result: OSStatus
		if let data {
			let attrs = [kSecValueData as String: data]
			result = SecItemUpdate(request as CFDictionary, attrs as CFDictionary)
			if result == errSecItemNotFound {
				var new = request
				new[kSecValueData as String] = data
				new[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
				result = SecItemAdd(new as CFDictionary, nil)
			}
		} else {
			result = SecItemDelete(request as CFDictionary)
			if result == errSecItemNotFound { return }
		}
		guard result == errSecSuccess else { throw Failure.keychain }
	}

	private enum Failure: LocalizedError {
		case busy, invalidServer, noTeam, signInRequired, missingDevice, noIdentity, keychain, revokeFailed
		case invalidExtension(String)
		var errorDescription: String? {
			switch self {
			case .busy: .localized("Apple ID provisioning is already in progress.")
			case .invalidServer: .localized("Enter an HTTPS anisette server URL.")
			case .noTeam: .localized("Apple did not return a developer team.")
			case .signInRequired: .localized("Sign in again under Settings → Apple ID.")
			case .missingDevice: .localized("Import a pairing file with a UDID or enter the device UDID under Settings → Apple ID.")
			case .noIdentity: .localized("Feather could not store the signing identity.")
			case .invalidExtension(let name): .localized("Could not provision the nested bundle %@ with this Apple ID.", arguments: name)
			case .revokeFailed: .localized("Apple did not confirm certificate revocation.")
			case .keychain: .localized("Feather could not update the Apple ID Keychain entry.")
			}
		}
	}
}
#endif
