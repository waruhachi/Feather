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
	private var outbox: URL?
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
		let outbox = FileManager.default.temporaryDirectory.appendingPathComponent("FeatherOutbox-" + UUID().uuidString)
		app.http.server.configuration.address = .hostname(host, port: port)
		app.http.server.configuration.hostname = host
		app.http.server.configuration.port = port
		Self.routes(on: app, inbox: inbox, outbox: outbox, password: password)
		do {
			try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: false, attributes: [.protectionKey: FileProtectionType.complete])
			try await app.server.start(address: .hostname(host, port: port))
			guard generation == currentGeneration, !Task.isCancelled else { throw CancellationError() }
			server = app
			self.outbox = outbox
			self.password = password
			address = URL(string: "http://\(host):\(port)")
		} catch {
			try? await app.asyncShutdown()
			try? FileManager.default.removeItem(at: outbox)
			throw error
		}
	}

	func stop() async {
		generation += 1
		guard let app = server else { return }
		let previousOutbox = outbox
		outbox = nil
		server = nil
		address = nil
		password = nil
		try? await app.asyncShutdown()
		if let previousOutbox { try? FileManager.default.removeItem(at: previousOutbox) }
	}

	func share(_ file: URL, name: String, session: URL) throws {
		guard address == session, let outbox else { throw CancellationError() }
		let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
		guard info.isRegularFile == true, info.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
		let title = name.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: "-")
		let safeName = String(title.prefix(120)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
		guard !safeName.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
		let folder = outbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
		do {
			try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(safeName))
		} catch {
			try? FileManager.default.removeItem(at: folder)
			throw error
		}
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

	nonisolated private static func routes(on app: Application, inbox: URL, outbox: URL, password: String) {
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
		app.get("outbox") { request -> Response in
			try authenticate(request)
			let folders = try FileManager.default.contentsOfDirectory(at: outbox, includingPropertiesForKeys: nil)
			let entries = folders.compactMap { folder -> Export? in
				guard let id = UUID(uuidString: folder.lastPathComponent),
					let file = try? exportFile(folder)
				else { return nil }
				return Export(id: id.uuidString, name: file.lastPathComponent)
			}
			let data = try JSONEncoder().encode(entries)
			return Response(status: .ok, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"], body: .init(data: data))
		}
		app.get("outbox", ":id") { request async throws -> Response in
			try authenticate(request)
			guard let raw = request.parameters.get("id"), let id = UUID(uuidString: raw) else { throw Abort(.notFound) }
			let file = try exportFile(outbox.appendingPathComponent(id.uuidString, isDirectory: true))
			let response = try await request.fileio.asyncStreamFile(at: file.path)
			response.headers.responseCompression = .disable
			response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
			response.headers.replaceOrAdd(name: .contentType, value: "application/octet-stream")
			response.headers.replaceOrAdd(name: .contentDisposition, value: "attachment")
			return response
		}
		TransferDAV.register(on: app, inbox: inbox, authenticate: authenticate)
	}

	private struct Export: Encodable {
		let id: String
		let name: String
	}

	nonisolated private static func exportFile(_ directory: URL) throws -> URL {
		let files = try? FileManager.default.contentsOfDirectory(
			at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
		)
		guard let files, files.count == 1, let file = files.first,
			let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
			info.isRegularFile == true, info.isSymbolicLink != true
		else { throw Abort(.notFound) }
		return file
	}

	nonisolated private static let uploadPage = """
	<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
	<title>Feather File Transfer</title><main><h1>Feather File Transfer</h1>
	<form><label>Select IPA or tweak files <input type="file" multiple accept=".ipa,.tipa,.deb,.dylib"></label>
	<button>Upload</button></form><p role="status"></p>
	<h2>Shared from Feather</h2><button type="button" id="refresh">Refresh</button><ul id="shared"></ul></main>
	<script>
	const form = document.querySelector('form');
	const status = document.querySelector('[role=status]');
	const refresh = async () => {
		try {
			const response = await fetch('/outbox', {cache: 'no-store'});
			if (!response.ok) throw new Error('HTTP ' + response.status);
			const files = await response.json();
			const rows = files.map(file => {
				const li = document.createElement('li');
				const link = document.createElement('a');
				link.href = '/outbox/' + encodeURIComponent(file.id);
				link.download = file.name;
				link.textContent = file.name;
				li.append(link);
				return li;
			});
			document.querySelector('#shared').replaceChildren(...rows);
		} catch (error) { status.textContent = error.message; }
	};
	document.querySelector('#refresh').addEventListener('click', refresh);
	refresh();
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
