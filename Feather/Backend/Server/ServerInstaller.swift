//
//  Server.swift
//  feather
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
//

import Foundation
import Vapor
import NIOSSL
import NIOTLS
import SwiftUI
import IDeviceSwift

// MARK: - Class
class ServerInstaller: Identifiable, ObservableObject {
	let id = UUID()
	let port = Int.random(in: 4000...8000)
	private var _needsShutdown = false
	
	private(set) var package: InstallationArchive?
	@Published private(set) var payloadProgress: OTAPayloadProgress.Snapshot?
	private var payloadTracker: OTAPayloadProgress?
	private(set) var manifestURL: URL?
	var tlsHost: String?
	let appIdentifier: String
	let appName: String
	let appVersion: String
	@ObservedObject var viewModel: InstallerStatusViewModel
	private var _server: Application?

	init(app: AppInfoPresentable, viewModel: InstallerStatusViewModel) {
		self.appIdentifier = app.identifier ?? ""
		self.appName = app.name ?? .localized("Unknown")
		self.appVersion = app.version ?? ""
		self.viewModel = viewModel
	}

	deinit {
		_shutdownServer()
	}

	func prepareManifest() async throws {
		guard getServerMethod() == 1 else { return }
		manifestURL = try await ManifestService.resolve(identifier: appIdentifier, name: appName,
			version: appVersion, payload: payloadEndpoint)
	}

	func start(package: InstallationArchive) throws {
		guard _server == nil else { return }
		guard let size = try package.url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
			throw Abort(.internalServerError, reason: "The installation archive is empty.")
		}
		let server = try setupApp(port: port)
		let tracker = OTAPayloadProgress(total: size)
		payloadTracker = tracker
		payloadProgress = tracker.snapshot
		self.package = package
		_server = server
		do {
			try _configureRoutes()
			try server.server.start()
			_needsShutdown = true
			log(getServerMethod() == 1 ? "Semi Local server ready" : "Fully Local HTTPS server ready")
		} catch {
			server.shutdown()
			_server = nil
			self.package = nil
			throw error
		}
	}

	private func _configureRoutes() throws {
		_server?.get("*") { [weak self] req in
			guard let self else { return Response(status: .badGateway) }
			switch req.url.path {
			case plistEndpoint.path:
				if req.method == .GET { self._updateStatus(.sendingManifest) }
				self.log("Manifest \(req.method.rawValue)")
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "text/xml",
				], body: .init(data: installManifestData))
			case displayImageSmallEndpoint.path:
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "image/png",
				], body: .init(data: displayImageSmallData))
			case displayImageLargeEndpoint.path:
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "image/png",
				], body: .init(data: displayImageLargeData))
			case payloadEndpoint.path:
				guard let package, let payloadTracker else { return Response(status: .notFound) }
				return self._payload(package, tracking: payloadTracker, for: req)
			case "/healthz":
				return Response(status: .ok)
			case "/install":
				var headers = HTTPHeaders()
				headers.add(name: .contentType, value: "text/html")
				return Response(status: .ok, headers: headers, body: .init(string: self.html))
			default:
				return Response(status: .notFound)
			}
		}
	}
	
	private func _payload(_ package: InstallationArchive, tracking: OTAPayloadProgress, for request: Request) -> Response {
		let fileIO = request.fileio
		let path = package.url.path
		let response = fileIO.streamFile(at: path, mediaType: .binary)
		response.headers.responseCompression = .disable
		let range = request.headers.first(name: .range) ?? "full"
		let count = response.body.count
		log("IPA \(request.method.rawValue) HTTP \(response.status.code), \(count) bytes (\(range))")
		guard request.method == .GET else { return response }
		guard response.status == .ok || response.status == .partialContent else {
			if response.status != .rangeNotSatisfiable && response.status != .notModified && response.status != .badRequest {
				_updateStatus(.broken(Abort(response.status)))
			}
			return response
		}

		let start: Int
		if response.status == .partialContent {
			guard let header = response.headers.contentRange, header.unit == .bytes,
				case .withinWithLimit(let lower, let upper, let total) = header.range,
				total == tracking.total, lower >= 0, upper >= lower, upper < total,
				count == upper - lower + 1
			else {
				return Response(status: .rangeNotSatisfiable,
					headers: ["Content-Range": "bytes */\(tracking.total)"])
			}
			start = lower
		} else {
			start = 0
			guard count == tracking.total else { return Response(status: .internalServerError) }
		}

		response.body = .init(asyncStream: { [weak self, package, tracking] writer in
			defer { withExtendedLifetime(package) {} }
			var offset = start
			do {
				let chunks = try await fileIO.readFile(at: path, chunkSize: 512 * 1024,
					offset: Int64(start), byteCount: count)
				do {
					for try await chunk in chunks {
						let nextOffset = offset + chunk.readableBytes
						guard nextOffset <= start + count else { throw Abort(.internalServerError) }
						try await writer.writeBuffer(chunk)
						if offset == start { self?._updateStatus(.sendingPayload) }
						if let progress = tracking.record(offset..<nextOffset) { self?._publish(progress) }
						offset = nextOffset
					}
					guard offset == start + count else { throw Abort(.internalServerError) }
					try await writer.write(.end)
				} catch {
					try? await chunks.closeHandle()
					throw error
				}
				let progress = tracking.snapshot
				self?._publish(progress)
				self?.log("IPA stream completed (\(range)), \(progress.sent)/\(progress.total) unique bytes sent")
				if progress.isComplete { self?._updateStatus(.installing) }
			} catch {
				self?._publish(tracking.snapshot)
				self?.log("IPA stream interrupted after \(offset - start)/\(count) bytes: \(error.localizedDescription)")
				try? await writer.write(.error(error))
			}
		}, count: count, byteBufferAllocator: request.byteBufferAllocator)
		return response
	}

	private func _publish(_ progress: OTAPayloadProgress.Snapshot) {
		DispatchQueue.main.async {
			if progress.sent > (self.payloadProgress?.sent ?? 0) {
				self.payloadProgress = progress
			}
		}
	}

	private func _shutdownServer() {
		guard _needsShutdown else { return }
		
		_needsShutdown = false
		_server?.server.shutdown()
		_server?.shutdown()
	}
	
	func log(_ detail: String) {
		let name = appName
		Task { await ActivityLog.shared.record(.init(action: .localized("Install Diagnostics"), app: name, outcome: detail)) }
	}

	private func _updateStatus(_ newStatus: InstallerStatusViewModel.InstallerStatus) {
		DispatchQueue.main.async {
			switch (self.viewModel.status, newStatus) {
			case (.completed, _), (.broken, _), (.installing, .sendingPayload), (.installing, .sendingManifest),
			     (.sendingPayload, .sendingManifest):
				return
			default:
				self.viewModel.status = newStatus
			}
		}
	}
		
	func getServerMethod() -> Int {
		UserDefaults.standard.integer(forKey: "Feather.serverMethod")
	}
	
	func getIPFix() -> Bool {
		UserDefaults.standard.bool(forKey: "Feather.ipFix")
	}
}
