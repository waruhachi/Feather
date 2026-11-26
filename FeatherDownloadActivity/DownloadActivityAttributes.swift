#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
import Foundation

@available(iOS 16.2, *)
struct FeatherDownloadAttributes: ActivityAttributes {
	struct ContentState: Codable, Hashable {
		enum Phase: String, Codable, Hashable {
			case downloading
			case importing
			case waiting
			case paused
			case finished
			case failed
			case cancelled
			case signing
			case installing
			case signed
			case installed
			case installationUnconfirmed
			case workFailed
		}

		let name: String
		let count: Int
		let phase: Phase
		let progress: Double?
	}
}
#endif

#if os(iOS) && !targetEnvironment(macCatalyst)
import AppIntents

@available(iOS 17, *)
struct PauseFeatherDownloadsIntent: LiveActivityIntent {
	static let title: LocalizedStringResource = "Pause Feather Downloads"

	func perform() async throws -> some IntentResult {
		#if !FEATHER_ACTIVITY_EXTENSION
		await DownloadManager.shared.setLiveActivityDownloadsPaused(true)
		#endif
		return .result()
	}
}

@available(iOS 17, *)
struct ResumeFeatherDownloadsIntent: LiveActivityIntent {
	static let title: LocalizedStringResource = "Resume Feather Downloads"

	func perform() async throws -> some IntentResult {
		#if !FEATHER_ACTIVITY_EXTENSION
		await DownloadManager.shared.setLiveActivityDownloadsPaused(false)
		#endif
		return .result()
	}
}
#endif
