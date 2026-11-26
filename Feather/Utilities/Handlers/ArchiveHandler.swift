//
//  ArchiveHandler.swift
//  Feather
//
//  Created by samara on 22.04.2025.
//

import Foundation
import UIKit.UIApplication
import Zip
import SwiftUI
import IDeviceSwift

final class ArchiveHandler: NSObject {
	@ObservedObject var viewModel: InstallerStatusViewModel
	
	private let _fileManager = FileManager.default
	private var _payloadUrl: URL?
	
	private var _app: AppInfoPresentable
	let installation = InstallationArchive()
	private var _uniqueWorkDir: URL { installation.directory }
	
	init(app: AppInfoPresentable, viewModel: InstallerStatusViewModel) {
		self.viewModel = viewModel
		self._app = app
		
		super.init()
	}
	
	func move() async throws {
		guard let appUrl = Storage.shared.getAppDirectory(for: _app) else {
			throw SigningFileHandlerError.appNotFound
		}
		
		let payloadUrl = _uniqueWorkDir.appendingPathComponent("Payload")
		let movedAppURL = payloadUrl.appendingPathComponent(appUrl.lastPathComponent)

		try _fileManager.createDirectoryIfNeeded(at: payloadUrl)
		
		try _fileManager.copyItem(at: appUrl, to: movedAppURL)
		_payloadUrl = payloadUrl
	}
	
	func archive() async throws -> URL {
		guard let payloadUrl = _payloadUrl else { throw SigningFileHandlerError.appNotFound }
		let archive = installation
		let zipUrl = archive.directory.appendingPathComponent("Archive.zip")
		let compression = ZipCompression.allCases[ArchiveHandler.getCompressionLevel()]
		return try await Task.detached(priority: .background) { [viewModel, archive] in
			try await Zip.zipFiles(
				paths: [payloadUrl],
				zipFilePath: zipUrl,
				password: nil,
				compression: compression,
				progress: { progress in
					Task { @MainActor in
						viewModel.packageProgress = progress
					}
				})
			
			try FileManager.default.moveItem(at: zipUrl, to: archive.url)
			return archive.url
		}.value
	}
	
	func moveToArchive(_ package: URL, shouldOpen: Bool = false) async throws -> URL? {
		let manager = FileManager.default
		let title = [_app.name ?? "Feather", _app.version].compactMap { $0 }.joined(separator: " ")
			.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
		var destination = manager.archives.appendingPathComponent(title).appendingPathExtension("ipa")
		var sequence = 2
		while manager.fileExists(atPath: destination.path) {
			destination = manager.archives.appendingPathComponent("\(title) (\(sequence))").appendingPathExtension("ipa")
			sequence += 1
		}
		try manager.moveItem(at: package, to: destination)

		if shouldOpen {
			await MainActor.run {
				UIApplication.open(FileManager.default.archives.toSharedDocumentsURL()!)
			}
		}
		
		return destination
	}
	
	static func getCompressionLevel() -> Int {
		UserDefaults.standard.integer(forKey: "Feather.compressionLevel")
	}
}
