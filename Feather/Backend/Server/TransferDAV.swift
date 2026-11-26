import Foundation
import Vapor

enum TransferDAV {
	private static let mutations = NSLock()
	private static let headers: HTTPHeaders = [
		"DAV": "1", "Allow": "OPTIONS, PROPFIND, GET, HEAD, PUT, MKCOL, MOVE, COPY, DELETE",
	]
	private static let allowedUploads = ["ipa", "tipa", "deb", "dylib"]

	static func register(on app: Application, inbox: URL, authenticate: @escaping @Sendable (Request) throws -> Void) {
		for route: [PathComponent] in [["files"], ["files", .catchall]] {
			app.on(.OPTIONS, route) { request -> Response in
				try authenticate(request)
				return Response(status: .ok, headers: headers)
			}
			app.on(.PROPFIND, route) { request -> Response in
				try authenticate(request)
				let components = try components(in: request.url.path)
				let item = try location(components, in: inbox)
				let values = try properties(of: item)
				var body = member(components, values: values)
				let depth = request.headers.first(name: "Depth") ?? "1"
				guard ["0", "1"].contains(depth) else { throw Abort(.forbidden, reason: "Use WebDAV depth 0 or 1.") }
				if values.directory && depth == "1" {
					let children = try FileManager.default.contentsOfDirectory(at: item,
						includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
						options: .skipsHiddenFiles)
					body += children.compactMap { child in
						(try? properties(of: child)).map { member(components + [child.lastPathComponent], values: $0) }
					}.joined()
				}
				var responseHeaders = headers
				responseHeaders.replaceOrAdd(name: .contentType, value: "application/xml; charset=utf-8")
				return Response(status: .multiStatus, headers: responseHeaders,
					body: .init(string: "<?xml version=\"1.0\"?><D:multistatus xmlns:D=\"DAV:\">" + body + "</D:multistatus>"))
			}
		}

		let items: [PathComponent] = ["files", .catchall]
		app.on(.GET, items) { request async throws -> Response in
			try authenticate(request)
			let item = try location(components(in: request.url.path), in: inbox)
			guard try !properties(of: item).directory else { throw Abort(.methodNotAllowed) }
			let response = try await request.fileio.asyncStreamFile(at: item.path)
			response.headers.responseCompression = .disable
			return response
		}
		app.on(.PUT, items, body: .stream) { request async throws -> Response in
			try authenticate(request)
			let names = try components(in: request.url.path)
			guard let name = names.last else { throw Abort(.forbidden) }
			let isInboxFile = allowedUploads.contains((name as NSString).pathExtension.lowercased())
			guard names.count > 1 || isInboxFile else { throw Abort(.unsupportedMediaType) }
			let manager = FileManager.default
			let stage = inbox.appendingPathComponent(".upload-" + UUID().uuidString)
			guard manager.createFile(atPath: stage.path, contents: nil) else { throw Abort(.insufficientStorage) }
			defer { try? manager.removeItem(at: stage) }
			let file = try FileHandle(forWritingTo: stage)
			defer { try? file.close() }
			var size: Int64 = 0
			for try await buffer in request.body {
				try Task.checkCancellation()
				size += Int64(buffer.readableBytes)
				guard size <= 8 * 1024 * 1024 * 1024 else { throw Abort(.payloadTooLarge) }
				try file.write(contentsOf: Data(buffer.readableBytesView))
			}
			try file.close()
			guard names.count > 1 || size > 0 else { throw Abort(.badRequest) }
			return try mutations.withLock {
				let destination = try location(names, in: inbox)
				let exists = manager.fileExists(atPath: destination.path)
				try requireParent(of: destination)
				// Preserve browser uploads with the same name. Nested WebDAV files support replacement.
				if exists, names.count == 1 { throw Abort(.conflict) }
				if exists {
					guard try !properties(of: destination).directory else { throw Abort(.conflict) }
					_ = try manager.replaceItemAt(destination, withItemAt: stage)
				} else {
					try manager.moveItem(at: stage, to: destination)
				}
				return Response(status: exists ? .noContent : .created)
			}
		}
		app.on(.MKCOL, items) { request -> Response in
			try authenticate(request)
			let names = try components(in: request.url.path)
			guard !names.isEmpty else { throw Abort(.methodNotAllowed) }
			guard request.body.data?.readableBytes ?? 0 == 0 else { throw Abort(.unsupportedMediaType) }
			return try mutations.withLock {
				let directory = try location(names, in: inbox)
				try requireParent(of: directory)
				guard !FileManager.default.fileExists(atPath: directory.path) else { throw Abort(.methodNotAllowed) }
				try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
				return Response(status: .created)
			}
		}
		app.on(.DELETE, items) { request -> Response in
			try authenticate(request)
			let names = try components(in: request.url.path)
			guard !names.isEmpty else { throw Abort(.forbidden) }
			return try mutations.withLock {
				let item = try location(names, in: inbox)
				_ = try properties(of: item)
				try FileManager.default.removeItem(at: item)
				return Response(status: .noContent)
			}
		}
		for method: HTTPMethod in [.MOVE, .COPY] {
			app.on(method, items) { request async throws -> Response in
				try authenticate(request)
				let sourceNames = try components(in: request.url.path)
				let destinationNames = try destinationComponents(for: request)
				let overwrite = request.headers.first(name: "Overwrite")?.uppercased() != "F"
				guard !sourceNames.isEmpty, !destinationNames.isEmpty,
					!destinationNames.starts(with: sourceNames), !sourceNames.starts(with: destinationNames)
				else { throw Abort(.forbidden) }
				return try await request.application.threadPool.runIfActive(eventLoop: request.eventLoop) {
					try mutations.withLock {
						try relocate(sourceNames, destinationNames, in: inbox, copying: method == .COPY, overwrite: overwrite)
					}
				}.get()
			}
		}
	}

	private static func components(in path: String) throws -> [String] {
		let parts = path.split(separator: "/")
		guard parts.first == "files" else { throw Abort(.notFound) }
		return try parts.dropFirst().map { component in
			guard let name = component.removingPercentEncoding, !name.isEmpty, !name.hasPrefix("."),
				!name.contains("/"), !name.contains("\\"), !name.contains("\0")
			else { throw Abort(.forbidden) }
			return name
		}
	}

	private static func destinationComponents(for request: Request) throws -> [String] {
		guard let header = request.headers.first(name: "Destination"),
			let target = URLComponents(string: header),
			target.query == nil, target.fragment == nil, target.user == nil, target.password == nil
		else { throw Abort(.badRequest) }
		if let scheme = target.scheme {
			guard scheme == "http", let host = target.host,
				let expected = request.headers.first(name: .host),
				(host + (target.port.map { ":\($0)" } ?? "")).caseInsensitiveCompare(expected) == .orderedSame
			else { throw Abort(.badGateway) }
		} else if target.host != nil {
			throw Abort(.badRequest)
		}
		return try components(in: target.percentEncodedPath)
	}

	private static func location(_ names: [String], in inbox: URL) throws -> URL {
		var current = inbox
		for name in names {
			current.appendPathComponent(name)
			if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
				throw Abort(.forbidden)
			}
		}
		return current
	}

	private static func requireParent(of item: URL) throws {
		guard (try? properties(of: item.deletingLastPathComponent()).directory) == true else {
			throw Abort(.conflict)
		}
	}

	private static func relocate(_ sourceNames: [String], _ destinationNames: [String], in inbox: URL,
								 copying: Bool, overwrite: Bool) throws -> Response {
		let manager = FileManager.default
		let source = try location(sourceNames, in: inbox)
		let destination = try location(destinationNames, in: inbox)
		let sourceProperties = try properties(of: source)
		try requireParent(of: destination)
		if !sourceProperties.directory, destinationNames.count == 1,
		   !allowedUploads.contains(destination.pathExtension.lowercased()) { throw Abort(.unsupportedMediaType) }
		let exists = manager.fileExists(atPath: destination.path)
		if exists && !overwrite { throw Abort(.preconditionFailed) }
		let stage = inbox.appendingPathComponent(".relocate-" + UUID().uuidString)
		if exists { try manager.moveItem(at: destination, to: stage) }
		do {
			if copying { try manager.copyItem(at: source, to: destination) }
			else { try manager.moveItem(at: source, to: destination) }
		} catch {
			if copying { try? manager.removeItem(at: destination) }
			if exists { try manager.moveItem(at: stage, to: destination) }
			throw error
		}
		if exists { try? manager.removeItem(at: stage) }
		return Response(status: exists ? .noContent : .created)
	}

	private static func properties(of url: URL) throws -> (directory: Bool, size: Int, modified: Date?) {
		guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
			.fileSizeKey, .contentModificationDateKey]), values.isSymbolicLink != true,
			values.isDirectory == true || values.isRegularFile == true else { throw Abort(.notFound) }
		return (values.isDirectory == true, values.fileSize ?? 0, values.contentModificationDate)
	}

	private static func member(_ names: [String], values: (directory: Bool, size: Int, modified: Date?)) -> String {
		let encoded = names.compactMap { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) }
		let path = "/files/" + encoded.joined(separator: "/") + (values.directory && !encoded.isEmpty ? "/" : "")
		let type = values.directory ? "<D:collection/>" : ""
		let size = values.directory ? "" : "<D:getcontentlength>\(values.size)</D:getcontentlength>"
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = TimeZone(secondsFromGMT: 0)
		formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
		let modified = values.modified.map { "<D:getlastmodified>\(formatter.string(from: $0))</D:getlastmodified>" } ?? ""
		return "<D:response><D:href>\(path)</D:href><D:propstat><D:prop><D:resourcetype>\(type)</D:resourcetype>\(size)\(modified)</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
	}
}
