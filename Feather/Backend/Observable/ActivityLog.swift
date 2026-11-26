import Foundation

actor ActivityLog {
	static let shared = ActivityLog()

	struct Entry: Codable, Identifiable {
		var id = UUID()
		var date = Date()
		let action: String
		let app: String
		let outcome: String
	}

	private var file: URL { URL.applicationSupportDirectory.appendingPathComponent("FeatherActivity.json") }

	func read() -> [Entry] {
		guard let data = try? Data(contentsOf: file) else { return [] }
		return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
	}

	func record(_ entry: Entry) {
		var entries = read()
		entries.insert(entry, at: 0)
		do {
			try FileManager.default.createDirectoryIfNeeded(at: file.deletingLastPathComponent())
			try JSONEncoder().encode(Array(entries.prefix(300))).write(to: file, options: .atomic)
		} catch {
			// Logging must not change the result of the underlying operation.
		}
	}

	func clear() throws {
		try FileManager.default.removeFileIfNeeded(at: file)
	}
}
