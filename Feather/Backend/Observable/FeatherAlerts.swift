import CryptoKit
import Foundation
import UserNotifications

@MainActor
final class FeatherAlerts: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
	static let shared = FeatherAlerts()
	static let updatesKey = "Feather.notifyLibraryUpdates"
	static let certificatesKey = "Feather.notifyCertificateHealth"
	private static let historyKey = "Feather.deliveredAlertIDs"

	enum Route: Equatable {
		case library(String)
		case signing(String)
		case certificates
	}
	@Published private(set) var route: Route?
	private var pending = Set<String>()

	static func authorize() async -> Bool {
		(try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) == true
	}

	func showUpdates(_ updates: [AppUpdate]) async {
		guard UserDefaults.standard.bool(forKey: Self.updatesKey) else { return }
		for update in updates.sorted(by: { $0.appName.localizedStandardCompare($1.appName) == .orderedAscending }) {
			await send(
				key: "update|\(update.bundleIdentifier)|\(update.remoteVersion)",
				title: .localized("Update Available"),
				body: .localized("%@ %@ is available in your Library.", arguments: update.appName, update.remoteVersion),
				info: ["library-app": update.localUUID]
			)
		}
	}

	func showCertificate(id: String, name: String, expiry: Date?, revoked: Bool) async {
		guard UserDefaults.standard.bool(forKey: Self.certificatesKey) else { return }
		if revoked {
			await send(key: "revoked|\(id)", title: .localized("Certificate Revoked"), body: name, info: ["certificates": true])
			return
		}
		guard let expiry else { return }
		let days = Int(ceil(expiry.timeIntervalSinceNow / 86400))
		guard days <= 7 else { return }
		let window = days <= 0 ? 0 : (days == 1 ? 1 : 7)
		let title: String = days <= 0 ? .localized("Provisioning Profile Expired") : .localized("Provisioning Profile Expiring")
		let body: String = days <= 0 ? name : .localized("%@ expires on %@.", arguments: name, expiry.formatted(date: .abbreviated, time: .omitted))
		await send(key: "expiry|\(id)|\(expiry.timeIntervalSince1970)|\(window)", title: title, body: body, info: ["certificates": true])
	}

	private func send(key: String, title: String, body: String, info: [AnyHashable: Any]) async {
		let id = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
		let defaults = UserDefaults.standard
		let history = defaults.stringArray(forKey: Self.historyKey) ?? []
		guard !history.contains(id), pending.insert(id).inserted else { return }
		defer { pending.remove(id) }

		let center = UNUserNotificationCenter.current()
		let status = await center.notificationSettings().authorizationStatus
		guard status == .authorized || status == .provisional || status == .ephemeral else { return }

		let content = UNMutableNotificationContent()
		content.title = title
		content.body = body
		content.sound = .default
		content.userInfo = info
		do {
			try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
			let current = defaults.stringArray(forKey: Self.historyKey) ?? []
			defaults.set(Array((current + [id]).suffix(2048)), forKey: Self.historyKey)
		} catch { return }
	}

	nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
		[.banner, .list, .sound]
	}

	nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
		let info = response.notification.request.content.userInfo
		let destination: Route?
		if let uuid = info["library-app"] as? String {
			destination = .library(uuid)
		} else if info["certificates"] as? Bool == true {
			destination = .certificates
		} else {
			destination = nil
		}
		if let destination { await MainActor.run { self.route = destination } }
	}

	func open(_ destination: Route) { route = destination }

	func clear(_ pendingRoute: Route) {
		if route == pendingRoute { route = nil }
	}
}
