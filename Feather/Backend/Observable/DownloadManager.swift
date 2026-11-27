//
//  enum.swift
//  Feather
//
//  Created by samara on 3.05.2025.
//

import BackgroundTasks
import Combine
import Foundation
import UIKit

class Download: ObservableObject, Identifiable, @unchecked Sendable {
	@Published var progress: Double = 0.0
	@Published var bytesDownloaded: Int64 = 0
	@Published var totalBytes: Int64 = 0
	@Published var unpackageProgress: Double = 0.0

	var overallProgress: Double {
		onlyArchiving
			? unpackageProgress
			: (0.3 * unpackageProgress) + (0.7 * progress)
	}

	var task: URLSessionDownloadTask?
	@Published var isImporting = false
	@Published var isPaused = false
	let importControl = ImportControl()
	var importTask: Task<Void, Never>?
	var importCompletion: [(Result<String, Error>) -> Void] = []

	let id: String
	let transferID: UUID
	let updateFromUUID: String?
	let url: URL
	let fileName: String
	let onlyArchiving: Bool
	var sourceProvenance: SourceAppProvenance?
	var importOrigin: IPAImportOrigin

	init(
		id: String,
		url: URL,
		transferID: UUID = UUID(),
		updateFromUUID: String? = nil,
		onlyArchiving: Bool = false,
		sourceProvenance: SourceAppProvenance? = nil,
		importOrigin: IPAImportOrigin? = nil
	) {
		self.id = id
		self.transferID = transferID
		self.updateFromUUID = updateFromUUID
		self.url = url
		self.onlyArchiving = onlyArchiving
		self.sourceProvenance = sourceProvenance
		self.importOrigin =
			sourceProvenance.map {
				.featherSource($0.sourceRepositoryURL)
			} ?? importOrigin ?? .remoteURL(url)
		self.fileName = url.lastPathComponent
	}
}

class DownloadManager: NSObject, ObservableObject {
	static let shared = DownloadManager()

	@Published var downloads: [Download] = []

	var manualDownloads: [Download] {
		downloads.filter { isManualDownload($0.id) }
	}

	static let sessionIdentifier = "\(Bundle.main.bundleIdentifier ?? "Feather").ipa-downloads"
	private var backgroundCompletion: (() -> Void)?
	private var _session: URLSession!
	private var pendingDirectory: URL {
		URL.applicationSupportDirectory.appendingPathComponent("FeatherPendingDownloads", isDirectory: true)
	}

	private struct Transfer: Codable {
		let id: String
		let transferID: UUID
		let updateFromUUID: String?
		let url: URL
		let provenance: SourceAppProvenance?
		let origin: IPAImportOrigin

		init(_ download: Download) {
			id = download.id
			transferID = download.transferID
			updateFromUUID = download.updateFromUUID
			url = download.url
			provenance = download.sourceProvenance
			origin = download.importOrigin
		}

		func makeDownload() -> Download {
			Download(id: id, url: url, transferID: transferID, updateFromUUID: updateFromUUID, sourceProvenance: provenance, importOrigin: origin)
		}
	}

	#if !targetEnvironment(macCatalyst)
		private func _updateBackgroundAudioState() {
			if #unavailable(iOS 26.0) {
				if !downloads.isEmpty {
					BackgroundAudioManager.shared.start()
				} else {
					BackgroundAudioManager.shared.stop()
				}
			}
		}
	#endif

	override init() {
		super.init()
		let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
		configuration.sessionSendsLaunchEvents = true
		configuration.isDiscretionary = false
		_session = URLSession(
			configuration: configuration,
			delegate: self,
			delegateQueue: .main
		)
	}

	func restoreTransfers(completion: (() -> Void)? = nil) {
		_session.getAllTasks { tasks in
			DispatchQueue.main.async {
				for task in tasks.compactMap({ $0 as? URLSessionDownloadTask }) {
					_ = self.download(for: task)
				}
				self.updateLiveActivity()
				completion?()
			}
		}
	}

	func acknowledgeBackgroundEvents(_ completion: @escaping () -> Void) {
		backgroundCompletion = completion
	}

	func importPendingDownloads() {
		let manager = FileManager.default
		guard let folders = try? manager.contentsOfDirectory(at: pendingDirectory, includingPropertiesForKeys: nil) else { return }
		for folder in folders {
			let file = folder.appendingPathComponent("Package.ipa")
			let manifest = folder.appendingPathComponent("Transfer.json")
			guard manager.fileExists(atPath: file.path),
				let data = try? Data(contentsOf: manifest),
				let transfer = try? JSONDecoder().decode(Transfer.self, from: data)
			else {
				try? manager.removeItem(at: folder)
				continue
			}
			let download = downloads.first(where: { $0.transferID == transfer.transferID }) ?? transfer.makeDownload()
			if !downloads.contains(where: { $0 === download }) { downloads.append(download) }
			guard download.importTask == nil else { continue }
			download.progress = 1
			handlePackageFile(url: file, dl: download, removeAfterImport: true)
		}
		updateLiveActivity()
	}

	private func download(for task: URLSessionDownloadTask) -> Download? {
		if let download = getDownloadTask(by: task) { return download }
		guard let description = task.taskDescription,
			let data = Data(base64Encoded: description),
			let transfer = try? JSONDecoder().decode(Transfer.self, from: data)
		else { return nil }
		let download = downloads.first(where: { $0.transferID == transfer.transferID }) ?? transfer.makeDownload()
		if !downloads.contains(where: { $0 === download }) { downloads.append(download) }
		download.task = task
		if task.state == .suspended { download.isPaused = true }
		return download
	}

	func startDownload(
		from url: URL,
		id: String = UUID().uuidString,
		sourceProvenance: SourceAppProvenance? = nil,
		importOrigin: IPAImportOrigin? = nil,
		updateFromUUID: String? = nil,
		onImport: ((Result<String, Error>) -> Void)? = nil
	) -> Download {
		let requestedOrigin =
			sourceProvenance.map {
				IPAImportOrigin.featherSource($0.sourceRepositoryURL)
			} ?? importOrigin ?? .remoteURL(url)
		if let existingDownload = downloads.first(where: {
			$0.url == url
				&& $0.sourceProvenance?.sourceVersionID
					== sourceProvenance?.sourceVersionID
				&& $0.sourceProvenance?.expectedSHA256 == sourceProvenance?.expectedSHA256
				&& $0.importOrigin == requestedOrigin
				&& $0.updateFromUUID == updateFromUUID
		}) {
			if let onImport { existingDownload.importCompletion.append(onImport) }
			resumeDownload(existingDownload)
			return existingDownload
		}

		let download = Download(
			id: id,
			url: url,
			updateFromUUID: updateFromUUID,
			sourceProvenance: sourceProvenance,
			importOrigin: importOrigin
		)

		guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
			let data = try? JSONEncoder().encode(Transfer(download))
		else {
			DispatchQueue.main.async {
				onImport?(.failure(URLError(.unsupportedURL)))
				FeatherHaptics.result(.error)
			}
			return download
		}
		if let onImport { download.importCompletion.append(onImport) }
		let task = _session.downloadTask(with: url)
		task.taskDescription = data.base64EncodedString()
		download.task = task
		downloads.append(download)
		task.resume()
		updateLiveActivity()

		return download
	}

	@MainActor
	func importLocalArchive(from url: URL, onImport: @escaping (Result<String, Error>) -> Void) {
		guard IPADocument.accepts(url) else {
			onImport(.failure(CocoaError(.fileReadUnsupportedScheme)))
			return
		}
		let download = Download(
			id: "FeatherManualDownload_\(UUID().uuidString)",
			url: url,
			onlyArchiving: true,
			importOrigin: .localFile
		)
		download.importCompletion.append(onImport)
		downloads.append(download)

		#if !targetEnvironment(macCatalyst)
		_updateBackgroundAudioState()
		#endif

		handlePackageFile(url: url, dl: download)
	}

	func resumeDownload(_ download: Download) {
		setPaused(false, for: download)
	}

	func setPaused(_ paused: Bool, for download: Download) {
		guard download.isPaused != paused else { return }
		if download.isImporting {
			download.importControl.setPaused(paused)
		} else if let task = download.task, task.state == .running || task.state == .suspended {
			if paused { task.suspend() } else { task.resume() }
		} else {
			return
		}
		download.isPaused = paused
		updateLiveActivity()
	}

	func cancelDownload(_ download: Download) {
		if let importTask = download.importTask {
			download.importControl.cancel()
			importTask.cancel()
			return
		}
		download.task?.taskDescription = nil
		download.task?.cancel()
		try? FileManager.default.removeItem(at: pendingDirectory.appendingPathComponent(download.transferID.uuidString))
		finish(download, result: .failure(CancellationError()))
	}

	private func finish(_ download: Download, result: Result<String, Error>) {
		guard let index = downloads.firstIndex(where: { $0 === download }) else { return }
		downloads.remove(at: index)
		download.importTask = nil
		download.task = nil
		let completions = download.importCompletion
		download.importCompletion.removeAll()

		#if !targetEnvironment(macCatalyst)
			_updateBackgroundAudioState()
			if #available(iOS 26.0, *) {
				BackgroundTaskManager.shared.stopTask(for: download.id, success: (try? result.get()) != nil)
			}
		#endif

		updateLiveActivity(finished: download, result: result)
		for completion in completions { completion(result) }
	}

	func isManualDownload(_ string: String) -> Bool {
		return string.contains("FeatherManualDownload")
	}

	func getDownload(by id: String) -> Download? {
		return downloads.first(where: { $0.id == id })
	}

	func getDownloadIndex(by id: String) -> Int? {
		return downloads.firstIndex(where: { $0.id == id })
	}

	func getDownloadTask(by task: URLSessionDownloadTask) -> Download? {
		return downloads.first(where: { $0.task == task })
	}
}

extension DownloadManager: URLSessionDownloadDelegate {

	private func handlePackageFile(url: URL, dl: Download, removeAfterImport: Bool = false) {
		let scoped = dl.onlyArchiving && url.startAccessingSecurityScopedResource()
		#if !targetEnvironment(macCatalyst)
			if #available(iOS 26.0, *), UIApplication.shared.applicationState == .active {
				BackgroundTaskManager.shared.startTask(for: dl.id, filename: dl.fileName)
			}
		#endif

		dl.isImporting = true
		if dl.isPaused { dl.importControl.setPaused(true) }
		updateLiveActivity()
		dl.importTask = Task { @MainActor in
			defer {
				if scoped { url.stopAccessingSecurityScopedResource() }
				if removeAfterImport { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
			}

			do {
				let uuid = try await FR.importPackage(url, download: dl)
				finish(dl, result: .success(uuid))
				if dl.updateFromUUID == nil { ImportSigning.enqueue(uuid) }
			} catch {
				if !(error is CancellationError) {
					FeatherHaptics.result(.error)
				}
				finish(dl, result: .failure(error))
			}
		}
	}

	func urlSession(
		_ session: URLSession,
		downloadTask: URLSessionDownloadTask,
		didFinishDownloadingTo location: URL
	) {
		guard let download = download(for: downloadTask) else { return }

		let directory = pendingDirectory.appendingPathComponent(download.transferID.uuidString, isDirectory: true)
		do {
			if let response = downloadTask.response as? HTTPURLResponse,
				!(200...299).contains(response.statusCode)
			{
				throw URLError(.badServerResponse)
			}
			try FileManager.default.createDirectoryIfNeeded(at: directory)
			let destination = directory.appendingPathComponent("Package.ipa")
			try JSONEncoder().encode(Transfer(download)).write(to: directory.appendingPathComponent("Transfer.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
			try FileManager.default.moveItem(at: location, to: destination)
			download.progress = 1
			updateLiveActivity()
			if UIApplication.shared.applicationState == .active {
				handlePackageFile(url: destination, dl: download, removeAfterImport: true)
			}
		} catch {
			try? FileManager.default.removeItem(at: directory)
			finish(download, result: .failure(error))
		}
	}

	func urlSession(
		_ session: URLSession,
		downloadTask: URLSessionDownloadTask,
		didWriteData bytesWritten: Int64,
		totalBytesWritten: Int64,
		totalBytesExpectedToWrite: Int64
	) {
		guard let download = download(for: downloadTask), download.importTask == nil else { return }

		DispatchQueue.main.async {
			download.progress =
				totalBytesExpectedToWrite > 0
				? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
				: 0
			download.bytesDownloaded = totalBytesWritten
			download.totalBytes = totalBytesExpectedToWrite
			self.updateLiveActivity()

			#if !targetEnvironment(macCatalyst)
				if #available(iOS 26.0, *) {
					BackgroundTaskManager.shared.updateProgress(
						for: download.id,
						progress: download.overallProgress
					)
				}
			#endif
		}
	}

	func urlSession(
		_ session: URLSession,
		task: URLSessionTask,
		didCompleteWithError error: Error?
	) {
		guard let error, let downloadTask = task as? URLSessionDownloadTask,
			let download = download(for: downloadTask), download.importTask == nil
		else { return }
		finish(download, result: .failure(error))
	}
	func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
		let completion = backgroundCompletion
		backgroundCompletion = nil
		completion?()
	}

}
