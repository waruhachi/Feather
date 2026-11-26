#if !targetEnvironment(macCatalyst)
import BackgroundTasks
import CoreData
import OSLog

@MainActor
enum ScheduledLibraryUpdates {
	enum Interval: Int, CaseIterable {
		case off = 0
		case hourly = 3600
		case daily = 86400
	}

	static let preferenceKey = "Feather.libraryUpdateInterval"
	private static let identifier = (Bundle.main.bundleIdentifier ?? "thewonderofyou.Feather") + ".libraryUpdateCheck"

	private static var interval: Interval {
		Interval(rawValue: UserDefaults.standard.integer(forKey: preferenceKey)) ?? .off
	}

	static func register() {
		BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
			MainActor.assumeIsolated {
				schedule(after: Date())
				let check = Task { @MainActor in
					let completed = await checkIfDue()
					task.setTaskCompleted(success: completed && !Task.isCancelled)
				}
				task.expirationHandler = { check.cancel() }
			}
		}
	}

	static func schedule(after now: Date = Date()) {
		guard interval != .off else {
			BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
			return
		}
		let request = BGAppRefreshTaskRequest(identifier: identifier)
		request.earliestBeginDate = now.addingTimeInterval(TimeInterval(interval.rawValue))
		do {
			try BGTaskScheduler.shared.submit(request)
		} catch {
			Logger.misc.debug("Library update check could not be scheduled: \(error.localizedDescription)")
		}
	}

	@discardableResult
	static func checkIfDue() async -> Bool {
		let manager = UpdateManager.shared
		guard interval != .off else { return true }
		if let checked = manager.lastCheckedDate, Date().timeIntervalSince(checked) < TimeInterval(interval.rawValue) {
			return true
		}
		let storage = Storage.shared
		do {
			let signed = try storage.context.fetch(Signed.fetchRequest())
			let imported = try storage.context.fetch(Imported.fetchRequest())
			let apps: [AppInfoPresentable] = signed.map { $0 as AppInfoPresentable } + imported.map { $0 as AppInfoPresentable }
			return await manager.checkForUpdates(sources: storage.getSources(), localApps: apps)
		} catch {
			Logger.misc.debug("Library update check could not read the Library: \(error.localizedDescription)")
			return false
		}
	}
}
#endif
