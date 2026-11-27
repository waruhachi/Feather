#if !targetEnvironment(macCatalyst)
import NimbleViews
import SwiftUI

struct LibraryUpdateSettingsView: View {
	@AppStorage(ScheduledLibraryUpdates.preferenceKey)
	private var interval = ScheduledLibraryUpdates.Interval.off
	@AppStorage(PairedLibraryUpdates.enabledKey) private var automaticInstall = false

	@AppStorage(FeatherAlerts.updatesKey) private var updateAlerts = false
	@AppStorage(FeatherAlerts.certificatesKey) private var certificateAlerts = false

	var body: some View {
		Form {
			Section {
				Picker(.localized("Automatic Checks"), selection: $interval) {
					Text(.localized("Off")).tag(ScheduledLibraryUpdates.Interval.off)
					Text(.localized("Hourly")).tag(ScheduledLibraryUpdates.Interval.hourly)
					Text(.localized("Daily")).tag(ScheduledLibraryUpdates.Interval.daily)
				}
			} footer: {
				Text(.localized("Feather checks when you open the app and when iOS grants background time. Available updates appear in Library."))
			}
			Section {
				Toggle(.localized("Install Paired Updates Automatically"), isOn: $automaticInstall)
			} footer: {
				Text(.localized("Enable automatic updates for a source in Sources or for an individual signed app in Library. An app’s setting overrides its source. Feather updates only installed apps with the same signing identity when a pairing connection is available. iOS controls when background work runs."))
			}
			Section {
				Toggle(.localized("Update Notifications"), isOn: $updateAlerts)
				Toggle(.localized("Certificate Expiry and Revocation Alerts"), isOn: $certificateAlerts)
			}
		}
		.onChange(of: automaticInstall) { enabled in
			PairedLibraryUpdates.schedule()
			if enabled { Task { await PairedLibraryUpdates.run() } }
		}
		.onChange(of: updateAlerts) { enabled in
			guard enabled else { return }
			Task {
				if await FeatherAlerts.authorize() {
					await FeatherAlerts.shared.showUpdates(Array(UpdateManager.shared.updates.values))
				} else {
					updateAlerts = false
				}
			}
		}
		.onChange(of: certificateAlerts) { enabled in
			ScheduledLibraryUpdates.schedule()
			guard enabled else { return }
			Task {
				if await FeatherAlerts.authorize() {
					await CertificateHealth.checkIfDue()
				} else {
					certificateAlerts = false
				}
			}
		}
		.navigationTitle(.localized("Library Updates"))
		.onChange(of: interval) { _ in
			ScheduledLibraryUpdates.schedule()
			Task { await ScheduledLibraryUpdates.checkIfDue() }
		}
	}
}
#endif
