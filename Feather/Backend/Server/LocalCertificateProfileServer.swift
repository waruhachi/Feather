#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit
import Vapor

@MainActor
enum LocalCertificateProfileServer {
	private static var server: Application?
	private static var backgroundTask = UIBackgroundTaskIdentifier.invalid

	static func open() throws {
		let profile = try LocalCertificate.profile()
		stop()

		let port = Int.random(in: 4000...8000)
		let token = UUID().uuidString
		let path = "\(token)/Feather.mobileconfig"
		let application = Application(ServerInstaller.env)
		application.http.server.configuration.address = .hostname("127.0.0.1", port: port)
		application.get(.constant(token), "Feather.mobileconfig") { _ in
			Response(status: .ok, headers: ["Content-Type": "application/x-apple-aspen-config"],
					 body: .init(data: profile))
		}
		do {
			try application.server.start()
		} catch {
			application.shutdown()
			throw error
		}
		server = application

		backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Feather Certificate Profile") {
			Task { @MainActor in
				if server === application { stop() }
			}
		}
		UIApplication.shared.open(URL(string: "http://127.0.0.1:\(port)/\(path)")!) { opened in
			if !opened, server === application { stop() }
		}
		Task {
			try? await Task.sleep(for: .seconds(60))
			if server === application { stop() }
		}
	}

	private static func stop() {
		if let server {
			self.server = nil
			server.server.shutdown()
			server.shutdown()
		}
		if backgroundTask != .invalid {
			UIApplication.shared.endBackgroundTask(backgroundTask)
			backgroundTask = .invalid
		}
	}
}
#endif
