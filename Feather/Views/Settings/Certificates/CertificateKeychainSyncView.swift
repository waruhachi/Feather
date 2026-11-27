import SwiftUI

struct CertificateKeychainSyncView: View {
	@AppStorage(CertificateKeychainSync.enabledKey) private var enabled = false
	@State private var working = false
	@State private var status: String?

	var body: some View {
		Form {
			Section {
				Toggle(.localized("Sync Signing Certificates"), isOn: $enabled)
					.disabled(working)
				Button(.localized("Sync Now"), systemImage: "arrow.triangle.2.circlepath") {
					Task { await sync() }
				}
				.disabled(!enabled || working)
				if working { ProgressView() }
				if let status { Text(status) }
			} footer: {
				Text(.localized("iCloud Keychain syncs imported signing keys, profiles, and their passwords between devices using the same signing team and iCloud account. Apple ID signing identities stay on the device where Feather created them."))
			}
		}
		.navigationTitle(.localized("iCloud Keychain"))
	}

	private func sync() async {
		working = true
		defer { working = false }
		do {
			let outcome = try await CertificateKeychainSync.sync()
			status = ([.localized("%lld uploaded · %lld added", arguments: outcome.uploaded, outcome.added)] + outcome.problems)
				.joined(separator: "\n")
		} catch is CancellationError {
			status = .localized("Sync is already running or was turned off.")
		} catch {
			status = error.localizedDescription
		}
	}
}
