#if !targetEnvironment(macCatalyst)
import AppIntents
import Foundation
import UniformTypeIdentifiers

struct CheckLibraryUpdatesIntent: AppIntent {
	static let title: LocalizedStringResource = "Check Feather Library Updates"

	@MainActor
	func perform() async throws -> some IntentResult & ProvidesDialog {
		let manager = UpdateManager.shared
		guard try await LibraryUpdateInput.checkAll() else {
			return .result(dialog: "Feather couldn’t complete the update check.")
		}
		let count = Set(manager.updates.values.map(\.bundleIdentifier)).count
		return .result(dialog: "\(count) apps have updates available.")
	}
}

struct SignIPAIntent: AppIntent {
	static let title: LocalizedStringResource = "Sign an IPA with Feather"
	static let openAppWhenRun = true

	@Parameter(title: "IPA File", supportedTypeIdentifiers: ["public.data"])
	var file: IntentFile

	@MainActor
	func perform() async throws -> some IntentResult {
		let name = URL(fileURLWithPath: file.filename).lastPathComponent
		guard ["ipa", "tipa"].contains(URL(fileURLWithPath: name).pathExtension.lowercased()) else {
			throw CocoaError(.fileReadUnsupportedScheme)
		}
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let input = directory.appendingPathComponent(name)
		if let url = file.fileURL {
			let access = url.startAccessingSecurityScopedResource()
			defer { if access { url.stopAccessingSecurityScopedResource() } }
			try FileManager.default.copyItem(at: url, to: input)
		} else {
			try file.data.write(to: input, options: .atomic)
		}
		let uuid = try await FR.importPackage(input, importOrigin: .localFile)
		FeatherAlerts.shared.open(.signing(uuid))
		return .result()
	}
}

struct FeatherAppShortcuts: AppShortcutsProvider {
	static var appShortcuts: [AppShortcut] {
		AppShortcut(
			intent: CheckLibraryUpdatesIntent(),
			phrases: ["Check for updates in \(.applicationName)"],
			shortTitle: "Check Updates",
			systemImageName: "arrow.triangle.2.circlepath"
		)
		AppShortcut(
			intent: SignIPAIntent(),
			phrases: ["Sign an IPA with \(.applicationName)"],
			shortTitle: "Sign IPA",
			systemImageName: "signature"
		)
	}
}
#endif
