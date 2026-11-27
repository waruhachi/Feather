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

#if !targetEnvironment(macCatalyst)
import Foundation

struct FeatherWidgetSnapshot: Codable, Equatable {
	let signed: Int
	let imported: Int
	let updates: Int
	let certificates: Int
	let revoked: Int
	let nextExpiry: Date?

	static let libraryKind = "FeatherLibraryWidget"
	static let certificateKind = "FeatherCertificateWidget"

	static var sharedURL: URL? {
		guard let group = Bundle.main.object(forInfoDictionaryKey: "FeatherWidgetAppGroup") as? String, !group.isEmpty else { return nil }
		return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
			.appendingPathComponent("FeatherWidgetSnapshot.json")
	}

	static func read() -> Self? {
		guard let url = sharedURL, let data = try? Data(contentsOf: url) else { return nil }
		return try? JSONDecoder().decode(Self.self, from: data)
	}
}
#endif
