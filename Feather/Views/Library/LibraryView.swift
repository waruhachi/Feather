//
//  ContentView.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//

import CoreData
import NimbleViews
import SwiftUI

// MARK: - View
struct LibraryView: View {
	private let downloadManager = DownloadManager.shared
	@StateObject var updateManager = UpdateManager.shared
	@ObservedObject private var alerts = FeatherAlerts.shared

	@State private var _selectedInfoAppPresenting: AnyApp?
	@State private var _selectedSigningAppPresenting: AnyApp?
	@State private var _selectedInstallAppPresenting: AnyApp?
	@State private var _pendingInstallApp: AnyApp?
	@State private var _isImportingPresenting = false
	@Environment(\.scenePhase) private var scenePhase
	@AppStorage("Feather.openImportOnReopen") private var openImportOnReopen = false
	@State private var wentToBackground = false
	@State private var pendingImportAfterInstall = false
	@State private var _isDownloadingPresenting = false
	@State private var _linkImportError: String?
	@State private var _alertDownloadString: String = ""  // for _isDownloadingPresenting
	@State private var _updateCheckRotation = 0.0
	@State private var _isUpdateCheckCompleteVisible = false
	@State private var _work: LibraryWork?
	@State private var _isInstallationSettingsPresented = false
	@AppStorage("Feather.openImportOnLaunch") private var _openImportOnLaunch = false
	@AppStorage("Feather.libraryImportAction") private var _importAction = LibraryImportAction.menu
	@State private var _importUpdateCheckTask: Task<Void, Never>?

	// MARK: Selection State
	@State private var _selectedAppUUIDs: Set<String> = []
	@State private var _editMode: EditMode = .inactive

	@State private var _searchText = ""
	@State private var _selectedScope: Scope = .all

	@Namespace private var _namespace

	// horror
	private func filteredAndSortedApps<T>(from apps: FetchedResults<T>) -> [T]
	where T: NSManagedObject {
		apps.filter {
			_searchText.isEmpty
				|| (($0.value(forKey: "name") as? String)?
					.localizedCaseInsensitiveContains(_searchText) ?? false)
		}
	}

	private var _filteredSignedApps: [Signed] {
		filteredAndSortedApps(from: _signedApps)
	}

	private var _filteredImportedApps: [Imported] {
		filteredAndSortedApps(from: _importedApps)
	}

	// MARK: Fetch
	@FetchRequest(
		entity: Signed.entity(),
		sortDescriptors: [
			NSSortDescriptor(keyPath: \Signed.date, ascending: false)
		],
		animation: .snappy
	) private var _signedApps: FetchedResults<Signed>

	@FetchRequest(
		entity: Imported.entity(),
		sortDescriptors: [
			NSSortDescriptor(keyPath: \Imported.date, ascending: false)
		],
		animation: .snappy
	) private var _importedApps: FetchedResults<Imported>

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [
			NSSortDescriptor(keyPath: \AltSource.name, ascending: true)
		],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>

	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Library")) {
			NBListAdaptable {
				if !_editMode.isEditing, _searchText.isEmpty, _selectedScope == .all {
					let apps = _updatableApps
					if !apps.isEmpty {
						NBSection(.localized("Updates Available"), secondary: apps.count.description) {
							let downloadable = apps.filter { updateManager.update(for: $0)?.canDownload == true }
							if !downloadable.isEmpty {
								Button(.localized("Update All"), systemImage: "arrow.down.circle") {
									_presentWork(.updates, apps: downloadable)
								}
							}
							ForEach(apps.map { AnyApp(base: $0) }) { item in
								if let update = updateManager.update(for: item.base) {
									Button {
										if update.canDownload {
											_presentWork(.updates, apps: [item.base])
										} else if let url = update.webURL {
											UIApplication.open(url)
										}
									} label: {
										LabeledContent(update.appName, value: update.remoteVersion)
									}
									.contextMenu {
										Button(.localized("Skip This Version"), systemImage: "forward.end") {
											updateManager.skipUpdate(for: item.base)
										}
										Button(.localized("Hold Updates"), systemImage: "bell.slash") {
											updateManager.setUpdatesDisabled(for: item.base, disabled: true)
										}
									}
								}
							}
						}
					}
				}
				if !_filteredSignedApps.isEmpty,
					_selectedScope == .all || _selectedScope == .signed
				{
					NBSection(
						.localized("Signed"),
						secondary: _filteredSignedApps.count.description
					) {
						ForEach(_filteredSignedApps, id: \.uuid) { app in
							LibraryCellView(
								app: app,
								sources: Array(_sources),
								selectedInfoAppPresenting:
									$_selectedInfoAppPresenting,
								selectedSigningAppPresenting:
									$_selectedSigningAppPresenting,
								selectedInstallAppPresenting:
									$_selectedInstallAppPresenting,
								selectedAppUUIDs: $_selectedAppUUIDs,
								onChooseUpdate: { _presentWork(.updates, apps: [app]) }
							)
							.compatMatchedTransitionSource(
								id: app.uuid ?? "",
								ns: _namespace
							)
						}
					}
				}

				if !_filteredImportedApps.isEmpty,
					_selectedScope == .all || _selectedScope == .imported
				{
					NBSection(
						.localized("Imported"),
						secondary: _filteredImportedApps.count.description
					) {
						ForEach(_filteredImportedApps, id: \.uuid) { app in
							LibraryCellView(
								app: app,
								sources: Array(_sources),
								selectedInfoAppPresenting:
									$_selectedInfoAppPresenting,
								selectedSigningAppPresenting:
									$_selectedSigningAppPresenting,
								selectedInstallAppPresenting:
									$_selectedInstallAppPresenting,
								selectedAppUUIDs: $_selectedAppUUIDs,
								onChooseUpdate: { _presentWork(.updates, apps: [app]) }
							)
							.compatMatchedTransitionSource(
								id: app.uuid ?? "",
								ns: _namespace
							)
						}
					}
				}
			}
			.searchable(text: $_searchText, placement: .platform())
			.compatSearchScopes($_selectedScope) {
				ForEach(Scope.allCases, id: \.displayName) { scope in
					Text(scope.displayName).tag(scope)
				}
			}
			.scrollDismissesKeyboard(.interactively)
			.overlay {
				if _filteredSignedApps.isEmpty,
					_filteredImportedApps.isEmpty
				{
					if #available(iOS 17, *) {
						ContentUnavailableView {
							Label(
								.localized("No Apps"),
								systemImage: "questionmark.app.fill"
							)
						} description: {
							Text(
								.localized(
									"Get started by importing your first IPA file."
								)
							)
						} actions: {
							Menu {
								_importActions()
							} label: {
								NBButton(.localized("Import"), style: .text)
							}
						}
					}
				}
			}
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					EditButton()
				}

				if _editMode.isEditing {
					NBToolbarButton(
						.localized("Delete"),
						systemImage: "trash",
						isDisabled: _selectedAppUUIDs.isEmpty
					) {
						_bulkDeleteSelectedApps()
					}
					ToolbarItem(placement: .topBarTrailing) {
						Menu {
							Button(.localized("Batch Sign"), systemImage: "signature") {
								_presentWork(.signing, apps: _selection)
							}
							if _selection.contains(where: \.isSigned) {
								Button(.localized("Install Queue"), systemImage: "square.and.arrow.down") {
									_presentWork(.installation, apps: _selection.filter(\.isSigned))
								}
							}
						} label: {
							Image(systemName: "ellipsis.circle")
						}
						.disabled(_selectedAppUUIDs.isEmpty)
					}
				} else {
					ToolbarItem(placement: .topBarTrailing) {
						Button {
							Task {
								await _checkForUpdates()
							}
						} label: {
							Image(
								systemName: _isUpdateCheckCompleteVisible
									? "checkmark.circle.fill"
									: "arrow.triangle.2.circlepath"
							)
							.rotationEffect(.degrees(_updateCheckRotation))
							.animation(
								updateManager.isChecking
									? .linear(duration: 0.8).repeatForever(
										autoreverses: false
									)
									: .default,
								value: _updateCheckRotation
							)
						}
						.disabled(updateManager.isChecking)
						.accessibilityLabel(.localized("Check for Updates"))
					}

					let downloadable = _updatableApps.filter { updateManager.update(for: $0)?.canDownload == true }
					if !downloadable.isEmpty {
						ToolbarItem(placement: .topBarTrailing) {
							Button {
								_presentWork(.updates, apps: downloadable)
							} label: {
								Image(systemName: "arrow.down.circle")
							}
							.accessibilityLabel(.localized("Update All"))
						}
					}

					ToolbarItem(placement: .topBarTrailing) {
						_importToolbar()
					}
				}
			}
			.environment(\.editMode, $_editMode)
			.sheet(item: $_work, onDismiss: _openPendingImport) { LibraryWorkView(work: $0) }
			.onReceive(alerts.$route) { route in
				if case .signing(let uuid)? = route {
					Task { @MainActor in
						if let app = _getAllApps().first(where: { $0.uuid == uuid }) {
							_selectedSigningAppPresenting = AnyApp(base: app)
						}
						alerts.clear(.signing(uuid))
					}
					return
				}
				guard case .library(let uuid)? = route else { return }
				Task { @MainActor in
					if let app = _getAllApps().first(where: { $0.uuid == uuid }),
						let update = updateManager.update(for: app)
					{
						if update.canDownload {
							_presentWork(.updates, apps: [app])
						} else if let url = update.webURL {
							UIApplication.open(url)
						}
					}
					alerts.clear(.library(uuid))
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: .featherImportAfterInstall)) { _ in
				pendingImportAfterInstall = true
			}
			.onChange(of: scenePhase) { phase in
				if phase == .background { wentToBackground = true }
				guard phase == .active, wentToBackground else { return }
				wentToBackground = false
				if openImportOnReopen && _selectedInstallAppPresenting == nil && _work == nil && _selectedSigningAppPresenting == nil {
					_isImportingPresenting = true
				}
			}
			.sheet(isPresented: $_isInstallationSettingsPresented) {
				NBNavigationView(.localized("Installation"), displayMode: .inline) { InstallationView() }
			}
			.onAppear {
				if _openImportOnLaunch && !LibraryLaunchState.didOpenPicker {
					LibraryLaunchState.didOpenPicker = true
					_isImportingPresenting = true
				}
			}
			.sheet(item: $_selectedInfoAppPresenting) { app in
				LibraryInfoView(app: app.base)
			}
			.sheet(item: $_selectedInstallAppPresenting, onDismiss: _openPendingImport) { app in
				InstallPreviewView(app: app.base, isSharing: app.archive)
					.presentationDetents([.height(200)])
					.presentationDragIndicator(.visible)
			}
			.fullScreenCover(item: $_selectedSigningAppPresenting, onDismiss: {
				if let pending = _pendingInstallApp {
					_pendingInstallApp = nil
					_selectedInstallAppPresenting = pending
				}
			}) { app in
				SigningView(app: app.base)
					.compatNavigationTransition(
						id: app.base.uuid ?? "",
						ns: _namespace
					)
			}
			.sheet(isPresented: $_isImportingPresenting) {
				FileImporterRepresentableView(
					allowedContentTypes: [.ipa, .tipa],
					allowsMultipleSelection: true,
					onDocumentsPicked: { urls in
						guard !urls.isEmpty else { return }

						for url in urls {
							let id =
								"FeatherManualDownload_\(UUID().uuidString)"
							let dl = downloadManager.startArchive(
								from: url,
								id: id
							)
							try? downloadManager.handlePachageFile(
								url: url,
								dl: dl
							)
						}
					}
				)
				.ignoresSafeArea()
			}
			.alert(
				.localized("Import from URL"),
				isPresented: $_isDownloadingPresenting
			) {
				TextField(.localized("URL"), text: $_alertDownloadString)
					.textInputAutocapitalization(.never)
				Button(.localized("Cancel"), role: .cancel) {
					_alertDownloadString = ""
				}
				Button(.localized("OK")) {
					let input = _alertDownloadString.trimmingCharacters(
						in: .whitespacesAndNewlines
					)
					_alertDownloadString = ""

					Task { await _importLink(input) }
				}
			}
			.alert(.localized("Import Failed"), isPresented: Binding(
				get: { _linkImportError != nil },
				set: { if !$0 { _linkImportError = nil } }
			)) {
				Button(.localized("OK"), role: .cancel) {}
			} message: {
				Text(_linkImportError ?? "")
			}
			.onReceive(NotificationCenter.default.publisher(for: .featherInstallApp)) { notification in
				guard let uuid = notification.object as? String, let signed = _signedApps.first(where: { $0.uuid == uuid }) else { return }
				_pendingInstallApp = AnyApp(base: signed)
			}

			.onReceive(
				NotificationCenter.default.publisher(
					for: .featherImportedAppDidFinish
				)
			) { _ in
				_scheduleUpdateCheckAfterImport()
			}
			.onChange(of: _editMode) { mode in
				if mode == .inactive {
					_selectedAppUUIDs.removeAll()
				}
			}
			.onChange(of: updateManager.isChecking) { isChecking in
				_handleUpdateCheckStateChange(isChecking)
			}
			.onDisappear {
				_importUpdateCheckTask?.cancel()
				_importUpdateCheckTask = nil
			}
		}
	}
}

// MARK: - Extension: View
extension LibraryView {
	@ViewBuilder
	private func _importToolbar() -> some View {
		if _importAction == .menu {
			Menu {
				_importActions()
				_importPreferences()
			} label: {
				Image(systemName: "plus")
					.accessibilityLabel(.localized("Import"))
			}
		} else {
			Button {
				FeatherHaptics.action()
				if _importAction == .files {
					_isImportingPresenting = true
				} else {
					_isDownloadingPresenting = true
				}
			} label: {
				Image(systemName: "plus")
					.accessibilityLabel(.localized(_importAction.title))
			}
			.contextMenu {
				_importActions()
				_importPreferences()
			}
		}
	}

	@ViewBuilder
	private func _importPreferences() -> some View {
		Menu(.localized("Default Import Action"), systemImage: "pin") {
			Picker(.localized("Default Import Action"), selection: $_importAction) {
				ForEach(LibraryImportAction.allCases, id: \.self) { action in
					Text(.localized(action.title)).tag(action)
				}
			}
		}
		Button(.localized("Installation"), systemImage: "gear") {
			_isInstallationSettingsPresented = true
		}
	}

	@ViewBuilder
	private func _importActions() -> some View {
		Button(.localized("Import from Files"), systemImage: "folder") {
			_isImportingPresenting = true
		}
		Button(.localized("Import from URL"), systemImage: "globe") {
			_isDownloadingPresenting = true
		}
	}
}

// MARK: - Extension: Bulk Delete
extension LibraryView {
	private var _selection: [AppInfoPresentable] {
		_getAllApps().filter { $0.uuid.map(_selectedAppUUIDs.contains) == true }
	}

	private var _updatableApps: [AppInfoPresentable] {
		var signedIDs = Set<String>()
		let signed = _signedApps.filter { app in
			guard let identity = app.identifier ?? app.uuid,
				signedIDs.insert(identity).inserted
			else { return false }
			return updateManager.update(for: app) != nil
		}
		var seenOriginalIDs = Set(signed.compactMap { updateManager.update(for: $0)?.bundleIdentifier })
		let imported = _importedApps.filter { app in
			guard let update = updateManager.update(for: app) else { return false }
			return seenOriginalIDs.insert(update.bundleIdentifier).inserted
		}
		return signed.map { $0 as AppInfoPresentable } + imported.map { $0 as AppInfoPresentable }
	}

	@MainActor
	private func _importLink(_ input: String) async {
		do {
			let url = try await IPALink.resolve(input)
			_ = downloadManager.startDownload(from: url, id: "FeatherManualDownload_" + UUID().uuidString) { outcome in
				if case .failure(let error) = outcome, (error as? URLError)?.code != .cancelled {
					_linkImportError = error.localizedDescription
				}
			}
		} catch {
			_linkImportError = error.localizedDescription
		}
	}

	private func _presentWork(_ purpose: LibraryWork.Purpose, apps: [AppInfoPresentable]) {
		_work = LibraryWork(purpose: purpose, apps: apps, sources: Array(_sources))
	}

	private func _bulkDeleteSelectedApps() {
		let selectedApps = _getAllApps().filter { app in
			guard let uuid = app.uuid else { return false }
			return _selectedAppUUIDs.contains(uuid)
		}

		for app in selectedApps {
			Storage.shared.deleteApp(for: app)
		}

		_selectedAppUUIDs.removeAll()

		// _editMode = .inactive
	}

	private func _openPendingImport() {
		guard pendingImportAfterInstall else { return }
		pendingImportAfterInstall = false
		_isImportingPresenting = true
	}

	private func _getAllApps() -> [AppInfoPresentable] {
		var allApps: [AppInfoPresentable] = []

		if _selectedScope == .all || _selectedScope == .signed {
			allApps.append(contentsOf: _filteredSignedApps)
		}

		if _selectedScope == .all || _selectedScope == .imported {
			allApps.append(contentsOf: _filteredImportedApps)
		}

		return allApps
	}

	private func _checkForUpdates() async {
		let localApps =
			_signedApps.map { $0 as AppInfoPresentable }
			+ _importedApps.map { $0 as AppInfoPresentable }
		await updateManager.checkForUpdates(
			sources: Array(_sources),
			localApps: localApps
		)
	}

	private func _checkForUpdatesAfterImport() async {
		do {
			try await Task.sleep(nanoseconds: 300_000_000)
		} catch {
			return
		}

		while updateManager.isChecking {
			do {
				try await Task.sleep(nanoseconds: 200_000_000)
			} catch {
				return
			}
		}

		guard !Task.isCancelled else { return }
		await _checkForUpdates()
	}

	private func _scheduleUpdateCheckAfterImport() {
		_importUpdateCheckTask?.cancel()
		_importUpdateCheckTask = Task {
			await _checkForUpdatesAfterImport()
		}
	}

	private func _handleUpdateCheckStateChange(_ isChecking: Bool) {
		if isChecking {
			_isUpdateCheckCompleteVisible = false
			_updateCheckRotation = 0
			withAnimation(
				.linear(duration: 0.8).repeatForever(autoreverses: false)
			) {
				_updateCheckRotation = 360
			}
		} else {
			withAnimation(.none) {
				_updateCheckRotation = 0
			}

			_isUpdateCheckCompleteVisible = true
			Task { @MainActor in
				try? await Task.sleep(nanoseconds: 900_000_000)
				if !updateManager.isChecking {
					_isUpdateCheckCompleteVisible = false
				}
			}
		}
	}
}

// MARK: - Extension: View (Sort)
extension LibraryView {
	enum Scope: CaseIterable {
		case all
		case signed
		case imported

		var displayName: String {
			switch self {
			case .all: return .localized("All")
			case .signed: return .localized("Signed")
			case .imported: return .localized("Imported")
			}
		}
	}
}

@MainActor
private enum LibraryLaunchState {
	static var didOpenPicker = false
}
