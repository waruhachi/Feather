//
//  SourcesView.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//

import CoreData
import AltSourceKit
import SwiftUI
import NimbleViews

// MARK: - View
struct SourcesView: View {
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	#if !NIGHTLY && !DEBUG
		@AppStorage("Feather.shouldStar") private var _shouldStar: Int = 0
	#endif
	@StateObject var viewModel = SourcesViewModel.shared
	@State private var _isAddingPresenting = false
	@State private var _addingSourceLoading = false
	@State private var _searchText = ""
	#if !targetEnvironment(macCatalyst)
	@State private var automaticSourceChanges = 0
	#endif
	@AppStorage("Feather.favoriteSources") private var _favoriteSourceData = Data()
	
	private var _filteredSources: [AltSource] {
		_sources.filter { _searchText.isEmpty || ($0.name?.localizedCaseInsensitiveContains(_searchText) ?? false) }
	}
	
	private var _favorites: Set<String> {
		(try? JSONDecoder().decode(Set<String>.self, from: _favoriteSourceData)) ?? []
	}

	private func _sourceRow(_ source: AltSource) -> some View {
		let identifier = source.identifier ?? ""
		let favorite = _favorites.contains(identifier)
		return NavigationLink {
			SourceAppsView(object: [source], viewModel: viewModel)
		} label: {
			SourcesCellView(source: source)
		}
		.buttonStyle(.plain)
		.contextMenu {
			#if !targetEnvironment(macCatalyst)
			if let url = source.sourceURL {
				let enabled = PairedLibraryUpdates.enabled(forSource: url)
				Button(.localized(enabled ? "Disable Automatic Installation" : "Enable Automatic Installation"), systemImage: "arrow.down.app") {
					PairedLibraryUpdates.setEnabled(!enabled, forSource: url)
					automaticSourceChanges += 1
				}
				.id(automaticSourceChanges)
			}
			#endif
			Button(.localized(favorite ? "Remove from Favorites" : "Add to Favorites"), systemImage: favorite ? "star.slash" : "star") {
				guard !identifier.isEmpty else { return }
				var updated = _favorites
				if favorite { updated.remove(identifier) } else { updated.insert(identifier) }
				_favoriteSourceData = (try? JSONEncoder().encode(updated)) ?? Data()
			}
		}
	}

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>
	
	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Sources")) {
			NBListAdaptable {
				let query = _searchText.trimmingCharacters(in: .whitespacesAndNewlines)
				if !query.isEmpty {
					let entries = SourceCatalogEntry.entries(in: Array(_sources), repositories: viewModel.sources, matching: query)
					NBSection(.localized("Apps")) {
						if entries.isEmpty {
							if !viewModel.isFinished {
								ProgressView()
							} else {
								Text(.localized("No Apps")).foregroundStyle(.secondary)
							}
						}
						SourceCatalogRows(entries: entries)
					}
				}
				if !_filteredSources.isEmpty {
					Section {
						NavigationLink {
							SourceCatalogView(sources: Array(_sources), model: viewModel)
						} label: {
							let isRegular = horizontalSizeClass != .compact
							HStack(spacing: 18) {
								Image("Repositories").appIconStyle()
								NBTitleWithSubtitleView(
									title: .localized("All Repositories"),
									subtitle: .localized("See all apps from your sources")
								)
							}
							.padding(isRegular ? 12 : 0)
							.background(
								isRegular
									? RoundedRectangle(cornerRadius: 18, style: .continuous)
									.fill(Color(.quaternarySystemFill))
									: nil
							)
						}
						.buttonStyle(.plain)
					}
					
					let favorites = _filteredSources.filter { _favorites.contains($0.identifier ?? "") }
					let otherSources = _filteredSources.filter { !_favorites.contains($0.identifier ?? "") }
					if !favorites.isEmpty {
						NBSection(.localized("Favorites"), secondary: favorites.count.description) {
							ForEach(favorites, content: _sourceRow)
						}
					}
					if !otherSources.isEmpty {
						NBSection(.localized("Repositories"), secondary: otherSources.count.description) {
							ForEach(otherSources, content: _sourceRow)
						}
					}
				}
			}
			.searchable(text: $_searchText, placement: .platform())
			.overlay {
				if _sources.isEmpty && _searchText.isEmpty {
					if #available(iOS 17, *) {
						ContentUnavailableView {
							Label(.localized("No Repositories"), systemImage: "globe.desk.fill")
						} description: {
							Text(.localized("Get started by adding your first repository."))
						} actions: {
							Button {
								_isAddingPresenting = true
							} label: {
								NBButton(.localized("Add Source"), style: .text)
							}
						}
					}
				}
			}
			.toolbar {
				NBToolbarButton(
					systemImage: "plus",
					style: .icon,
					placement: .topBarTrailing,
					isDisabled: _addingSourceLoading
				) {
					_isAddingPresenting = true
				}
			}
			.refreshable {
				await viewModel.fetchSources(_sources, refresh: true)
			}
			.sheet(isPresented: $_isAddingPresenting) {
				SourcesAddView()
			}
		}
		.task(id: Array(_sources)) {
			await viewModel.fetchSources(_sources)
		}
		#if !NIGHTLY && !DEBUG
		.onAppear {
				guard _shouldStar < 6 else { return }; _shouldStar += 1
				guard _shouldStar == 6 else { return }
			
				let github = UIAlertAction(title: "GitHub", style: .default) { _ in
					UIApplication.open("https://github.com/khcrysalis/Feather")
				}
			
				let cancel = UIAlertAction(title: .localized("Dismiss"), style: .cancel)
			
				UIAlertController.showAlert(
					title: .localized("Enjoying %@?", arguments: Bundle.main.name),
					message: .localized("Go to our GitHub and give us a star!"),
					actions: [github, cancel]
				)
			}
		#endif
	}
}
