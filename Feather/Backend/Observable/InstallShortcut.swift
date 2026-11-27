import UIKit

@MainActor
enum InstallShortcut {
	static let preferenceKey = "Feather.installShortcutName"
	static let callbackHost = "install-shortcut"

	private struct Request {
		let id = UUID().uuidString
		let app: String
		let name: String
		let created = Date()
	}

	private static var pending: Request?
	private static var installing: Request?

	static func start(for app: String) {
		let name = UserDefaults.standard.string(forKey: preferenceKey)?
			.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		guard !name.isEmpty else {
			presentInstall(app)
			return
		}

		let request = Request(app: app, name: name)
		pending = request
		Task {
			// Let the signing sheet dismiss before switching to Shortcuts.
			try? await Task.sleep(for: .milliseconds(350))
			guard pending?.id == request.id else { return }
			let callback = "feather://\(callbackHost)/\(request.id)"
			guard let url = shortcutURL(name: name, input: "Installation", callback: callback),
				await UIApplication.shared.open(url) else {
				if pending?.id == request.id { handleResult(request, outcome: "error") }
				return
			}
		}
	}

	static func handle(_ url: URL) {
		let parts = url.pathComponents.filter { $0 != "/" }
		guard parts.count == 2, let request = pending, parts[0] == request.id,
			Date().timeIntervalSince(request.created) < 15 * 60
		else { return }
		handleResult(request, outcome: parts[1])
	}

	static func finish(for app: String?, verified: Bool) {
		guard let request = installing, request.app == app else { return }
		installing = nil
		if verified, let url = shortcutURL(name: request.name, input: "Installed") {
			UIApplication.shared.open(url)
		}
	}

	private static func handleResult(_ request: Request, outcome: String) {
		switch outcome {
		case "success":
			pending = nil
			installing = request
			presentInstall(request.app)
		case "cancel":
			pending = nil
		case "error":
			pending = nil
			UIAlertController.showAlertWithCancel(
				title: .localized("Install Shortcut Failed"),
				message: .localized("You can still install the signed app from Library."),
				actions: [UIAlertAction(title: .localized("Continue to Install"), style: .default) { _ in
					presentInstall(request.app)
				}]
			)
		default:
			break
		}
	}

	private static func presentInstall(_ app: String) {
		NotificationCenter.default.post(name: .featherInstallApp, object: app)
	}

	private static func shortcutURL(name: String, input: String, callback: String? = nil) -> URL? {
		var parts = URLComponents()
		parts.scheme = "shortcuts"
		parts.host = callback == nil ? "run-shortcut" : "x-callback-url"
		parts.path = callback == nil ? "" : "/run-shortcut"
		var parameters = [
			URLQueryItem(name: "name", value: name),
			URLQueryItem(name: "input", value: "text"),
			URLQueryItem(name: "text", value: input),
		]
		if let callback {
			for outcome in ["success", "error", "cancel"] {
				parameters.append(URLQueryItem(name: "x-" + outcome, value: callback + "/" + outcome))
			}
		}
		parts.queryItems = parameters
		return parts.url
	}
}
