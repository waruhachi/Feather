import NimbleViews
import SwiftUI

struct ActivityLogView: View {
	@State private var entries: [ActivityLog.Entry] = []
	@State private var clearing = false

	var body: some View {
		NBList(.localized("Activity Log")) {
			ForEach(entries) { entry in
				VStack(alignment: .leading, spacing: 4) {
					Text(entry.app).font(.headline)
					Text(verbatim: "\(entry.action): \(entry.outcome)")
					Text(entry.date.formatted()).font(.caption).foregroundStyle(.secondary)
				}
			}
			if entries.isEmpty { Text(.localized("No Activity")).foregroundStyle(.secondary) }
		}
		.toolbar {
			if !entries.isEmpty {
				ToolbarItem(placement: .primaryAction) {
					Menu(.localized("Actions"), systemImage: "ellipsis.circle") {
						ShareLink(item: entries.map { "\($0.date.formatted())  \($0.action)  \($0.app)  \($0.outcome)" }.joined(separator: "\n"))
						Button(.localized("Clear Log"), role: .destructive) { clearing = true }
					}
				}
			}
		}
		.refreshable { entries = await ActivityLog.shared.read() }
		.task { entries = await ActivityLog.shared.read() }
		.confirmationDialog(.localized("Clear Log"), isPresented: $clearing) {
			Button(.localized("Clear Log"), role: .destructive) {
				Task {
					try? await ActivityLog.shared.clear()
					entries = await ActivityLog.shared.read()
				}
			}
		}
	}
}
