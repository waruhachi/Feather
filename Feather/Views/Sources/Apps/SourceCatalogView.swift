import AltSourceKit
import NimbleViews
import SwiftUI

struct SourceListing: Identifiable {
	let url: URL
	let source: ASRepository
	let app: ASRepository.App

	var id: String { url.absoluteString + "|" + app.currentUniqueId }
	var sourceName: String { source.name ?? url.host ?? url.absoluteString }
}

struct SourceCatalogEntry: Identifiable {
	let id: String
	let listings: [SourceListing]
	var title: String { listings[0].app.currentName }

	static func entries(in sources: [AltSource], repositories: [AltSource: ASRepository], matching query: String) -> [Self] {
		let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
		var groups: [String: [SourceListing]] = [:]
		for entry in sources {
			guard let repository = repositories[entry], let url = entry.sourceURL else { continue }
			for app in repository.apps {
				let listing = SourceListing(url: url, source: repository, app: app)
				let identifier = app.id.flatMap { $0.isEmpty ? nil : $0.lowercased() }
				let key = identifier.map { "bundle:" + $0 } ?? "listing:" + listing.id
				if groups[key]?.contains(where: { $0.id == listing.id }) != true {
					groups[key, default: []].append(listing)
				}
			}
		}
		return groups.compactMap { id, listings in
			guard term.isEmpty || listings.contains(where: {
				[$0.app.currentName, $0.app.id, $0.app.developer, $0.sourceName]
					.compactMap { $0 }.contains { $0.localizedStandardContains(term) }
			}) else { return nil }
			return Self(id: id, listings: listings)
		}.sorted { first, second in
			let order = first.title.localizedStandardCompare(second.title)
			return order == .orderedSame ? first.id < second.id : order == .orderedAscending
		}
	}
}

struct SourceCatalogRows: View {
	let entries: [SourceCatalogEntry]

	var body: some View {
		ForEach(entries) { entry in
			NavigationLink {
				SourceCatalogDetailView(listings: entry.listings)
			} label: {
				VStack(alignment: .leading, spacing: 3) {
					Text(entry.title)
					let detail: String = entry.listings.count == 1
						? entry.listings[0].sourceName
						: .localized("%lld Sources", arguments: entry.listings.count)
					Text(detail).font(.caption).foregroundStyle(.secondary)
				}
			}
		}
	}
}

struct SourceCatalogView: View {
	let sources: [AltSource]
	@ObservedObject var model: SourcesViewModel
	@State private var query = ""

	var body: some View {
		let entries = SourceCatalogEntry.entries(in: sources, repositories: model.sources, matching: query)
		List {
			SourceCatalogRows(entries: entries)
			if entries.isEmpty {
				if !model.isFinished {
					ProgressView()
				} else {
					Text(.localized("No Apps")).foregroundStyle(.secondary)
				}
			}
		}
		.navigationTitle(.localized("All Repositories"))
		.searchable(text: $query, placement: .platform(), prompt: Text(.localized("Search Apps")))
	}
}

private struct SourceCatalogDetailView: View {
	let listings: [SourceListing]
	@State private var selected = 0

	var body: some View {
		let listing = listings[selected]
		SourceAppsDetailView(sourceURL: listing.url, source: listing.source, app: listing.app)
			.id(listing.id)
			.toolbar {
				if listings.count > 1 {
					ToolbarItem(placement: .topBarTrailing) {
						Menu {
							Picker(.localized("Source"), selection: $selected) {
								ForEach(listings.indices, id: \.self) { index in
									let item = listings[index]
									Text(item.sourceName + (item.app.currentVersion.map { " · " + $0 } ?? "")).tag(index)
								}
							}
						} label: {
							Label(.localized("Source"), systemImage: "globe")
						}
					}
				}
			}
	}
}
