import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct FeatherDownloadWidget: Widget {
	var body: some WidgetConfiguration {
		ActivityConfiguration(for: FeatherDownloadAttributes.self) { context in
			DownloadStatus(state: context.state, stale: context.isStale)
				.padding()
		} dynamicIsland: { context in
			DynamicIsland {
				DynamicIslandExpandedRegion(.bottom) {
					DownloadStatus(state: context.state, stale: context.isStale)
				}
			} compactLeading: {
				Image(systemName: context.state.symbol)
			} compactTrailing: {
				if let progress = context.state.progress, !context.isStale {
					Text(progress, format: .percent.precision(.fractionLength(0)))
						.monospacedDigit()
				} else {
					Image(systemName: "ellipsis")
				}
			} minimal: {
				if let progress = context.state.progress, !context.isStale {
					ProgressView(value: progress)
						.progressViewStyle(.circular)
				} else {
					Image(systemName: context.state.symbol)
				}
			}
			.keylineTint(.indigo)
		}
	}
}

private struct DownloadStatus: View {
	let state: FeatherDownloadAttributes.ContentState
	let stale: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Label {
				if state.count > 1 {
					Text("\(state.count) downloads")
				} else {
					Text(state.name).lineLimit(1)
				}
			} icon: {
				Image(systemName: state.symbol)
			}
			.font(.headline)

			HStack {
				Text(stale ? "Open Feather for current progress" : state.title)
				Spacer()
				if let progress = state.progress, !stale {
					Text(progress, format: .percent.precision(.fractionLength(0)))
						.monospacedDigit()
				}
				if #available(iOS 17, *), !stale {
					if state.phase == .paused {
						Button(intent: ResumeFeatherDownloadsIntent()) {
							Label("Resume", systemImage: "play.fill")
						}
						.labelStyle(.iconOnly)
					} else if state.phase == .downloading || state.phase == .importing {
						Button(intent: PauseFeatherDownloadsIntent()) {
							Label("Pause", systemImage: "pause.fill")
						}
						.labelStyle(.iconOnly)
					}
				}
			}
			.font(.subheadline)
			.foregroundStyle(.secondary)

			if let progress = state.progress, !stale {
				ProgressView(value: progress)
					.tint(.indigo)
			}
		}
	}
}

private extension FeatherDownloadAttributes.ContentState {
	var title: LocalizedStringKey {
		switch phase {
		case .downloading: "Downloading"
		case .importing: "Importing"
		case .waiting: "Open Feather to import"
		case .paused: "Paused"
		case .finished: "Added to Library"
		case .failed: "Download or import failed"
		case .cancelled: "Cancelled"
		}
	}

	var symbol: String {
		switch phase {
		case .downloading: "arrow.down.circle"
		case .importing: "archivebox"
		case .waiting: "clock"
		case .paused: "pause.circle"
		case .finished: "checkmark.circle"
		case .failed: "exclamationmark.circle"
		case .cancelled: "xmark.circle"
		}
	}
}
