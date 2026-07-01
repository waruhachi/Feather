//
//  UpdateManager.swift
//  Feather
//
//  Created by Dominic on 24.05.2026.
//

import AltSourceKit
import CoreData
import Foundation
import NimbleJSON

struct AppUpdate: Identifiable, Equatable {
	let id: String
	let localUUID: String
	let localVersion: String?
	let remoteVersion: String
	let appName: String
	let bundleIdentifier: String
	let downloadURL: URL?
	let webURL: URL?
	let versionID: String
	let providerKind: UpdateProviderKind
	let sourceURL: URL?
	let sourceProvenance: SourceAppProvenance?

	var canDownload: Bool {
		downloadURL != nil
	}
}

@MainActor
final class UpdateManager: ObservableObject {
	static let shared = UpdateManager()

	typealias RepositoryDataHandler = Result<ASRepository, Error>

	@Published private(set) var updates: [String: AppUpdate] = [:]
	@Published private(set) var isChecking = false
	@Published private(set) var lastCheckedDate: Date?

	private let _dataService = NBFetchService()
	private let _jsonDecoder = JSONDecoder()

	private init() {}

	func update(for app: AppInfoPresentable) -> AppUpdate? {
		guard let uuid = app.uuid else { return nil }
		return updates[uuid]
	}

	func skipUpdate(for app: AppInfoPresentable) {
		guard let update = update(for: app) else { return }
		Storage.shared.skipUpdate(for: app, versionID: update.versionID)
		updates[update.localUUID] = nil
	}

	func setUpdatesDisabled(for app: AppInfoPresentable, disabled: Bool) {
		Storage.shared.setUpdatesDisabled(for: app, disabled: disabled)
		if disabled, let uuid = app.uuid {
			updates[uuid] = nil
		}
	}

	func clearCachedUpdate(for app: AppInfoPresentable) {
		guard let uuid = app.uuid else { return }
		updates[uuid] = nil
	}

	func appStoreURL(bundleIdentifier: String) async -> URL? {
		guard
			let appStoreApp = await _lookupAppStoreApp(
				bundleIdentifier: bundleIdentifier
			)
		else {
			return nil
		}

		return appStoreApp.trackViewURL
			?? URL(
				string: "https://apps.apple.com/app/id\(appStoreApp.trackID)"
			)
	}

	func checkForUpdate(
		sources: [AltSource],
		localApp: AppInfoPresentable
	) async {
		guard !isChecking else { return }
		guard let localUUID = localApp.uuid else { return }

		isChecking = true
		defer {
			isChecking = false
			lastCheckedDate = Date()
		}

		let repositories = await _fetchRepositories(from: sources)
		let foundUpdates = await _findUpdates(
			repositories: repositories,
			localApps: [localApp]
		)
		let foundUpdate = foundUpdates[localUUID]

		if let foundUpdate {
			updates[localUUID] = foundUpdate
		} else {
			updates[localUUID] = nil
		}
	}

	func checkForUpdates(
		sources: [AltSource],
		localApps: [AppInfoPresentable]
	) async {
		guard !isChecking else { return }

		isChecking = true
		defer {
			isChecking = false
			lastCheckedDate = Date()
		}

		let repositories = await _fetchRepositories(from: sources)
		updates = await _findUpdates(
			repositories: repositories,
			localApps: localApps
		)
	}

	private func _fetchRepositories(from sources: [AltSource]) async -> [(
		AltSource, ASRepository
	)] {
		var repositories: [(AltSource, ASRepository)] = []

		for source in sources {
			guard let url = source.sourceURL else {
				continue
			}

			guard let repository = await _fetchRepository(from: url) else {
				continue
			}

			repositories.append((source, repository))
		}

		return repositories
	}

	private func _fetchRepository(from url: URL) async -> ASRepository? {
		await withCheckedContinuation { continuation in
			_dataService.fetch(from: url) { (result: RepositoryDataHandler) in
				switch result {
				case .success(let repository):
					continuation.resume(returning: repository)
				case .failure:
					continuation.resume(returning: nil)
				}
			}
		}
	}

	private func _findUpdates(
		repositories: [(AltSource, ASRepository)],
		localApps: [AppInfoPresentable]
	) async -> [String: AppUpdate] {
		var foundUpdates: [String: AppUpdate] = [:]
		let metadataByUUID = Storage.shared.getSourceMetadata().reduce(
			into: [String: AppSourceMetadata]()
		) {
			guard let appUUID = $1.appUUID else { return }
			$0[appUUID] = $1
		}

		for localApp in localApps {
			guard let localUUID = localApp.uuid else {
				continue
			}

			let metadata = metadataByUUID[localUUID]
			guard metadata?.updatesDisabled != true else {
				continue
			}

			let storedProviderKind = UpdateProviderKind(
				rawValue: metadata?.updateProviderKind ?? ""
			)
			let originKind = IPAOriginKind(rawValue: metadata?.originKind ?? "")
			let providerKind = _effectiveProviderKind(
				storedProviderKind: storedProviderKind,
				originKind: originKind,
				originURL: metadata?.originURL
			)
			let update: AppUpdate?

			switch providerKind {
			case .some(.featherSource):
				update = await _findFeatherSourceUpdate(
					repositories: repositories,
					localApp: localApp,
					localUUID: localUUID,
					metadata: metadata
				)
			case .some(.appStore):
				update = await _findAppStoreUpdate(
					localApp: localApp,
					localUUID: localUUID,
					metadata: metadata
				)
			case .some(.github), .some(.gitlab):
				update = await _findReleaseUpdate(
					localApp: localApp,
					localUUID: localUUID,
					metadata: metadata
				)
			case .some(.none), nil:
				if let sourceUpdate = await _findFeatherSourceUpdate(
					repositories: repositories,
					localApp: localApp,
					localUUID: localUUID,
					metadata: metadata
				) {
					update = sourceUpdate
				} else if originKind == .remoteURL {
					if _isReleaseSource(metadata?.originURL) {
						update = await _findReleaseUpdate(
							localApp: localApp,
							localUUID: localUUID,
							metadata: metadata
						)
					} else {
						update = await _findAppStoreUpdate(
							localApp: localApp,
							localUUID: localUUID,
							metadata: metadata
						)
					}
				} else if originKind == .localFile || originKind == .unknown
					|| metadata == nil
				{
					update = await _findAppStoreUpdate(
						localApp: localApp,
						localUUID: localUUID,
						metadata: metadata
					)
				} else {
					update = nil
				}
			}

			guard let update else {
				continue
			}

			guard metadata?.skippedUpdateVersionID != update.versionID else {
				continue
			}

			foundUpdates[localUUID] = update
		}

		return foundUpdates
	}

	private func _findFeatherSourceUpdate(
		repositories: [(AltSource, ASRepository)],
		localApp: AppInfoPresentable,
		localUUID: String,
		metadata: AppSourceMetadata?
	) async -> AppUpdate? {
		let sourceAppIdentifier: String
		let sourceAppVersion: String?
		let storedSourceURL: URL

		if let metadata {
			guard
				let metadataSourceAppIdentifier = metadata.sourceAppIdentifier,
				let metadataSourceURL = metadata.sourceRepositoryURL
			else {
				return nil
			}

			sourceAppIdentifier = metadataSourceAppIdentifier
			sourceAppVersion = metadata.sourceAppVersion
			storedSourceURL = metadataSourceURL
		} else {
			guard
				let localSourceURL = localApp.source,
				let localIdentifier = localApp.identifier
			else {
				return nil
			}

			sourceAppIdentifier = localIdentifier
			sourceAppVersion = localApp.version
			storedSourceURL = localSourceURL
		}

		var candidateRepositories = repositories.compactMap {
			source,
			repository -> (URL, ASRepository)? in
			guard let sourceURL = source.sourceURL else { return nil }
			return (sourceURL, repository)
		}
		if !candidateRepositories.contains(where: {
			let sourceURL = $0.0
			return _matchesStoredRepository(
				storedSourceURL: storedSourceURL,
				sourceURL: sourceURL
			)
		}), let repository = await _fetchRepository(from: storedSourceURL) {
			candidateRepositories.append((storedSourceURL, repository))
		}

		for (sourceURL, repository) in candidateRepositories {
			guard
				_matchesStoredRepository(
					storedSourceURL: storedSourceURL,
					sourceURL: sourceURL
				)
			else {
				continue
			}

			guard
				let remoteApp = repository.apps.first(where: {
					$0.id == sourceAppIdentifier
				})
			else {
				continue
			}

			guard let remoteVersion = remoteApp.currentVersion,
				!remoteVersion.isEmpty
			else {
				continue
			}

			guard
				_isRemoteVersion(
					remoteVersion,
					newerThan: sourceAppVersion ?? localApp.version
				)
			else {
				continue
			}

			guard let downloadURL = remoteApp.currentDownloadUrl else {
				continue
			}

			guard
				let provenance = SourceAppProvenance(
					sourceURL: sourceURL,
					repository: repository,
					app: remoteApp
				)
			else {
				continue
			}

			return AppUpdate(
				id: localUUID,
				localUUID: localUUID,
				localVersion: sourceAppVersion ?? localApp.version,
				remoteVersion: remoteVersion,
				appName: remoteApp.currentName,
				bundleIdentifier: sourceAppIdentifier,
				downloadURL: downloadURL,
				webURL: sourceURL,
				versionID: provenance.sourceVersionID,
				providerKind: .featherSource,
				sourceURL: sourceURL,
				sourceProvenance: provenance
			)
		}

		return nil
	}

	private func _effectiveProviderKind(
		storedProviderKind: UpdateProviderKind?,
		originKind: IPAOriginKind?,
		originURL: URL?
	) -> UpdateProviderKind? {
		guard originKind == .remoteURL, let originURL else {
			return storedProviderKind
		}

		let remoteProviderKind = Storage.shared.remoteUpdateProviderKind(
			for: originURL
		)
		switch remoteProviderKind {
		case .github, .gitlab:
			return remoteProviderKind
		case .featherSource, .appStore, .none:
			return storedProviderKind
		}
	}

	private func _isReleaseSource(_ url: URL?) -> Bool {
		guard let url else { return false }
		return ReleaseSource(url: url) != nil
	}

	private func _findAppStoreUpdate(
		localApp: AppInfoPresentable,
		localUUID: String,
		metadata: AppSourceMetadata?
	) async -> AppUpdate? {
		guard
			let bundleIdentifier = metadata?.sourceAppIdentifier
				?? localApp.identifier
		else {
			return nil
		}

		guard
			let appStoreApp = await _lookupAppStoreApp(
				bundleIdentifier: bundleIdentifier
			)
		else {
			return nil
		}

		guard
			_isRemoteVersion(
				appStoreApp.version,
				newerThan: metadata?.sourceAppVersion ?? localApp.version
			)
		else {
			return nil
		}

		let versionID = [
			UpdateProviderKind.appStore.rawValue,
			String(appStoreApp.trackID),
			appStoreApp.version,
		].joined(separator: "|")

		return AppUpdate(
			id: localUUID,
			localUUID: localUUID,
			localVersion: metadata?.sourceAppVersion ?? localApp.version,
			remoteVersion: appStoreApp.version,
			appName: appStoreApp.trackName,
			bundleIdentifier: appStoreApp.bundleID,
			downloadURL: nil,
			webURL: appStoreApp.trackViewURL
				?? URL(
					string:
						"https://apps.apple.com/app/id\(appStoreApp.trackID)"
				),
			versionID: versionID,
			providerKind: .appStore,
			sourceURL: nil,
			sourceProvenance: nil
		)
	}

	private func _lookupAppStoreApp(bundleIdentifier: String) async
		-> AppStoreApp?
	{
		guard
			let encodedBundleID = bundleIdentifier.addingPercentEncoding(
				withAllowedCharacters: .urlQueryAllowed
			)
		else {
			return nil
		}

		guard
			let url = URL(
				string:
					"https://itunes.apple.com/lookup?bundleId=\(encodedBundleID)"
			),
			let response = await _appStoreResponse(from: url)
		else {
			return nil
		}

		return response.results.first
	}

	private func _appStoreResponse(from url: URL) async
		-> AppStoreLookupResponse?
	{
		do {
			let (data, _) = try await URLSession.shared.data(from: url)
			return try _jsonDecoder.decode(
				AppStoreLookupResponse.self,
				from: data
			)
		} catch {
			return nil
		}
	}

	private func _findReleaseUpdate(
		localApp: AppInfoPresentable,
		localUUID: String,
		metadata: AppSourceMetadata?
	) async -> AppUpdate? {
		guard
			let originURL = metadata?.originURL,
			let releaseSource = ReleaseSource(url: originURL),
			let release = await _latestRelease(from: releaseSource)
		else {
			return nil
		}

		guard
			_isRemoteVersion(
				release.version,
				newerThan: metadata?.sourceAppVersion ?? localApp.version
			)
		else {
			return nil
		}

		guard
			let asset = _asset(
				for: release,
				preferredName: releaseSource.assetName
			)
		else {
			return nil
		}

		return AppUpdate(
			id: localUUID,
			localUUID: localUUID,
			localVersion: metadata?.sourceAppVersion ?? localApp.version,
			remoteVersion: release.version,
			appName: metadata?.sourceAppName ?? localApp.name
				?? releaseSource.identifier,
			bundleIdentifier: metadata?.sourceAppIdentifier ?? localApp
				.identifier ?? releaseSource.identifier,
			downloadURL: asset.downloadURL,
			webURL: release.webURL,
			versionID: [
				releaseSource.kind.rawValue,
				releaseSource.identifier,
				release.id,
				asset.id,
			].joined(separator: "|"),
			providerKind: releaseSource.kind,
			sourceURL: releaseSource.webURL,
			sourceProvenance: nil
		)
	}

	private func _latestRelease(from source: ReleaseSource) async
		-> ReleaseCandidate?
	{
		let releases: [ReleaseCandidate]
		switch source.kind {
		case .github:
			releases = await _githubReleases(from: source)
		case .gitlab:
			releases = await _gitLabReleases(from: source)
		default:
			releases = []
		}

		let stableRelease =
			releases
			.filter { !$0.isPrerelease }
			.max {
				_compareVersions($0.version, $1.version) == .orderedAscending
			}
		let prerelease =
			releases
			.filter(\.isPrerelease)
			.max {
				_compareVersions($0.version, $1.version) == .orderedAscending
			}

		guard let prerelease else {
			return stableRelease
		}

		guard let stableRelease else {
			return prerelease
		}

		return _compareVersions(prerelease.version, stableRelease.version)
			== .orderedDescending
			? prerelease
			: stableRelease
	}

	private func _githubReleases(from source: ReleaseSource) async
		-> [ReleaseCandidate]
	{
		do {
			let (data, _) = try await URLSession.shared.data(
				from: source.apiURL
			)
			return try _jsonDecoder.decode([GitHubRelease].self, from: data).map
			{
				ReleaseCandidate(
					id: String($0.id),
					version: _version(from: $0.tagName),
					webURL: $0.htmlURL,
					isPrerelease: $0.prerelease,
					assets: $0.assets.map {
						ReleaseAsset(
							id: String($0.id),
							name: $0.name,
							downloadURL: $0.browserDownloadURL
						)
					}
				)
			}
		} catch {
			return []
		}
	}

	private func _gitLabReleases(from source: ReleaseSource) async
		-> [ReleaseCandidate]
	{
		do {
			let (data, _) = try await URLSession.shared.data(
				from: source.apiURL
			)
			return try _jsonDecoder.decode([GitLabRelease].self, from: data).map
			{
				let assets = ($0.assets?.links ?? []).compactMap {
					asset -> ReleaseAsset? in
					guard
						let urlString = asset.directAssetURL ?? asset.url,
						let downloadURL = URL(
							string: urlString,
							relativeTo: source.webURL
						)?.absoluteURL
					else {
						return nil
					}

					return ReleaseAsset(
						id: asset.id.map(String.init) ?? asset.name,
						name: asset.name,
						downloadURL: downloadURL
					)
				}

				return ReleaseCandidate(
					id: $0.tagName,
					version: _version(from: $0.tagName),
					webURL: $0.links?.selfURL,
					isPrerelease: _isPrereleaseTag($0.tagName),
					assets: assets
				)
			}
		} catch {
			return []
		}
	}

	private func _asset(for release: ReleaseCandidate, preferredName: String?)
		-> ReleaseAsset?
	{
		let assets = release.assets
		if let preferredName,
			let matchingAsset = assets.first(where: {
				$0.name.caseInsensitiveCompare(preferredName) == .orderedSame
			})
		{
			return matchingAsset
		}

		if assets.count == 1 {
			return assets[0]
		}

		return assets.first {
			$0.name.lowercased().hasSuffix(".ipa")
		}
	}

	private func _matchesStoredRepository(
		storedSourceURL: URL,
		sourceURL: URL
	) -> Bool {
		_normalizedSourceURL(storedSourceURL) == _normalizedSourceURL(sourceURL)
	}

	private func _normalizedSourceURL(_ url: URL) -> String {
		var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
		let scheme = components?.scheme?.lowercased()
		let host = components?.host?.lowercased()
		components?.scheme = scheme
		components?.host = host
		components?.fragment = nil

		let normalized = components?.url ?? url
		let absoluteString = normalized.absoluteString
		return absoluteString.hasSuffix("/")
			? String(absoluteString.dropLast()) : absoluteString
	}

	private func _isRemoteVersion(
		_ remoteVersion: String,
		newerThan localVersion: String?
	) -> Bool {
		guard let localVersion, !localVersion.isEmpty else {
			return true
		}

		return _compareVersions(remoteVersion, localVersion)
			== .orderedDescending
	}

	private func _compareVersions(_ lhs: String, _ rhs: String)
		-> ComparisonResult
	{
		let lhsComponents = _numericVersionComponents(lhs)
		let rhsComponents = _numericVersionComponents(rhs)
		let count = max(lhsComponents.count, rhsComponents.count)

		for index in 0..<count {
			let lhsValue =
				index < lhsComponents.count ? lhsComponents[index] : 0
			let rhsValue =
				index < rhsComponents.count ? rhsComponents[index] : 0

			if lhsValue > rhsValue {
				return .orderedDescending
			} else if lhsValue < rhsValue {
				return .orderedAscending
			}
		}

		let lhsPrerelease = _isPrereleaseTag(lhs)
		let rhsPrerelease = _isPrereleaseTag(rhs)
		if lhsPrerelease != rhsPrerelease {
			return lhsPrerelease ? .orderedAscending : .orderedDescending
		}

		return .orderedSame
	}

	private func _numericVersionComponents(_ version: String) -> [Int] {
		_version(from: version)
			.split { !$0.isNumber }
			.compactMap { Int($0) }
	}

	private func _version(from tag: String) -> String {
		let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
		let startIndex =
			trimmed.firstIndex(where: { $0.isNumber }) ?? trimmed.startIndex
		return String(trimmed[startIndex...])
	}

	private func _isPrereleaseTag(_ tag: String) -> Bool {
		let lowercased = tag.lowercased()
		return lowercased.contains("alpha") || lowercased.contains("beta")
			|| lowercased.contains("rc") || lowercased.contains("pre")
			|| lowercased.contains("preview")
	}
}

private struct ReleaseSource {
	let kind: UpdateProviderKind
	let identifier: String
	let apiURL: URL
	let webURL: URL
	let assetName: String?

	init?(url: URL) {
		guard let host = url.host?.lowercased() else {
			return nil
		}

		let pathComponents = url.pathComponents.filter { $0 != "/" }

		if host == "github.com" || host.hasSuffix(".github.com") {
			let isTaggedDownload =
				pathComponents.count >= 6
				&& pathComponents[2] == "releases"
				&& pathComponents[3] == "download"
			let isLatestDownload =
				pathComponents.count >= 6
				&& pathComponents[2] == "releases"
				&& pathComponents[3] == "latest"
				&& pathComponents[4] == "download"
			guard
				isTaggedDownload || isLatestDownload,
				let apiURL = URL(
					string:
						"https://api.github.com/repos/\(pathComponents[0])/\(pathComponents[1])/releases"
				),
				let webURL = URL(
					string:
						"https://github.com/\(pathComponents[0])/\(pathComponents[1])"
				)
			else {
				return nil
			}

			self.kind = .github
			self.identifier = "\(pathComponents[0])/\(pathComponents[1])"
			self.apiURL = apiURL
			self.webURL = webURL
			self.assetName = pathComponents.last
			return
		}

		if host == "gitlab.com" || host.hasSuffix(".gitlab.com") {
			guard let markerIndex = pathComponents.firstIndex(of: "-") else {
				return nil
			}

			let projectPathComponents = pathComponents[..<markerIndex]
			let releaseMarker = Array(pathComponents[markerIndex...])
			guard
				releaseMarker.count >= 4,
				releaseMarker[1] == "releases",
				let encodedProjectPath = projectPathComponents.joined(
					separator: "/"
				)
				.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
				.replacingOccurrences(of: "/", with: "%2F"),
				let apiURL = URL(
					string:
						"https://gitlab.com/api/v4/projects/\(encodedProjectPath)/releases"
				),
				let webURL = URL(
					string:
						"https://gitlab.com/\(projectPathComponents.joined(separator: "/"))"
				)
			else {
				return nil
			}

			self.kind = .gitlab
			self.identifier = projectPathComponents.joined(separator: "/")
			self.apiURL = apiURL
			self.webURL = webURL
			self.assetName = pathComponents.last
			return
		}

		return nil
	}
}

private struct ReleaseCandidate {
	let id: String
	let version: String
	let webURL: URL?
	let isPrerelease: Bool
	let assets: [ReleaseAsset]
}

private struct ReleaseAsset {
	let id: String
	let name: String
	let downloadURL: URL
}

private struct AppStoreLookupResponse: Decodable {
	let resultCount: Int
	let results: [AppStoreApp]
}

private struct AppStoreApp: Decodable {
	let trackID: Int
	let bundleID: String
	let trackName: String
	let version: String
	let trackViewURL: URL?

	enum CodingKeys: String, CodingKey {
		case trackID = "trackId"
		case bundleID = "bundleId"
		case trackName
		case version
		case trackViewURL = "trackViewUrl"
	}
}

private struct GitHubRelease: Decodable {
	let id: Int
	let tagName: String
	let prerelease: Bool
	let htmlURL: URL?
	let assets: [GitHubAsset]

	enum CodingKeys: String, CodingKey {
		case id
		case tagName = "tag_name"
		case prerelease
		case htmlURL = "html_url"
		case assets
	}
}

private struct GitHubAsset: Decodable {
	let id: Int
	let name: String
	let browserDownloadURL: URL

	enum CodingKeys: String, CodingKey {
		case id
		case name
		case browserDownloadURL = "browser_download_url"
	}
}

private struct GitLabRelease: Decodable {
	let tagName: String
	let assets: GitLabAssets?
	let links: GitLabLinks?

	enum CodingKeys: String, CodingKey {
		case tagName = "tag_name"
		case assets
		case links = "_links"
	}
}

private struct GitLabAssets: Decodable {
	let links: [GitLabAsset]?
}

private struct GitLabAsset: Decodable {
	let id: Int?
	let name: String
	let directAssetURL: String?
	let url: String?

	enum CodingKeys: String, CodingKey {
		case id
		case name
		case directAssetURL = "direct_asset_url"
		case url
	}
}

private struct GitLabLinks: Decodable {
	let selfURL: URL?

	enum CodingKeys: String, CodingKey {
		case selfURL = "self"
	}
}
