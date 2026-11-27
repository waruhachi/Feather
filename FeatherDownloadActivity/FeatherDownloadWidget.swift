import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct FeatherWidgets: WidgetBundle {
	var body: some Widget {
		FeatherDownloadWidget()
		FeatherSummaryWidget<LibrarySummary>()
		FeatherSummaryWidget<CertificateSummary>()
	}
}

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
		case .signing: "Signing"
		case .installing: "Installing"
		case .signed: "Signed"
		case .installed: "Installed"
		case .installationUnconfirmed: "Check Home Screen"
		case .workFailed: "Operation Failed"
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
		case .signing: "signature"
		case .installing: "square.and.arrow.down"
		case .signed, .installed: "checkmark.circle"
		case .installationUnconfirmed: "questionmark.circle"
		case .workFailed: "exclamationmark.circle"
		}
	}
}

private protocol FeatherSummaryKind { static var certificates: Bool { get } }
private enum LibrarySummary: FeatherSummaryKind { static let certificates = false }
private enum CertificateSummary: FeatherSummaryKind { static let certificates = true }

private struct FeatherSummaryWidget<Kind: FeatherSummaryKind>: Widget {
	private var certificates: Bool { Kind.certificates }

	var body: some WidgetConfiguration {
		StaticConfiguration(
			kind: certificates ? FeatherWidgetSnapshot.certificateKind : FeatherWidgetSnapshot.libraryKind,
			provider: FeatherSummaryProvider()
		) { entry in
			FeatherSummaryView(entry: entry, certificates: certificates)
		}
		.configurationDisplayName(certificates ? "Certificate Health" : "Feather Library")
		.description(certificates ? "See certificate expiry and revocation status." : "See signed apps and available updates.")
		.supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryInline])
	}
}

private struct FeatherSummaryEntry: TimelineEntry {
	let date: Date
	let snapshot: FeatherWidgetSnapshot?
}

private struct FeatherSummaryProvider: TimelineProvider {
	func placeholder(in context: Context) -> FeatherSummaryEntry {
		FeatherSummaryEntry(date: Date(), snapshot: .init(signed: 4, imported: 2, updates: 1, certificates: 2, revoked: 0, nextExpiry: nil))
	}

	func getSnapshot(in context: Context, completion: @escaping (FeatherSummaryEntry) -> Void) {
		completion(context.isPreview ? placeholder(in: context) : entry())
	}

	func getTimeline(in context: Context, completion: @escaping (Timeline<FeatherSummaryEntry>) -> Void) {
		completion(Timeline(entries: [entry()], policy: .after(Date().addingTimeInterval(3600))))
	}

	private func entry() -> FeatherSummaryEntry {
		FeatherSummaryEntry(date: Date(), snapshot: FeatherWidgetSnapshot.read())
	}
}

private struct FeatherSummaryView: View {
	@Environment(\.widgetFamily) private var family
	let entry: FeatherSummaryEntry
	let certificates: Bool

	private var symbol: String { certificates ? "checkmark.seal" : "square.grid.2x2" }
	private var title: LocalizedStringKey { certificates ? "Certificates" : "Feather Library" }

	var body: some View {
		Group {
			if family == .accessoryInline {
				Label { summary } icon: { Image(systemName: symbol) }
			} else {
				VStack(alignment: .leading, spacing: 4) {
					Label(title, systemImage: symbol).font(.caption.bold()).widgetAccentable()
					summary.font(.headline)
					if family == .systemSmall, let snapshot = entry.snapshot {
						if certificates, let expiry = snapshot.nextExpiry {
							Text(expiry, style: .date).font(.caption).foregroundStyle(.secondary)
						} else if !certificates {
							Text("\(snapshot.signed) signed · \(snapshot.imported) imported")
								.font(.caption).foregroundStyle(.secondary)
						}
					}
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			}
		}
		.widgetURL(URL(string: certificates ? "feather://certificates" : "feather://library"))
		.modifier(FeatherWidgetBackground())
	}

	@ViewBuilder
	private var summary: some View {
		if let snapshot = entry.snapshot {
			if !certificates {
				Text("\(snapshot.updates) updates")
			} else if snapshot.revoked > 0 {
				Text("\(snapshot.revoked) revoked")
			} else if let expiry = snapshot.nextExpiry {
				if expiry <= entry.date {
					Text("Profile expired")
				} else {
					Text(expiry, style: .relative)
				}
			} else {
				Text("\(snapshot.certificates) certificates")
			}
		} else {
			Text("Open Feather")
		}
	}
}

private struct FeatherWidgetBackground: ViewModifier {
	func body(content: Content) -> some View {
		if #available(iOS 17.0, *) {
			content.containerBackground(.fill.tertiary, for: .widget)
		} else {
			content.padding()
		}
	}
}
