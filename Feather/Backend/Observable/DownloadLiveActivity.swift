#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
import UIKit

extension DownloadManager {
	@MainActor
	func setLiveActivityDownloadsPaused(_ paused: Bool) async {
		await withCheckedContinuation { continuation in
			restoreTransfers { continuation.resume() }
		}
		for download in downloads where !download.onlyArchiving {
			setPaused(paused, for: download)
		}
	}

	func updateLiveActivity(finished: Download? = nil, result: Result<String, Error>? = nil) {
		guard #available(iOS 16.2, *) else { return }
		let active = downloads.filter { !$0.onlyArchiving }
		let state: FeatherDownloadAttributes.ContentState?

		if let first = active.first {
			let phase: FeatherDownloadAttributes.ContentState.Phase
			if active.allSatisfy({ $0.isPaused }) {
				phase = .paused
			} else if active.contains(where: { $0.progress < 1 && !$0.isImporting }) {
				phase = .downloading
			} else if active.contains(where: { $0.isImporting }) {
				phase = .importing
			} else {
				phase = .waiting
			}
			let measurable = active.allSatisfy { $0.totalBytes > 0 || $0.progress >= 1 || $0.isImporting }
			let progress = measurable
				? active.reduce(0.0) { $0 + min(1, max(0, $1.overallProgress)) } / Double(active.count)
				: nil
			state = .init(name: String(first.fileName.prefix(120)), count: active.count, phase: phase, progress: progress)
		} else if let finished, !finished.onlyArchiving, let result {
			switch result {
			case .success:
				state = .init(name: String(finished.fileName.prefix(120)), count: 1, phase: .finished, progress: 1)
			case .failure(let error):
				state = .init(name: String(finished.fileName.prefix(120)), count: 1,
					phase: error is CancellationError ? .cancelled : .failed, progress: nil)
			}
		} else {
			state = nil
		}

		Task { @MainActor in
			DownloadLiveActivity.shared.set(state, hasActiveDownloads: !active.isEmpty)
		}
	}
}

@available(iOS 16.2, *)
@MainActor
private final class DownloadLiveActivity {
	static let shared = DownloadLiveActivity()
	typealias State = FeatherDownloadAttributes.ContentState
	private var activity: Activity<FeatherDownloadAttributes>?
	private var lastUpdate: Date?
	private var pending: (State?, Bool)?
	private var refreshTask: Task<Void, Never>?
	private var dismissed = false

	func set(_ state: State?, hasActiveDownloads: Bool) {
		pending = (state, hasActiveDownloads)
		guard refreshTask == nil else { return }
		refreshTask = Task {
			defer { refreshTask = nil }
			while let (state, active) = pending {
				pending = nil
				await publish(state, active: active)
			}
		}
	}

	private func publish(_ state: State?, active: Bool) async {
		if activity == nil && !dismissed {
			activity = Activity<FeatherDownloadAttributes>.activities.first
		}
		if let activity, activity.activityState == .dismissed || activity.activityState == .ended {
			self.activity = nil
			dismissed = true
		}
		guard active, let state else {
			let final = state.map { ActivityContent(state: $0, staleDate: nil) }
			await activity?.end(final, dismissalPolicy: final == nil ? .immediate : .after(Date().addingTimeInterval(15)))
			activity = nil
			dismissed = false
			lastUpdate = nil
			return
		}

		let now = Date()
		let content = ActivityContent(state: state, staleDate: now.addingTimeInterval(5 * 60))
		if let activity {
			if activity.content.state.phase != state.phase
				|| activity.content.state.count != state.count
				|| now.timeIntervalSince(lastUpdate ?? .distantPast) >= 1
			{
				lastUpdate = now
				await activity.update(content)
			}
		} else if !dismissed, UIApplication.shared.applicationState == .active,
			ActivityAuthorizationInfo().areActivitiesEnabled {
			activity = try? Activity.request(attributes: FeatherDownloadAttributes(), content: content)
			lastUpdate = now
		}
	}
}
#else
extension DownloadManager {
	func updateLiveActivity(finished: Download? = nil, result: Result<String, Error>? = nil) {}
}
#endif
