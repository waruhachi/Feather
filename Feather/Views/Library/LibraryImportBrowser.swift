import SwiftUI
import WebKit

struct LibraryImportBrowser: View {
	@Environment(\.dismiss) private var dismiss
	@State private var address = ""
	@State private var page: URL?
	@State private var pendingImport: URL?
	let onImport: (String) -> Void

	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				TextField(.localized("Website URL"), text: $address)
					.keyboardType(.URL)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
					.submitLabel(.go)
					.onSubmit(openAddress)
					.padding()
				BrowserPage(address: page) { pendingImport = $0 }
			}
			.navigationTitle(.localized("Import Browser"))
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button(.localized("Done")) { dismiss() }
				}
			}
			.confirmationDialog(.localized("Import this IPA?"), isPresented: Binding(
				get: { pendingImport != nil },
				set: { if !$0 { pendingImport = nil } }
			), presenting: pendingImport) { url in
				Button(.localized("Import IPA")) {
					onImport(url.absoluteString)
					dismiss()
				}
			} message: { url in
				Text(url.host ?? url.scheme ?? "")
			}
		}
	}

	private func openAddress() {
		let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !input.isEmpty,
			let url = URL(string: input.contains("://") ? input : "https://" + input)
		else { return }
		if BrowserPage.isPackage(url) {
			pendingImport = url
		} else if BrowserPage.isWebURL(url) {
			page = url
		}
	}
}

private struct BrowserPage: UIViewRepresentable {
	let address: URL?
	let onPackage: (URL) -> Void

	func makeCoordinator() -> Coordinator { Coordinator(onPackage: onPackage) }

	func makeUIView(context: Context) -> WKWebView {
		let configuration = WKWebViewConfiguration()
		configuration.websiteDataStore = .nonPersistent()
		let view = WKWebView(frame: .zero, configuration: configuration)
		view.navigationDelegate = context.coordinator
		return view
	}

	func updateUIView(_ view: WKWebView, context: Context) {
		context.coordinator.onPackage = onPackage
		guard let address, address != context.coordinator.requested else { return }
		context.coordinator.requested = address
		view.load(URLRequest(url: address))
	}

	static func isWebURL(_ url: URL) -> Bool {
		["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
	}

	static func isPackage(_ url: URL) -> Bool {
		url.scheme?.lowercased() == "itms-services"
			|| (isWebURL(url) && ["ipa", "tipa"].contains(url.pathExtension.lowercased()))
	}

	final class Coordinator: NSObject, WKNavigationDelegate {
		var requested: URL?
		var onPackage: (URL) -> Void

		init(onPackage: @escaping (URL) -> Void) { self.onPackage = onPackage }

		func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
			guard let url = action.request.url else { return .cancel }
			if BrowserPage.isPackage(url) {
				if action.targetFrame?.isMainFrame != false { onPackage(url) }
				return .cancel
			}
			guard BrowserPage.isWebURL(url) else { return .cancel }
			if action.targetFrame == nil {
				webView.load(action.request)
				return .cancel
			}
			return .allow
		}
	}
}
