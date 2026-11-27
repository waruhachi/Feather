#if !targetEnvironment(macCatalyst)
import AppIntents
import CoreData
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

struct SignLatestImportIntent: AppIntent {
	static let title: LocalizedStringResource = "Sign Latest IPA"
	static let openAppWhenRun = true

	@MainActor
	static func openLatest() throws -> Bool {
		let request = Imported.fetchRequest()
		request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
		request.fetchLimit = 1
		guard let uuid = try Storage.shared.context.fetch(request).first?.uuid else { return false }
		FeatherAlerts.shared.open(.signing(uuid))
		return true
	}

	@MainActor
	func perform() async throws -> some IntentResult & ProvidesDialog {
		if try Self.openLatest() {
			return .result(dialog: "Opening your latest import for signing.")
		}
		return .result(dialog: "There are no imported IPAs in your Feather Library.")
	}
}

struct CertificateDaysLeftIntent: AppIntent {
	static let title: LocalizedStringResource = "Days Left on Feather Certificate"

	@MainActor
	func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
		let selection = UserDefaults.standard.integer(forKey: "feather.selectedCert")
		guard let certificate = Storage.shared.getCertificate(for: selection), let expiration = certificate.expiration else {
			return .result(value: 0, dialog: "No signing certificate is selected in Feather.")
		}
		guard !certificate.revoked else {
			return .result(value: 0, dialog: "Your selected signing certificate is revoked.")
		}
		let days = max(0, Int(ceil(expiration.timeIntervalSinceNow / 86400)))
		if days == 0 { return .result(value: days, dialog: "Your selected signing certificate has expired.") }
		return .result(value: days, dialog: "Your selected signing certificate expires in \(days) days.")
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
		AppShortcut(
			intent: SignLatestImportIntent(),
			phrases: ["Sign the latest import in \(.applicationName)"],
			shortTitle: "Sign Latest IPA",
			systemImageName: "signature"
		)
		AppShortcut(
			intent: CertificateDaysLeftIntent(),
			phrases: ["When does my \(.applicationName) certificate expire"],
			shortTitle: "Certificate Expiry",
			systemImageName: "checkmark.seal"
		)
	}
}
#endif
