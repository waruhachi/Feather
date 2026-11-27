#if !targetEnvironment(macCatalyst)
import Foundation
import WidgetKit

@MainActor
enum WidgetSummary {
	static func refresh() {
		guard let url = FeatherWidgetSnapshot.sharedURL else { return }
		let storage = Storage.shared
		let certificates = storage.getAllCertificates()
		let snapshot = FeatherWidgetSnapshot(
			signed: (try? storage.context.count(for: Signed.fetchRequest())) ?? 0,
			imported: (try? storage.context.count(for: Imported.fetchRequest())) ?? 0,
			updates: Set(UpdateManager.shared.updates.values.map(\.bundleIdentifier)).count,
			certificates: certificates.count,
			revoked: certificates.filter(\.revoked).count,
			nextExpiry: certificates.filter { !$0.revoked }.compactMap(\.expiration).min()
		)
		guard snapshot != FeatherWidgetSnapshot.read(), let data = try? JSONEncoder().encode(snapshot) else { return }
		do {
			try data.write(to: url, options: .atomic)
			WidgetCenter.shared.reloadTimelines(ofKind: FeatherWidgetSnapshot.libraryKind)
			WidgetCenter.shared.reloadTimelines(ofKind: FeatherWidgetSnapshot.certificateKind)
		} catch { return }
	}
}
#endif
