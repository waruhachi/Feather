//
//  LibraryInfoView.swift
//  Feather
//
//  Created by samara on 14.04.2025.
//

import NimbleViews
import SwiftUI
import Zsign

// MARK: - View
struct LibraryInfoView: View {
	var app: AppInfoPresentable

	@ObservedObject private var _updateManager = UpdateManager.shared
	@State private var _metadataRevision = 0
	@State private var _appStoreSourceURL: URL?
	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [
			NSSortDescriptor(keyPath: \AltSource.name, ascending: true)
		]
	) private var _sources: FetchedResults<AltSource>

	// MARK: Body
	var body: some View {
		NBNavigationView(app.name ?? "", displayMode: .inline) {
			List {
				Section {
				} header: {
					FRAppIconView(app: app)
						.frame(maxWidth: .infinity, alignment: .center)
				}

				_infoSection(for: app)
				_updateSourceSection(for: app)
				_updateOptionsSection(for: app)
				_certSection(for: app)
				_bundleSection(for: app)
				_executableSection(for: app)

				Section {
					Button(.localized("Open in Files"), systemImage: "folder") {
						UIApplication.open(
							Storage.shared.getUuidDirectory(for: app)!
								.toSharedDocumentsURL()!
						)
					}
				}
			}
			.toolbar {
				NBToolbarButton(role: .close)
			}
			.task(id: _appStoreLookupID) {
				await _refreshAppStoreSourceURL()
			}
		}
	}
}

// MARK: - Extension: View
extension LibraryInfoView {
	@ViewBuilder
	private func _infoSection(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Info")) {
			if let name = app.name {
				_infoCell(.localized("Name"), desc: name)
			}

			if let ver = app.version {
				_infoCell(.localized("Version"), desc: ver)
			}

			if let id = app.identifier {
				_infoCell(.localized("Identifier"), desc: id)
			}

			if let date = app.date {
				_infoCell(.localized("Date Added"), desc: date.formatted())
			}
		}
	}

	@ViewBuilder
	private func _updateSourceSection(for app: AppInfoPresentable) -> some View
	{
		let metadata = _sourceMetadata(for: app)
		let sourceURL = _sourceURL(metadata)

		NBSection(.localized("Update")) {
			LabeledContent(.localized("Source")) {
				Text(_sourceDescription(metadata))
					.foregroundStyle(.secondary)
			}
			.contextMenu {
				if let sourceURL {
					Button(.localized("Open Source"), systemImage: "safari") {
						UIApplication.open(sourceURL)
					}
					Button(.localized("Copy"), systemImage: "doc.on.doc") {
						UIPasteboard.general.string = sourceURL.absoluteString
					}
				}
			}
		}
	}

	@ViewBuilder
	private func _updateOptionsSection(for app: AppInfoPresentable) -> some View
	{
		let hasUpdate = _updateManager.update(for: app) != nil
		let updatesDisabled = Storage.shared.updatesDisabled(for: app.uuid)
		let skippedVersionID = Storage.shared.skippedUpdateVersionID(
			for: app.uuid
		)

		Section {
			if hasUpdate {
				Button(
					.localized("Skip This Update"),
					systemImage: "forward.end"
				) {
					_updateManager.skipUpdate(for: app)
					Task {
						await _refreshUpdate()
					}
				}
			}

			if skippedVersionID != nil {
				Button(
					.localized("Clear Skipped Update"),
					systemImage: "arrow.uturn.backward"
				) {
					Storage.shared.clearSkippedUpdate(for: app.uuid)
					Task {
						await _refreshUpdate()
					}
				}
			}

			Button(
				updatesDisabled
					? .localized("Enable Updates")
					: .localized("Disable Updates"),
				systemImage: updatesDisabled ? "bell" : "bell.slash"
			) {
				_updateManager.setUpdatesDisabled(
					for: app,
					disabled: !updatesDisabled
				)
				Task {
					await _refreshUpdate()
				}
			}
		}
	}

	@ViewBuilder
	private func _certSection(for app: AppInfoPresentable) -> some View {
		if let cert = Storage.shared.getCertificate(from: app) {
			NBSection(.localized("Certificate")) {
				CertificatesCellView(
					cert: cert
				)
			}
		}
	}

	@ViewBuilder
	private func _bundleSection(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Bundle")) {
			NavigationLink(.localized("Alternative Icons")) {
				SigningAlternativeIconView(
					app: app,
					appIcon: .constant(nil),
					isModifing: .constant(false)
				)
			}
			NavigationLink(.localized("Frameworks & PlugIns")) {
				SigningFrameworksView(app: app, options: .constant(nil))
			}
		}
	}

	@ViewBuilder
	private func _executableSection(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Executable")) {
			NavigationLink(.localized("Dylibs")) {
				SigningDylibView(app: app, options: .constant(nil))
			}
		}
	}

	@ViewBuilder
	private func _infoCell(_ title: String, desc: String) -> some View {
		LabeledContent(title) {
			Text(desc)
		}
		.copyableText(desc)
	}

	private func _sourceMetadata(for app: AppInfoPresentable)
		-> AppSourceMetadata?
	{
		_ = _metadataRevision
		return Storage.shared.sourceMetadata(for: app)
	}

	private var _appStoreLookupID: String {
		[
			app.identifier ?? "",
			String(_metadataRevision),
		].joined(separator: "|")
	}

	private func _providerDescription(_ metadata: AppSourceMetadata?) -> String
	{
		guard
			let providerKind = UpdateProviderKind(
				rawValue: metadata?.updateProviderKind ?? ""
			)
		else {
			return .localized("Automatic")
		}

		switch providerKind {
		case .featherSource:
			return .localized("Feather Repo")
		case .appStore:
			return .localized("App Store")
		case .github:
			return .localized("GitHub")
		case .gitlab:
			return .localized("GitLab")
		case .none:
			return .localized("Automatic")
		}
	}

	private func _sourceDescription(_ metadata: AppSourceMetadata?) -> String {
		if let originURL = metadata?.originURL ?? metadata?.updateProviderURL {
			let providerKind = Storage.shared.remoteUpdateProviderKind(
				for: originURL
			)
			switch providerKind {
			case .github:
				return .localized("GitHub")
			case .gitlab:
				return .localized("GitLab")
			case .featherSource:
				return .localized("Feather Repo")
			case .appStore:
				return .localized("App Store")
			case .none:
				break
			}
		}

		let providerDescription = _providerDescription(metadata)
		if providerDescription != .localized("Automatic"),
			providerDescription != .localized("Remote URL")
		{
			return providerDescription
		}

		guard
			let originKind = IPAOriginKind(rawValue: metadata?.originKind ?? "")
		else {
			return .localized("App Store")
		}

		switch originKind {
		case .featherSource:
			return .localized("Feather Repo")
		case .remoteURL:
			return .localized("Remote URL")
		case .localFile, .unknown:
			return .localized("App Store")
		}
	}

	private func _sourceURL(_ metadata: AppSourceMetadata?) -> URL? {
		if let originURL = metadata?.originURL {
			return _appRepositoryURL(originURL)
		}

		if let sourceRepositoryURL = metadata?.sourceRepositoryURL {
			return sourceRepositoryURL
		}

		if let updateProviderURL = metadata?.updateProviderURL {
			return _appRepositoryURL(updateProviderURL)
		}

		if _sourceDescription(metadata) == .localized("App Store") {
			return _appStoreSourceURL
		}

		return nil
	}

	private func _appRepositoryURL(_ url: URL) -> URL {
		guard let host = url.host?.lowercased() else {
			return url
		}

		let pathComponents = url.pathComponents.filter { $0 != "/" }

		if host == "github.com" || host.hasSuffix(".github.com"),
			pathComponents.count >= 2,
			let repositoryURL = URL(
				string:
					"https://github.com/\(pathComponents[0])/\(pathComponents[1])"
			)
		{
			return repositoryURL
		}

		if host == "gitlab.com" || host.hasSuffix(".gitlab.com") {
			let repositoryPathComponents: ArraySlice<String>
			if let markerIndex = pathComponents.firstIndex(of: "-") {
				repositoryPathComponents = pathComponents[..<markerIndex]
			} else {
				repositoryPathComponents = pathComponents[...]
			}

			if !repositoryPathComponents.isEmpty,
				let repositoryURL = URL(
					string:
						"https://gitlab.com/\(repositoryPathComponents.joined(separator: "/"))"
				)
			{
				return repositoryURL
			}
		}

		return url
	}

	private func _refreshAppStoreSourceURL() async {
		guard let identifier = app.identifier else {
			_appStoreSourceURL = nil
			return
		}

		_appStoreSourceURL = await UpdateManager.shared.appStoreURL(
			bundleIdentifier: identifier
		)
	}

	private func _refreshUpdate() async {
		_refreshMetadata()
		await UpdateManager.shared.checkForUpdate(
			sources: Array(_sources),
			localApp: app
		)
		_refreshMetadata()
	}

	private func _refreshMetadata() {
		_metadataRevision += 1
	}
}
