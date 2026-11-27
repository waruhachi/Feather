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
				LibraryBackgroundTask.run(task) {
					let completed = await checkIfDue()
					await CertificateHealth.checkIfDue()
					return completed
				}
			}
		}
	}

	static func schedule(after now: Date = Date()) {
		let seconds = interval == .off && UserDefaults.standard.bool(forKey: FeatherAlerts.certificatesKey) ? Interval.daily.rawValue : interval.rawValue
		guard seconds > 0 else {
			BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
			return
		}
		let request = BGAppRefreshTaskRequest(identifier: identifier)
		request.earliestBeginDate = now.addingTimeInterval(TimeInterval(seconds))
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
		do {
			return try await LibraryUpdateInput.checkAll()
		} catch {
			Logger.misc.debug("Library update check could not read the Library: \(error.localizedDescription)")
			return false
		}
	}
}

@MainActor
enum LibraryBackgroundTask {
	static func run(_ task: BGTask, operation: @escaping @MainActor () async -> Bool) {
		var finished = false
		func finish(_ success: Bool) {
			guard !finished else { return }
			finished = true
			task.expirationHandler = nil
			task.setTaskCompleted(success: success)
		}
		let work = Task { @MainActor in
			let completed = await operation()
			finish(completed && !Task.isCancelled)
		}
		task.expirationHandler = {
			work.cancel()
			Task { @MainActor in finish(false) }
		}
	}
}
#endif
