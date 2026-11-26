//
//  IPAHandler.swift
//  Feather
//
//  Created by samara on 11.04.2025.
//

import Foundation
import SwiftUI

final class AppFileHandler: NSObject, @unchecked Sendable {
	private let _fileManager = FileManager.default
	let uuid: String
	private let _uniqueWorkDir: URL
	var uniqueWorkDirPayload: URL?

	private var _ipa: URL
	private let _install: Bool
	private let _download: Download?
	private let _sourceProvenance: SourceAppProvenance?
	private let _importOrigin: IPAImportOrigin

	init(
		file ipa: URL,
		install: Bool = false,
		download: Download? = nil,
		sourceProvenance: SourceAppProvenance? = nil,
		importOrigin: IPAImportOrigin? = nil
	) {
		self.uuid = download?.transferID.uuidString ?? UUID().uuidString
		self._ipa = ipa
		self._install = install
		self._download = download
		self._sourceProvenance = sourceProvenance ?? download?.sourceProvenance
		self._importOrigin =
			sourceProvenance.map {
				.featherSource($0.sourceRepositoryURL)
			} ?? importOrigin ?? download?.importOrigin ?? .localFile
		self._uniqueWorkDir = _fileManager.temporaryDirectory
			.appendingPathComponent("FeatherImport_\(uuid)", isDirectory: true)

		super.init()
	}

	func copy() async throws {
		try _fileManager.createDirectoryIfNeeded(at: _uniqueWorkDir)

		let destinationURL = _uniqueWorkDir.appendingPathComponent("Input").appendingPathComponent("Package.ipa")
		try _fileManager.createDirectoryIfNeeded(at: destinationURL.deletingLastPathComponent())

		try _fileManager.removeFileIfNeeded(at: destinationURL)

		try _fileManager.copyItem(at: _ipa, to: destinationURL)
		_ipa = destinationURL
	}

	func extract() async throws {
		let download = _download
		let control = download?.importControl ?? ImportControl()
		try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
				DispatchQueue.global(qos: .utility).async {
					do {
						var lastPercentage = -1
						let output = self._uniqueWorkDir.appendingPathComponent("Extracted", isDirectory: true)
						try self._fileManager.createDirectoryIfNeeded(at: output)
						try IPAExtraction.extract(self._ipa, to: output, control: control) { progress in
							let percentage = Int(progress * 100)
							guard let download, percentage != lastPercentage else { return }
							lastPercentage = percentage
							DispatchQueue.main.async {
								download.unpackageProgress = progress
								DownloadManager.shared.updateLiveActivity()
								#if !targetEnvironment(macCatalyst)
									if #available(iOS 26.0, *) {
										BackgroundTaskManager.shared.updateProgress(for: download.id, progress: min(download.overallProgress, 0.99))
									}
								#endif
							}
						}
						self.uniqueWorkDirPayload = output.appendingPathComponent("Payload")
						continuation.resume()
					} catch {
						continuation.resume(throwing: error)
					}
				}
			}
		} onCancel: {
			control.cancel()
		}
	}

	func move() async throws {
		guard let payloadURL = uniqueWorkDirPayload else {
			throw ImportedFileHandlerError.payloadNotFound
		}

		let destinationURL = try await _directory()

		guard let payload = try? payloadURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
			payload.isDirectory == true, payload.isSymbolicLink != true
		else {
			throw ImportedFileHandlerError.payloadNotFound
		}

		if _download != nil {
			try _fileManager.removeFileIfNeeded(at: destinationURL)
		}
		try _fileManager.moveItem(at: payloadURL, to: destinationURL)

		try? _fileManager.removeItem(at: _uniqueWorkDir)
	}

	@MainActor
	func addToDatabase() async throws {
		let app = try await _directory()

		guard let appUrl = _fileManager.getPath(in: app, for: "app"),
			let values = try? appUrl.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
			values.isDirectory == true, values.isSymbolicLink != true,
			Bundle(url: appUrl)?.bundleIdentifier != nil
		else {
			try? _fileManager.removeItem(at: app)
			throw ImportedFileHandlerError.payloadNotFound
		}

		let bundle = Bundle(url: appUrl)

		let storage = Storage.shared
		do {
			try storage.saveNewApp {
				storage.addImported(
					uuid: uuid,
					source: _sourceProvenance?.sourceRepositoryURL,
					appName: bundle?.name ?? appUrl.deletingPathExtension().lastPathComponent,
					appIdentifier: bundle?.bundleIdentifier,
					appVersion: bundle?.version ?? "",
					appIcon: bundle?.iconFileName
				)

				if let sourceProvenance = _sourceProvenance {
					storage.addSourceMetadata(for: uuid, kind: .imported, provenance: sourceProvenance, deferSave: true)
				} else {
					storage.addImportMetadata(
						for: uuid,
						kind: .imported,
						origin: _importOrigin,
						appIdentifier: bundle?.bundleIdentifier,
						appName: bundle?.name,
						appVersion: bundle?.version,
						deferSave: true
					)
				}
			}
		} catch {
			try? _fileManager.removeItem(at: app)
			throw error
		}

		if let original = _download?.updateFromUUID {
			storage.inheritUpdateSource(from: original, to: uuid)
		}

		NotificationCenter.default.post(
			name: .featherImportedAppDidFinish,
			object: uuid
		)
	}

	private func _directory() async throws -> URL {
		// Documents/Feather/Unsigned/\(UUID)
		_fileManager.unsigned(uuid)
	}

	func clean() async throws {
		try _fileManager.removeFileIfNeeded(at: _uniqueWorkDir)
	}
}

private enum ImportedFileHandlerError: Error {
	case payloadNotFound
}
