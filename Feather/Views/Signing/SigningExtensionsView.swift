//
//  SigningExtensionsView.swift
//  Feather
//
//  Created by GitHub Copilot on 17.04.2026.
//

import NimbleViews
import SwiftUI

// MARK: - View
struct SigningExtensionsView: View {
	@State private var _isAddingPresenting = false
	@State private var _bundledExtensions: [AppExtensionMetadata] = []

	var app: AppInfoPresentable
	@Binding var options: Options

	// MARK: Body
	var body: some View {
		NBList(.localized("Extensions")) {
			NBSection(.localized("Bundled Extensions")) {
				if _bundledExtensions.isEmpty {
					Text(.localized("No bundled app extensions found."))
						.font(.footnote)
						.foregroundColor(.disabled())
				} else {
					ForEach(_bundledExtensions) { item in
						_bundledRow(item)
					}
				}
			}

			NBSection(.localized("Queued for Injection")) {
				if options.injectedAppExtensions.isEmpty {
					Text(.localized("No extensions chosen."))
						.font(.footnote)
						.foregroundColor(.disabled())
				} else {
					ForEach(options.injectedAppExtensions, id: \.absoluteString)
					{ appex in
						_queuedRow(for: appex)
					}
				}
			}
		}
		.toolbar {
			NBToolbarButton(
				systemImage: "plus",
				style: .icon,
				placement: .topBarTrailing
			) {
				_isAddingPresenting = true
			}
		}
		.sheet(isPresented: $_isAddingPresenting) {
			FileImporterRepresentableView(
				allowedContentTypes: [.appex, .folder],
				allowsMultipleSelection: true,
				onDocumentsPicked: { urls in
					guard !urls.isEmpty else { return }

					for url in urls {
						guard url.pathExtension.lowercased() == "appex" else { continue }
						FileManager.default.moveAndStore(
							url,
							with: "FeatherAppExtension"
						) { storedURL in
							options.injectedAppExtensions.append(storedURL)
						}
					}
				}
			)
			.ignoresSafeArea()
		}
		.onAppear(perform: _listBundledExtensions)
		.animation(.smooth, value: options.injectedAppExtensions)
	}
}

// MARK: - Extension: View
extension SigningExtensionsView {
	@ViewBuilder
	private func _bundledRow(_ item: AppExtensionMetadata) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(item.displayName)
				.lineLimit(2)
			if let identifier = item.bundleIdentifier {
				Text(identifier)
					.font(.caption)
					.foregroundColor(.secondary)
			}
			Text(item.locationName)
				.font(.caption2)
				.foregroundColor(.secondary)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	@ViewBuilder
	private func _queuedRow(for appex: URL) -> some View {
		let metadata = AppExtensionMetadata(
			url: appex,
			locationName: .localized("Queued")
		)

		VStack(alignment: .leading, spacing: 4) {
			Text(metadata.displayName)
				.lineLimit(2)
			if let identifier = metadata.bundleIdentifier {
				Text(identifier)
					.font(.caption)
					.foregroundColor(.secondary)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.swipeActions(edge: .trailing, allowsFullSwipe: true) {
			Button(role: .destructive) {
				FileManager.default.deleteStored(appex) { url in
					if let index = options.injectedAppExtensions.firstIndex(
						of: url
					) {
						options.injectedAppExtensions.remove(at: index)
					}
				}
			} label: {
				Label(.localized("Delete"), systemImage: "trash")
			}
		}
		.contextMenu {
			Button(role: .destructive) {
				FileManager.default.deleteStored(appex) { url in
					if let index = options.injectedAppExtensions.firstIndex(
						of: url
					) {
						options.injectedAppExtensions.remove(at: index)
					}
				}
			} label: {
				Label(.localized("Delete"), systemImage: "trash")
			}
		}
	}

	private func _listBundledExtensions() {
		guard let appURL = Storage.shared.getAppDirectory(for: app) else {
			_bundledExtensions = []
			return
		}

		let pluginExtensions = _listFiles(
			at: appURL.appendingPathComponent("PlugIns"),
			locationName: "PlugIns"
		)
		let legacyExtensions = _listFiles(
			at: appURL.appendingPathComponent("Extensions"),
			locationName: "Extensions"
		)
		_bundledExtensions = pluginExtensions + legacyExtensions
	}

	private func _listFiles(at path: URL, locationName: String)
		-> [AppExtensionMetadata]
	{
		guard
			let contents = try? FileManager.default.contentsOfDirectory(
				at: path,
				includingPropertiesForKeys: nil
			)
		else {
			return []
		}

		return
			contents
			.filter { $0.pathExtension == "appex" }
			.map { AppExtensionMetadata(url: $0, locationName: locationName) }
			.sorted { lhs, rhs in
				lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
					== .orderedAscending
			}
	}
}

// MARK: - Models
private struct AppExtensionMetadata: Identifiable {
	let id: String
	let url: URL
	let locationName: String
	let bundleIdentifier: String?
	let displayName: String

	init(url: URL, locationName: String) {
		self.id = url.path
		self.url = url
		self.locationName = locationName

		let infoPlistURL = url.appendingPathComponent("Info.plist")
		let infoDictionary = NSDictionary(contentsOf: infoPlistURL)
		self.bundleIdentifier = infoDictionary?["CFBundleIdentifier"] as? String
		self.displayName =
			(infoDictionary?["CFBundleDisplayName"] as? String)
			?? (infoDictionary?["CFBundleName"] as? String)
			?? url.deletingPathExtension().lastPathComponent
	}
}
