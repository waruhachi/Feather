#if !targetEnvironment(macCatalyst)
import BackgroundTasks
import CoreData
import OSLog
import IDeviceSwift
import UIKit

@MainActor
enum PairedLibraryUpdates {
	static let enabledKey = "Feather.installLibraryUpdatesAutomatically"
	private static let selectionKey = "Feather.automaticUpdateBundleIDs"
	private static let retryKey = "Feather.automaticUpdateAttempts"
	private static var running = false
	private static let identifier = (Bundle.main.bundleIdentifier ?? "thewonderofyou.Feather") + ".pairedLibraryInstall"

	static func register() {
		BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
			MainActor.assumeIsolated {
				schedule()
				LibraryBackgroundTask.run(task) {
					await run(inBackground: true)
					return !Task.isCancelled
				}
			}
		}
	}

	static func schedule() {
		guard UserDefaults.standard.bool(forKey: enabledKey),
			UserDefaults.standard.integer(forKey: "Feather.installationMethod") == 1,
			!(UserDefaults.standard.stringArray(forKey: selectionKey) ?? []).isEmpty
		else {
			BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
			return
		}
		let request = BGProcessingTaskRequest(identifier: identifier)
		request.requiresNetworkConnectivity = true
		request.earliestBeginDate = Date(timeIntervalSinceNow: 3600)
		do { try BGTaskScheduler.shared.submit(request) }
		catch { Logger.misc.debug("Could not schedule paired Library updates: \(error.localizedDescription)") }
	}

	static func enabled(for app: AppInfoPresentable) -> Bool {
		guard let identifier = app.identifier else { return false }
		return (UserDefaults.standard.stringArray(forKey: selectionKey) ?? []).contains(identifier)
	}

	static func setEnabled(_ enabled: Bool, for app: AppInfoPresentable) {
		guard let identifier = app.identifier else { return }
		var selection = Set(UserDefaults.standard.stringArray(forKey: selectionKey) ?? [])
		if enabled { selection.insert(identifier) } else { selection.remove(identifier) }
		UserDefaults.standard.set(Array(selection), forKey: selectionKey)
		UserDefaults.standard.removeObject(forKey: retryKey)
		schedule()
	}

	static func run(inBackground: Bool = false) async {
		guard !running, isAvailable(inBackground: inBackground) else { return }
		running = true
		defer { running = false }

		let manager = UpdateManager.shared
		if !manager.isChecking, Date().timeIntervalSince(manager.lastCheckedDate ?? .distantPast) >= 3600 {
			_ = try? await LibraryUpdateInput.checkAll()
		}
		let storage = Storage.shared
		let request = Signed.fetchRequest()
		request.sortDescriptors = [NSSortDescriptor(keyPath: \Signed.date, ascending: false)]
		guard let signed = try? storage.context.fetch(request) else { return }
		var seen = Set<String>()
		for app in signed {
			guard isAvailable(inBackground: inBackground), !Task.isCancelled else { return }
			guard let identifier = app.identifier, identifier != Bundle.main.bundleIdentifier,
				seen.insert(identifier).inserted, enabled(for: app),
				let update = manager.update(for: app), update.canDownload,
				!Storage.shared.updatesDisabled(for: app.uuid),
				let installed = await Task.detached(priority: .utility, operation: { InstalledAppProbe().read(identifier).record }).value,
				installed.isInstalled, !installed.isPlaceholder,
				let version = installed.version, version == app.version,
				UpdateVersion.compare(update.remoteVersion, version) == .orderedDescending,
				let uuid = app.uuid, LibraryUpdateInput.acquire(uuid)
			else { continue }
			defer { LibraryUpdateInput.release(uuid) }
			guard markAttempt(update, identifier: identifier) else { continue }
			do {
				try await install(update, replacing: app, inBackground: inBackground)
				manager.clearCachedUpdate(for: app)
				await ActivityLog.shared.record(.init(action: .localized("Automatic Update"), app: update.appName, outcome: .localized("Installed")))
			} catch {
				await ActivityLog.shared.record(.init(action: .localized("Automatic Update"), app: update.appName, outcome: error.localizedDescription))
			}
		}
	}

	private static func isAvailable(inBackground: Bool) -> Bool {
		UserDefaults.standard.bool(forKey: enabledKey)
			&& UserDefaults.standard.integer(forKey: "Feather.installationMethod") == 1
			&& (UIApplication.shared.applicationState == .active || (inBackground && UIApplication.shared.isProtectedDataAvailable))
			&& FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile())
	}

	private static func markAttempt(_ update: AppUpdate, identifier: String) -> Bool {
		let defaults = UserDefaults.standard
		let key = "\(identifier)|\(update.remoteVersion)"
		let now = Date()
		let history = (defaults.dictionary(forKey: retryKey) as? [String: Date] ?? [:])
			.filter { now.timeIntervalSince($0.value) < 3600 }
		if history[key] != nil { return false }
		var updated = history
		updated[key] = now
		defaults.set(updated, forKey: retryKey)
		return true
	}

	private static func install(_ update: AppUpdate, replacing app: Signed, inBackground: Bool) async throws {
		let input = try await LibraryUpdateInput.download(update, inBackground: inBackground)
		try Task.checkCancellation()
		guard isAvailable(inBackground: inBackground), enabled(for: app), UpdateManager.shared.canApply(update), !app.isDeleted else {
			throw CancellationError()
		}
		try LibraryUpdateInput.checkIdentifier(input, update: update)
		let identifier = app.identifier ?? update.bundleIdentifier
		let recipe = try SigningRecipe.load(for: identifier)
		let certificate: CertificatePair
		if let pin = recipe?.certificateID {
			guard let match = Storage.shared.getAllCertificates().first(where: { $0.uuid == pin }) else {
				throw SigningPreflight.savedCertificateUnavailable
			}
			certificate = match
		} else {
			guard let prior = Storage.shared.getCertificate(from: app) else { throw SigningPreflight.savedCertificateUnavailable }
			certificate = prior
		}

		let defaults = OptionsManager.shared.options
		var options = recipe?.options(using: defaults) ?? defaults
		options.signingOption = .default
		options.injectedAppExtensions = []
		options.appIdentifier = identifier
		try SigningPreflight.checkReplacement(of: app, with: input, options: options, certificate: certificate)
		if let minimum = SigningPreflight.requiredSystemVersion(for: input, options: options) {
			throw SigningPreflight.newerSystemRequired(minimum)
		}
		let signedUUID = try await FR.signPackage(input, using: options, icon: recipe?.icon, certificate: certificate)
		let request = Signed.fetchRequest()
		request.predicate = NSPredicate(format: "uuid == %@", signedUUID)
		guard let replacement = try Storage.shared.context.fetch(request).first, isAvailable(inBackground: inBackground), enabled(for: app),
			UpdateManager.shared.canApply(update)
		else { throw CancellationError() }

		let viewModel = InstallerStatusViewModel(isIdevice: true)
		let archive = ArchiveHandler(app: replacement, viewModel: viewModel)
		try await archive.move()
		let package = try await archive.archive()
		guard isAvailable(inBackground: inBackground), enabled(for: app), UpdateManager.shared.canApply(update),
			let installed = await Task.detached(priority: .utility, operation: { InstalledAppProbe().read(identifier).record }).value,
			installed.isInstalled, !installed.isPlaceholder, installed.version == app.version
		else { throw CancellationError() }

		try Task.checkCancellation()
		let activity = WorkLiveActivity.begin(.installing, name: update.appName)
		do {
			try await InstallationProxy(viewModel: viewModel).install(at: package)
			guard case .completed(.success) = viewModel.status else { throw LibraryUpdateInput.Failure.installUnconfirmed }
			WorkLiveActivity.finish(activity, outcome: .installed)
		} catch {
			WorkLiveActivity.finish(activity, outcome: .failed)
			throw error
		}
		if options.post_deleteAppAfterSigned { Storage.shared.deleteApp(for: input) }
		Storage.shared.finishInstall(replacement, protecting: [])
	}
}
#endif
