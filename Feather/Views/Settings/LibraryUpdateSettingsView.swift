#if !targetEnvironment(macCatalyst)
import NimbleViews
import SwiftUI

struct LibraryUpdateSettingsView: View {
	@AppStorage(ScheduledLibraryUpdates.preferenceKey)
	private var interval = ScheduledLibraryUpdates.Interval.off

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
		}
		.navigationTitle(.localized("Library Updates"))
		.onChange(of: interval) { _ in
			ScheduledLibraryUpdates.schedule()
			Task { await ScheduledLibraryUpdates.checkIfDue() }
		}
	}
}
#endif
