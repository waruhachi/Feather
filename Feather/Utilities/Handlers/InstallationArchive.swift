import Foundation

final class InstallationArchive: Sendable {
	let directory = FileManager.default.temporaryDirectory
		.appendingPathComponent("FeatherInstall_\(UUID().uuidString)", isDirectory: true)
	var url: URL { directory.appendingPathComponent("Archive.ipa") }

	deinit {
		let directory = directory
		DispatchQueue.global(qos: .utility).async {
			try? FileManager.default.removeItem(at: directory)
		}
	}
}
