import Foundation

enum IPADocument {
	static func accepts(_ url: URL) -> Bool {
		url.isFileURL && ["ipa", "tipa"].contains(url.pathExtension.lowercased())
	}

	static func copyForImport(from source: URL, to destination: URL) throws {
		var coordinationError: NSError?
		var copyError: Error?
		NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readableURL in
			do {
				try FileManager.default.copyItem(at: readableURL, to: destination)
			} catch {
				copyError = error
			}
		}
		if let coordinationError { throw coordinationError }
		if let copyError { throw copyError }
	}
}
