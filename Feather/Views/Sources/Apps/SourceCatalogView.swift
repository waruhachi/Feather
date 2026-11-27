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

	static func entries(in sources: [AltSource], repositories: [AltSource: ASRepository], matching query: String, inSourceOrder: Bool = false) -> [Self] {
		let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
		var groups: [String: [SourceListing]] = [:]
		var order: [String] = []
		for entry in sources {
			guard let repository = repositories[entry], let url = entry.sourceURL else { continue }
			for app in repository.apps {
				let listing = SourceListing(url: url, source: repository, app: app)
				let identifier = app.id.flatMap { $0.isEmpty ? nil : $0.lowercased() }
				let key = identifier.map { "bundle:" + $0 } ?? "listing:" + listing.id
				if groups[key] == nil { order.append(key) }
				if groups[key]?.contains(where: { $0.id == listing.id }) != true {
					groups[key, default: []].append(listing)
				}
			}
		}
		let matches: [Self] = order.compactMap { id in
			guard let listings = groups[id] else { return nil }
			guard term.isEmpty || listings.contains(where: {
				[$0.app.currentName, $0.app.id, $0.app.developer, $0.app.currentDescription, $0.sourceName]
					.compactMap { $0 }.contains { $0.localizedStandardContains(term) }
			}) else { return nil }
			return Self(id: id, listings: listings)
		}
		if inSourceOrder { return matches }
		return matches.sorted { first, second in
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
				let first = entry.listings[0]
				let detail: String = entry.listings.count == 1
					? first.sourceName
					: .localized("%lld Sources", arguments: entry.listings.count)
				FRIconCellView(title: entry.title, subtitle: detail, iconUrl: first.app.iconURL)
			}
		}
	}
}

struct SourceCatalogView: View {
	let sources: [AltSource]
	@ObservedObject var model: SourcesViewModel
	@State private var query = ""
	@AppStorage("Feather.sortOptionRawValue") private var sort = SourceAppsView.SortOption.default
	@AppStorage("Feather.sortAscending") private var ascending = true

	var body: some View {
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
		.toolbar {
			ToolbarItem(placement: .topBarTrailing) {
				Menu {
					Picker(.localized("Sort By"), selection: $sort) {
						ForEach(SourceAppsView.SortOption.allCases, id: \.self) { option in
							Text(option.displayName).tag(option)
						}
					}
					Toggle(.localized("Ascending"), isOn: $ascending)
					Button(.localized("Copy Sources"), systemImage: "doc.on.doc") {
						UIPasteboard.general.string = sources.compactMap { $0.sourceURL?.absoluteString }.joined(separator: "\n")
					}
				} label: {
					Label(.localized("Sort and Share"), systemImage: "ellipsis.circle")
				}
			}
		}
	}

	private var entries: [SourceCatalogEntry] {
		var entries = SourceCatalogEntry.entries(in: sources, repositories: model.sources, matching: query, inSourceOrder: sort == .default)
		if sort == .date {
			entries.sort { first, second in
				let firstDate = first.listings.compactMap { $0.app.currentDate?.date }.max() ?? .distantPast
				let secondDate = second.listings.compactMap { $0.app.currentDate?.date }.max() ?? .distantPast
				return firstDate < secondDate
			}
		}
		return ascending ? entries : Array(entries.reversed())
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
