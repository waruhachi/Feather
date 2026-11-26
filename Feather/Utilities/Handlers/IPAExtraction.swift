import Foundation
import Minizip

final class ImportControl: @unchecked Sendable {
	private let condition = NSCondition()
	private var paused = false
	private var cancelled = false

	func setPaused(_ value: Bool) {
		condition.lock()
		paused = value
		condition.broadcast()
		condition.unlock()
	}

	func cancel() {
		condition.lock()
		cancelled = true
		condition.broadcast()
		condition.unlock()
	}

	func checkpoint() throws {
		condition.lock()
		defer { condition.unlock() }
		while paused && !cancelled {
			condition.wait()
		}
		if cancelled { throw CancellationError() }
	}
}

enum IPAExtraction {
	static func extract(
		_ archive: URL,
		to directory: URL,
		control: ImportControl,
		progress: (Double) -> Void,
		maximumExtractedBytes: UInt64 = .max
	) throws {
		guard let zip = unzOpen64(archive.path) else { throw ExtractionError.invalidArchive }
		defer { unzClose(zip) }

		var global = unz_global_info64()
		guard unzGetGlobalInfo64(zip, &global) == UNZ_OK, global.number_entry > 0,
			unzGoToFirstFile(zip) == UNZ_OK
		else { throw ExtractionError.invalidArchive }

		let manager = FileManager.default
		let directories = directory.standardizedFileURL.path + "/"
		var seen = Set<String>()
		var total: UInt64 = 0
		var links: [(URL, String)] = []
		var buffer = [UInt8](repeating: 0, count: 128 * 1024)
		for index in 0..<global.number_entry {
			try control.checkpoint()
			var info = unz_file_info64()
			guard unzGetCurrentFileInfo64(zip, &info, nil, 0, nil, 0, nil, 0) == UNZ_OK,
				info.size_filename > 0, info.size_filename <= 4096
			else { throw ExtractionError.invalidArchive }

			guard info.uncompressed_size <= maximumExtractedBytes - total else { throw ExtractionError.invalidArchive }
			total += info.uncompressed_size

			var name = [CChar](repeating: 0, count: Int(info.size_filename) + 1)
			guard unzGetCurrentFileInfo64(zip, &info, &name, UInt(name.count), nil, 0, nil, 0) == UNZ_OK,
				let filename = String(bytes: name.dropLast().map { UInt8(bitPattern: $0) }, encoding: .utf8),
				!filename.contains("\\"),
				!filename.contains("\0")
			else { throw ExtractionError.invalidArchive }

			let parts = filename.split(separator: "/", omittingEmptySubsequences: false)
			let path = filename.hasSuffix("/") ? parts.dropLast() : parts[...]
			guard !path.isEmpty, path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
				seen.insert(path.joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()).inserted
			else { throw ExtractionError.invalidArchive }

			let output = directory.appendingPathComponent(path.joined(separator: "/"))
			let mode = UInt16(truncatingIfNeeded: info.external_fa >> 16)
			let kind = mode & 0o170000
			if filename.hasSuffix("/") {
				guard kind == 0 || kind == 0o040000 else { throw ExtractionError.invalidArchive }
				try manager.createDirectoryIfNeeded(at: output)
			} else {
				guard kind == 0 || kind == 0o100000 || kind == 0o120000,
					unzOpenCurrentFile(zip) == UNZ_OK
				else { throw ExtractionError.invalidArchive }
				var entryIsOpen = true
				defer { if entryIsOpen { unzCloseCurrentFile(zip) } }
				try manager.createDirectoryIfNeeded(at: output.deletingLastPathComponent())
				if kind == 0o120000 {
					guard info.uncompressed_size > 0, info.uncompressed_size < 4096 else { throw ExtractionError.invalidArchive }
					let count = unzReadCurrentFile(zip, &buffer, UInt32(buffer.count))
					guard count > 0, UInt64(count) == info.uncompressed_size,
						let target = String(bytes: buffer.prefix(Int(count)), encoding: .utf8),
						!target.hasPrefix("/"), !target.split(separator: "/").contains(".."), !target.contains("\\") && !target.contains("\0"),
						output.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL.path.hasPrefix(directories)
					else { throw ExtractionError.invalidArchive }
					links.append((output, target))
				} else {
					guard manager.createFile(atPath: output.path, contents: nil) else {
						throw CocoaError(.fileWriteUnknown)
					}
					let handle = try FileHandle(forWritingTo: output)
					defer { try? handle.close() }
					var written: UInt64 = 0
					while true {
						try control.checkpoint()
						let count = unzReadCurrentFile(zip, &buffer, UInt32(buffer.count))
						guard count >= 0 else { throw ExtractionError.invalidArchive }
						if count == 0 { break }
						try handle.write(contentsOf: Data(buffer.prefix(Int(count))))
						written += UInt64(count)
						guard written <= info.uncompressed_size else { throw ExtractionError.invalidArchive }
						let fraction = Double(written) / Double(max(1, info.uncompressed_size))
						progress((Double(index) + min(1, fraction)) / Double(global.number_entry))
					}
					guard written == info.uncompressed_size else { throw ExtractionError.invalidArchive }
					if mode & 0o111 != 0 {
						try manager.setAttributes([.posixPermissions: Int(mode & 0o777)], ofItemAtPath: output.path)
					}
				}
				let result = unzCloseCurrentFile(zip)
				entryIsOpen = false
				guard result == UNZ_OK else { throw ExtractionError.invalidArchive }
			}
			progress(Double(index + 1) / Double(global.number_entry))
			if index + 1 < global.number_entry, unzGoToNextFile(zip) != UNZ_OK {
				throw ExtractionError.invalidArchive
			}
		}
		for (link, target) in links {
			try control.checkpoint()
			try manager.createSymbolicLink(atPath: link.path, withDestinationPath: target)
		}
	}

	private enum ExtractionError: LocalizedError {
		case invalidArchive

		var errorDescription: String? { "The IPA archive is invalid or unsupported." }
	}
}
