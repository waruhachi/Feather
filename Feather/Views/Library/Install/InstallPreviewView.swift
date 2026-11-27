//
//  InstallPreview.swift
//  Feather
//
//  Created by samara on 22.04.2025.
//

import SwiftUI
import NimbleViews
import IDeviceSwift
import OSLog

// MARK: - View
struct InstallPreviewView: View {
	@Environment(\.dismiss) var dismiss

	@AppStorage("Feather.useShareSheetForArchiving") private var _useShareSheet: Bool = false
	@AppStorage("Feather.installationMethod") private var _installationMethod: Int = 0
	@AppStorage("Feather.serverMethod") private var _serverMethod: Int = 0
	@State private var _isWebviewPresenting = false
	@State private var progressTask: Task<Void, Never>?
	@State private var installTask: Task<Void, Never>?
	@State private var started = false
	@State private var didFinish = false
	@State private var didReceivePayload = false
	@State private var verifiedOTA = false
	@State private var activityID: UUID?
	@AppStorage("Feather.dismissInstallAfterFinish") private var dismissAfterFinish = false
	@AppStorage("Feather.openImportAfterInstall") private var openImportAfterInstall = false
	
	private let appUUID: String?
	var app: AppInfoPresentable
	var onOutcome: ((String) -> Void)?
	var onVerifiedInstall: (() -> Void)?
	var onTransferStarted: (() -> Void)?
	var protectedCopies: () -> Set<String>
	@StateObject var viewModel: InstallerStatusViewModel
	@StateObject var installer: ServerInstaller
	
	@State var isSharing: Bool
	
	init(app: AppInfoPresentable, isSharing: Bool = false, onOutcome: ((String) -> Void)? = nil,
		 onVerifiedInstall: (() -> Void)? = nil, onTransferStarted: (() -> Void)? = nil, protectedCopies: @escaping () -> Set<String> = { [] }) {
		self.onOutcome = onOutcome
		self.onVerifiedInstall = onVerifiedInstall
		self.onTransferStarted = onTransferStarted
		self.protectedCopies = protectedCopies
		self.app = app
		self.appUUID = app.uuid
		self.isSharing = isSharing
		let viewModel = InstallerStatusViewModel(isIdevice: UserDefaults.standard.integer(forKey: "Feather.installationMethod") == 1)
		self._viewModel = StateObject(wrappedValue: viewModel)
		self._installer = StateObject(wrappedValue: ServerInstaller(app: app, viewModel: viewModel))
	}
	
	// MARK: Body
	var body: some View {
		let cornerRadius = {
			if #available(iOS 26.0, *) {
				28.0
			} else {
				10.5
			}
		}()
		
		ZStack {
			InstallProgressView(app: app, viewModel: viewModel, otaPayload: installer.payloadProgress)
			_status()
			_button()
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
		.background(Color(UIColor.secondarySystemBackground))
		.cornerRadius(cornerRadius)
		.padding()
		.sheet(isPresented: $_isWebviewPresenting) {
			SafariRepresentableView(url: installer.pageEndpoint).ignoresSafeArea()
		}
		.onReceive(viewModel.$status) { status in
			switch status {
			case .ready where _installationMethod == 0:
				guard let identifier = app.identifier else { return }
				progressTask = startInstallProgressPolling(bundleID: identifier, viewModel: viewModel)
				if _serverMethod == 0 {
					if let url = installer.iTunesLink {
						UIApplication.shared.open(url) { opened in
							if !opened { viewModel.status = .broken(URLError(.cannotOpenFile)) }
						}
					} else {
						viewModel.status = .broken(URLError(.badURL))
					}
				} else {
					_isWebviewPresenting = true
				}
			case .sendingPayload where _installationMethod == 0:
				_isWebviewPresenting = false
				if !didReceivePayload {
					didReceivePayload = true
					onTransferStarted?()
				}
			case .completed(.success):
				let verified = _installationMethod == 1 || verifiedOTA
				if verified {
					onVerifiedInstall?()
					Storage.shared.finishInstall(app, protecting: protectedCopies())
				}
				finish(.localized(verified ? "Installed" : "Finished. Check Home Screen."), completed: true, verified: verified)
			case .completed(.failure(let error)), .broken(let error):
				finish(error.localizedDescription, completed: false)
			default: break
			}
		}
		.onAppear(perform: _install)
		.onChange(of: InstallProgressView.progress(for: viewModel, otaPayload: installer.payloadProgress)) { progress in
			if let activityID { WorkLiveActivity.update(activityID, progress: progress) }
		}
		
		#if !targetEnvironment(macCatalyst)
		.onAppear {
			BackgroundAudioManager.shared.start(owner: installer.id.uuidString)
		}
		#endif
		
		.onDisappear {
			InstallShortcut.finish(for: appUUID, verified: false)
			endActivity(.cancelled)
			installTask?.cancel()
			installTask = nil
			progressTask?.cancel()
			progressTask = nil
			
			#if !targetEnvironment(macCatalyst)
			BackgroundAudioManager.shared.stop(owner: installer.id.uuidString)
			#endif
		}
	}
	
	@ViewBuilder
	private func _status() -> some View {
		Label(installSucceeded && _installationMethod == 0 && !verifiedOTA
			  ? .localized("Finished. Check Home Screen.") : viewModel.statusLabel, systemImage: viewModel.statusImage)
			.padding()
			.labelStyle(.titleAndIcon)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
			.animation(.smooth, value: viewModel.statusImage)
	}
	
	@ViewBuilder
	private func _button() -> some View {
		ZStack {
			if installSucceeded && (_installationMethod == 1 || verifiedOTA) {
				Button {
					UIApplication.openApp(with: installer.appIdentifier)
				} label: {
					NBButton("Open", systemImage: "", style: .text)
				}
				.padding()
				.compatTransition()
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
		.animation(.easeInOut(duration: 0.3), value: viewModel.isCompleted)
	}
	
	private func _install() {
		guard !started else { return }
		started = true
		guard isSharing || app.identifier != Bundle.main.bundleIdentifier! || _installationMethod == 1 else {
			if let onOutcome {
				onOutcome(.localized("Feather cannot replace itself through a server install."))
				return
			}
			UIAlertController.showAlertWithOk(
				title: .localized("Install"),
				message: .localized("You cannot update ‘%@‘ with itself, please use an alternative tool to update it.", arguments: Bundle.main.name)
			)
			return
		}
				
		if !isSharing {
			activityID = WorkLiveActivity.begin(.installing, name: app.name ?? .localized("Unknown"))
		}
		installTask = Task.detached {
			do {
				let handler = await ArchiveHandler(app: app, viewModel: viewModel)
				try await handler.move()
				
				let packageUrl = try await handler.archive()
				try Task.checkCancellation()
				
				if await !isSharing {
					if await _installationMethod == 0 {
						if await _serverMethod == 0,
						   !LocalCertificate.isEnabled, InstallTLSCertificates.preferredIdentity() == nil {
							try await InstallTLSCertificates.shared.refresh()
						}
						let server = await MainActor.run { installer }
						try await server.prepareManifest()
						try Task.checkCancellation()
						try await MainActor.run { try server.start(package: handler.installation) }
						try await server.verifyHTTPS()
						try Task.checkCancellation()
						await MainActor.run { viewModel.status = .ready }
					} else if await _installationMethod == 1 {
						let handler = await InstallationProxy(viewModel: viewModel)
						try await handler.install(at: packageUrl, suspend: app.identifier == Bundle.main.bundleIdentifier!)
					}
				} else {
					let package = try await handler.moveToArchive(packageUrl, shouldOpen: !_useShareSheet)
					
					if await !_useShareSheet {
						await MainActor.run {
							dismiss()
						}
					} else {
						if let package {
							await MainActor.run {
								dismiss()
								UIActivityViewController.show(activityItems: [package])
							}
						}
					}
				}
			} catch is CancellationError {
				return
			} catch {
				await progressTask?.cancel()
				await MainActor.run { viewModel.status = .broken(error) }
				
				await MainActor.run {
					guard onOutcome == nil else { return }
					UIAlertController.showAlertWithOk(
						title: .localized("Install"),
						message: error.localizedDescription,
						action: {
							HeartbeatManager.shared.start(true)
							dismiss()
						}
					)
				}
			}
		}
	}
	
	private var installSucceeded: Bool {
		if case .completed(.success) = viewModel.status { return true }
		return false
	}

	private func endActivity(_ outcome: WorkLiveActivity.Outcome) {
		guard let activityID else { return }
		WorkLiveActivity.finish(activityID, outcome: outcome)
		self.activityID = nil
	}

	private func finish(_ message: String, completed: Bool, verified: Bool = false) {
		guard !didFinish else { return }
		InstallShortcut.finish(for: appUUID, verified: verified)
		didFinish = true
		endActivity(completed ? (verified ? .installed : .unconfirmed) : .failed)
		progressTask?.cancel()
		progressTask = nil
		#if !targetEnvironment(macCatalyst)
		BackgroundAudioManager.shared.stop(owner: installer.id.uuidString)
		#endif
		let name = installer.appName
		Task { await ActivityLog.shared.record(.init(action: .localized("Install"), app: name, outcome: message)) }
		if let onOutcome {
			onOutcome(message)
		} else if completed && (dismissAfterFinish || openImportAfterInstall) {
			if openImportAfterInstall { NotificationCenter.default.post(name: .featherImportAfterInstall, object: nil) }
			dismiss()
		}
	}

	private func startInstallProgressPolling(bundleID: String, viewModel: InstallerStatusViewModel) -> Task<Void, Never> {
		let probe = InstalledAppProbe()
		let baseline = probe.read(bundleID).record
		probe.resetProgress()
		let build = Storage.shared.getAppDirectory(for: app).flatMap(Bundle.init(url:))?
			.object(forInfoDictionaryKey: "CFBundleVersion") as? String
		let version = app.version
		return Task { @MainActor in
			var state = OTAInstallState()
			let clock = ProcessInfo.processInfo
			state.advance(to: .waiting, now: clock.systemUptime)
			while !Task.isCancelled {
				if didReceivePayload { state.advance(to: .downloading, now: clock.systemUptime) }
				if case .installing = viewModel.status { state.advance(to: .verifying, now: clock.systemUptime) }
				let evidence = await Task.detached(priority: .utility) { probe.read(bundleID) }.value
				guard !Task.isCancelled else { return }
				let progress = evidence.progress
				if state.phase != .waiting && (progress?.isCancelled == true || progress?.installStateName == "Failed") {
					viewModel.status = .broken(InstallProgressError.failed)
					return
				}
				if state.confirmsInstall(progress)
					|| (state.phase == .verifying && evidence.record?.confirmsReplacement(of: baseline, version: version, build: build) == true) {
					verifiedOTA = true
					installer.log("Install confirmed by iOS")
					viewModel.installProgress = 1
					viewModel.status = .completed(.success(()))
					return
				}
				if state.progressEnded(progress, now: clock.systemUptime) {
					installer.log("Progress ended without install confirmation")
					viewModel.installProgress = 1
					viewModel.status = .completed(.success(()))
					return
				}
				if state.timedOut(at: clock.systemUptime) {
					installer.log("Install timed out in \(state.phase)")
					if state.phase == .verifying {
						viewModel.status = .completed(.success(()))
					} else {
						viewModel.status = .broken(InstallProgressError.timedOut)
					}
					return
				}
				if let fraction = progress?.fraction, fraction.isFinite {
					viewModel.installProgress = min(1, max(0, (fraction - 0.6) / 0.3))
				}
				try? await Task.sleep(for: .milliseconds(250))
			}
		}
	}

	private enum InstallProgressError: LocalizedError {
		case failed, timedOut
		var errorDescription: String? {
			switch self {
			case .failed: .localized("iOS reported that installation failed or was cancelled.")
			case .timedOut: .localized("iOS did not finish downloading the IPA.")
			}
		}
	}
}

extension Notification.Name {
	static let featherImportAfterInstall = Notification.Name("Feather.importAfterInstall")
}
