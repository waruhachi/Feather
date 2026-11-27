import SwiftUI

private struct CatalogTweak: Decodable, Identifiable {
	let id: String
	let name: String
	let description: String
	let targets: [String]
	let version: String
	let debURL: URL
	let requires: [URL]?
	let projectURL: URL?
}

private struct TweakCatalog: Decodable {
	let version: Int
	let tweaks: [CatalogTweak]

	static func load() async throws -> [CatalogTweak] {
		let endpoint = URL(string: "https://raw.githubusercontent.com/AccretionMods/mods/main/tweaks.json")!
		let (data, response) = try await URLSession.shared.data(from: endpoint)
		try verify(response)
		let catalog = try JSONDecoder().decode(Self.self, from: data)
		guard catalog.version == 1 else { throw CocoaError(.fileReadUnknown) }
		return catalog.tweaks.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
	}

	@MainActor
	static func save(_ tweak: CatalogTweak) async throws -> [URL] {
		let manager = FileManager.default
		let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try manager.createDirectory(at: directory, withIntermediateDirectories: false)
		defer { try? manager.removeItem(at: directory) }

		var pending: [(file: URL, origin: URL)] = []
		var result: [URL] = []
		var seen = Set<URL>()
		for url in [tweak.debURL] + (tweak.requires ?? []) where seen.insert(url).inserted {
			guard isHTTPS(url), ["deb", "dylib"].contains(url.pathExtension.lowercased()) else {
				throw URLError(.unsupportedURL)
			}
			if let existing = TweakLibrary.files().first(where: { TweakLibrary.metadata(for: $0).catalogURL == url }) {
				result.append(existing)
				continue
			}

			let (file, response) = try await URLSession.shared.download(from: url)
			defer { try? manager.removeItem(at: file) }
			try verify(response)
			let staging = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
			try manager.createDirectory(at: staging, withIntermediateDirectories: false)
			let named = staging.appendingPathComponent(url.lastPathComponent)
			try manager.moveItem(at: file, to: named)
			pending.append((named, url))
		}

		try Task.checkCancellation()
		var added: [URL] = []
		do {
			for (file, url) in pending {
				var metadata = TweakLibrary.Metadata(folder: .localized("Tweak Catalog"), notes: tweak.name)
				metadata.catalogURL = url
				added.append(try TweakLibrary.add(file, metadata: metadata))
			}
		} catch {
			for file in added { try? TweakLibrary.remove(file) }
			throw error
		}
		return result + added
	}

	private static func verify(_ response: URLResponse) throws {
		guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
			let url = http.url, isHTTPS(url)
		else { throw URLError(.badServerResponse) }
	}

	private static func isHTTPS(_ url: URL) -> Bool {
		url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil
	}
}

struct TweakCatalogView: View {
	var bundleIdentifier: String? = nil
	var onSelect: (([URL]) -> Void)? = nil
	@State private var entries: [CatalogTweak] = []
	@State private var loading = true
	@State private var downloading: String?
	@State private var report: String?
	@State private var loadError: String?

	var body: some View {
		List {
			if loading {
				ProgressView()
			} else if let loadError {
				Text(loadError)
				Button(.localized("Retry")) { Task { await load() } }
			} else if entries.isEmpty {
				Text(.localized("No catalog tweaks match this app."))
			}
			ForEach(entries) { tweak in
				VStack(alignment: .leading, spacing: 8) {
					Text(tweak.name).font(.headline)
					Text(tweak.description).font(.subheadline).foregroundStyle(.secondary)
					Text(tweak.version).font(.caption)
					if let url = tweak.projectURL, url.scheme == "https" {
						Link(.localized("Project"), destination: url)
					}
					Button(.localized(onSelect == nil ? "Save to Tweak Manager" : "Download and Add")) {
						Task { await download(tweak) }
					}
					.disabled(downloading != nil)
					if downloading == tweak.id { ProgressView() }
				}
			}
		}
		.navigationTitle(.localized(bundleIdentifier == nil ? "Tweak Catalog" : "Suggested Tweaks"))
		.task { await load() }
		.alert(.localized("Tweak Catalog"), isPresented: Binding(
			get: { report != nil },
			set: { if !$0 { report = nil } }
		)) { Button(.localized("OK"), role: .cancel) {} } message: {
			Text(report ?? "")
		}
	}

	private func load() async {
		loading = true
		defer { loading = false }
		do {
			let tweaks = try await TweakCatalog.load()
			entries = bundleIdentifier.map { bundleID in tweaks.filter { $0.targets.contains(bundleID) } } ?? tweaks
			loadError = nil
		} catch {
			loadError = error.localizedDescription
		}
	}

	private func download(_ tweak: CatalogTweak) async {
		guard downloading == nil else { return }
		downloading = tweak.id
		defer { downloading = nil }
		do {
			let files = try await TweakCatalog.save(tweak)
			if let onSelect { onSelect(files) }
			else { report = .localized("Saved to Tweak Manager") }
		} catch {
			report = error.localizedDescription
		}
	}
}
