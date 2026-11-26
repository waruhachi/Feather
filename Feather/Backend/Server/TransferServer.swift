import Foundation
import Vapor

@MainActor
final class TransferServer: ObservableObject {
	static let shared = TransferServer()
	static var inbox: URL { URL.applicationSupportDirectory.appendingPathComponent("FeatherTransferInbox", isDirectory: true) }
	nonisolated static let username = "feather"

	@Published private(set) var address: URL?
	@Published private(set) var password: String?
	@Published private(set) var isStarting = false
	private var server: Application?
	private var generation = 0

	func start() async throws {
		guard server == nil, !isStarting else { return }
		guard let host = Self.wifiAddress else { throw TransferError.noWiFi }
		try FileManager.default.createDirectoryIfNeeded(at: Self.inbox)

		isStarting = true
		let currentGeneration = generation
		defer { isStarting = false }
		let app = try await Application.make(ServerInstaller.env)
		let password = UUID().uuidString.replacingOccurrences(of: "-", with: "")
		let port = Int.random(in: 8100...8900)
		let inbox = Self.inbox
		app.http.server.configuration.address = .hostname(host, port: port)
		app.http.server.configuration.hostname = host
		app.http.server.configuration.port = port
		Self.routes(on: app, inbox: inbox, password: password)
		do {
			try await app.server.start(address: .hostname(host, port: port))
			guard generation == currentGeneration, !Task.isCancelled else { throw CancellationError() }
			server = app
			self.password = password
			address = URL(string: "http://\(host):\(port)")
		} catch {
			try? await app.asyncShutdown()
			throw error
		}
	}

	func stop() async {
		generation += 1
		guard let app = server else { return }
		server = nil
		address = nil
		password = nil
		try? await app.asyncShutdown()
	}

	private static var wifiAddress: String? {
		var interfaces: UnsafeMutablePointer<ifaddrs>?
		guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
		defer { freeifaddrs(first) }

		var cursor: UnsafeMutablePointer<ifaddrs>? = first
		while let interface = cursor?.pointee {
			cursor = interface.ifa_next
			guard let address = interface.ifa_addr,
				address.pointee.sa_family == UInt8(AF_INET),
				String(cString: interface.ifa_name) == "en0"
			else { continue }
			var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
			if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
				return String(cString: host)
			}
		}
		return nil
	}

	nonisolated private static func routes(on app: Application, inbox: URL, password: String) {
		@Sendable func authenticate(_ request: Request) throws {
			guard let credentials = request.headers.basicAuthorization,
				credentials.username == username,
				credentials.password == password
			else {
				var headers = HTTPHeaders()
				headers.add(name: .wwwAuthenticate, value: "Basic realm=\"Feather Transfer\"")
				throw Abort(.unauthorized, headers: headers)
			}
		}

		app.get { request -> Response in
			try authenticate(request)
			return Response(status: .ok, headers: ["Content-Type": "text/html; charset=utf-8"], body: .init(string: Self.uploadPage))
		}
		TransferDAV.register(on: app, inbox: inbox, authenticate: authenticate)
	}

	nonisolated private static let uploadPage = """
	<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
	<title>Feather File Transfer</title><main><h1>Feather File Transfer</h1>
	<form><label>Select IPA or tweak files <input type="file" multiple accept=".ipa,.tipa,.deb,.dylib"></label>
	<button>Upload</button></form><p role="status"></p></main>
	<script>
	const form = document.querySelector('form');
	const status = document.querySelector('[role=status]');
	form.addEventListener('submit', async (event) => {
		event.preventDefault();
		const button = form.querySelector('button');
		button.disabled = true;
		try {
			for (const file of form.querySelector('input').files) {
				status.textContent = 'Uploading ' + file.name;
				const result = await fetch('/files/' + encodeURIComponent(file.name), {method: 'PUT', body: file});
				if (!result.ok) throw new Error(file.name + ': HTTP ' + result.status);
			}
			status.textContent = 'Upload complete. Open the inbox in Feather.';
		} catch (error) { status.textContent = error.message; }
		finally { button.disabled = false; }
	});
	</script></html>
	"""

	private enum TransferError: LocalizedError {
		case noWiFi
		var errorDescription: String? { .localized("Connect to Wi-Fi to start File Transfer.") }
	}
}
