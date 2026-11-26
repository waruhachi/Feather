import Foundation

@MainActor
enum WorkLiveActivity {
	enum Phase {
		case signing, installing
	}

	enum Outcome {
		case signed, installed, unconfirmed, failed, cancelled
	}

	static func begin(_ phase: Phase, name: String) -> UUID {
		let id = UUID()
		#if os(iOS) && !targetEnvironment(macCatalyst)
		if #available(iOS 16.2, *) {
			DownloadLiveActivity.shared.begin(id, phase: phase == .signing ? .signing : .installing, name: name)
		}
		#endif
		return id
	}

	static func update(_ id: UUID, progress: Double) {
		#if os(iOS) && !targetEnvironment(macCatalyst)
		if #available(iOS 16.2, *), progress.isFinite {
			DownloadLiveActivity.shared.update(id, progress: min(1, max(0, progress)))
		}
		#endif
	}

	static func finish(_ id: UUID, outcome: Outcome) {
		#if os(iOS) && !targetEnvironment(macCatalyst)
		if #available(iOS 16.2, *) {
			let phase: FeatherDownloadAttributes.ContentState.Phase
			switch outcome {
			case .signed: phase = .signed
			case .installed: phase = .installed
			case .unconfirmed: phase = .installationUnconfirmed
			case .failed: phase = .workFailed
			case .cancelled: phase = .cancelled
			}
			DownloadLiveActivity.shared.finish(id, phase: phase)
		}
		#endif
	}
}

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
			DownloadLiveActivity.shared.setDownload(state, active: !active.isEmpty)
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

	private var downloads: State?
	private var work: [(UUID, State)] = []

	func setDownload(_ state: State?, active: Bool) {
		downloads = active ? state : nil
		refresh(final: active ? nil : state)
	}

	func begin(_ id: UUID, phase: State.Phase, name: String) {
		work.append((id, State(name: String(name.prefix(120)), count: 1, phase: phase, progress: nil)))
		refresh()
	}

	func update(_ id: UUID, progress: Double) {
		guard let index = work.firstIndex(where: { $0.0 == id }) else { return }
		let state = work[index].1
		work[index].1 = State(name: state.name, count: state.count, phase: state.phase, progress: progress)
		if index == work.count - 1 { refresh() }
	}

	func finish(_ id: UUID, phase: State.Phase) {
		guard let index = work.firstIndex(where: { $0.0 == id }) else { return }
		let state = work.remove(at: index).1
		let complete = phase == .signed || phase == .installed
		refresh(final: State(name: state.name, count: 1, phase: phase, progress: complete ? 1 : nil))
	}

	private func refresh(final: State? = nil) {
		let active = work.last?.1 ?? downloads
		pending = (active ?? final, active != nil)
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
				|| activity.content.state.name != state.name
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
