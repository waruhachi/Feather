//
//  DylibHandler.swift
//  feather
//
//  Created by samara on 8/17/24.
//  Copyright (c) 2024 Samara M (khcrysalis)
//

import Foundation
import Zsign
import OSLog

class TweakHandler {
	private let _fileManager = FileManager.default
	private var _urlsToInject: [URL] = []
	private var _directoriesToCheck: [(URL, TweakInjectionRule)] = []
	private var _extractedRules: [URL: TweakInjectionRule] = [:]
	private var _extensionInjections: [(relativePath: String, weak: Bool)] = []
	private let _frameworksRPath = "@executable_path/Frameworks"
	private let _commonDependencyPaths: [(needle: String, target: String)] = [
		("cepheiprefs.", "@rpath/CepheiPrefs.framework/CepheiPrefs"),
		("cepheiui.", "@rpath/CepheiUI.framework/CepheiUI"),
		("cephei.", "@rpath/Cephei.framework/Cephei"),
		("orion.", "@rpath/Orion.framework/Orion"),
		("substrate.", "@rpath/CydiaSubstrate.framework/CydiaSubstrate"),
	]

	private let _app: URL
	private var _options: Options
	private var _urls: [URL]

	init(
		app: URL,
		options: Options = OptionsManager.shared.options
	) {
		self._app = app
		self._options = options
		self._urls = options.injectionFiles + options.injectionFrameworks
	}

	private func _checkEllekit() async throws {
		let frameworksPath = _app.appendingPathComponent("Frameworks")
			.appendingPathComponent("CydiaSubstrate.framework")

		func addEllekit() async throws {
			if let ellekitURL = Bundle.main.url(
				forResource: "ellekit",
				withExtension: "deb"
			) {
				self._urls.insert(ellekitURL, at: 0)
			} else {
				Logger.misc.info("ellekit.deb not found in the app bundle")
			}

			try _fileManager.createDirectoryIfNeeded(
				at: _app.appendingPathComponent("Frameworks")
			)
		}
		// we should check if CydiaSubstrate.framework exists, if it doesn't
		// just add ellekit
		// experiment_replaceSubstrateWithEllekit:
		// 	for this version, we need to replace CydiaSubstrate.framework with
		//	our own version containing ElleKit
		// other:
		// 	just return if it exists, should work fine
		if _fileManager.fileExists(atPath: frameworksPath.path) {
			if _options.experiment_replaceSubstrateWithEllekit {
				Logger.misc.info("Attempting to replace Substrate with ElleKit")
				try _fileManager.removeFileIfNeeded(at: frameworksPath)
				try await addEllekit()
			} else {
				return
			}
		} else {
			guard !_urls.isEmpty else { return }
			try await addEllekit()
		}
	}

	public func getInputFiles() async throws {
		Logger.misc.info("Attempting to inject")

		if !_options.experiment_replaceSubstrateWithEllekit {
			guard !_urls.isEmpty else { return }
		}

		try await _checkEllekit()

		let baseTmpDir = _fileManager.temporaryDirectory.appendingPathComponent(
			"FeatherTweak_\(UUID().uuidString)"
		)
		try _fileManager.createDirectoryIfNeeded(at: baseTmpDir)
		defer { try? _fileManager.removeItem(at: baseTmpDir) }

		if let appexe = Bundle(url: _app)?.executableURL {
			_ = Zsign.addRPath(
				appExecutable: appexe.path,
				with: _frameworksRPath
			)
			_ = Zsign.addRPath(appExecutable: appexe.path, with: "@executable_path")
		}

		// check for appropriate files, if theres debs
		// it will extract then add a url, if theres no url, i.e.
		// you haven't added a deb, it will skip
		let inputs = _urls
		for url in inputs where url.pathExtension.lowercased() == "deb" {
			try await _handleDeb(at: url, baseTmpDir: baseTmpDir)
		}
		for (directory, rule) in _directoriesToCheck {
			let start = _urlsToInject.count
			try await _handleDirectories(at: [directory])
			for file in _urlsToInject.dropFirst(start) { _extractedRules[file] = rule }
		}
		_registerInjectedDependencies(_urlsToInject)

		for url in inputs {
			switch url.pathExtension.lowercased() {
			case "dylib":
				try await _handleDylib(at: url)
			case "deb":
				continue
			case "framework":
				try await _handleFramework(at: url)
			case "bundle":
				let destination = _app.appendingPathComponent(url.lastPathComponent)
				if !_fileManager.fileExists(atPath: destination.path) {
					try _fileManager.copyItem(at: url, to: destination)
				}
			default:
				Logger.misc.warning(
					"Unsupported file type: \(url.lastPathComponent), skipping."
				)
			}
		}

		try await _handleExtractedDirectoryContents(at: _urlsToInject)
		for extensionURL in _discoverAppExtensions() where !_extensionInjections.isEmpty {
			guard let executable = Bundle(url: extensionURL)?.executableURL else { continue }
			_ = Zsign.addRPath(appExecutable: executable.path, with: "@executable_path/../../Frameworks")
			_ = Zsign.addRPath(appExecutable: executable.path, with: "@executable_path/../..")
			for injection in _extensionInjections {
				_ = Zsign.injectDyLib(appExecutable: executable.path,
					with: "@executable_path/../../" + injection.relativePath, weak: injection.weak)
			}
		}
	}

	private func _rule(for url: URL) -> TweakInjectionRule {
		_extractedRules[url] ?? _options.tweakInjectionRules?[url.absoluteString] ?? TweakInjectionRule()
	}

	private func _relativePath(for file: URL) -> String {
		let root = (_rule(for: file).folder ?? _options.injectFolder) == .frameworks ? "Frameworks/" : ""
		if file.pathExtension.lowercased() == "framework" {
			let executable = Bundle(url: file)?.executableURL?.lastPathComponent ?? file.deletingPathExtension().lastPathComponent
			return root + file.lastPathComponent + "/" + executable
		}
		return root + file.lastPathComponent
	}

	private func _inject(_ source: URL, relativePath: String, executable: URL) {
		let rule = _rule(for: source)
		if rule.includesApp() {
			var loadPath = "@executable_path/" + relativePath
			if (rule.path ?? _options.injectPath) == .rpath {
				let frameworks = relativePath.hasPrefix("Frameworks/")
				_ = Zsign.addRPath(appExecutable: executable.path, with: frameworks ? _frameworksRPath : "@executable_path")
				loadPath = "@rpath/" + (frameworks ? String(relativePath.dropFirst("Frameworks/".count)) : relativePath)
			}
			_ = Zsign.injectDyLib(appExecutable: executable.path, with: loadPath, weak: rule.weak)
		}
		if rule.includesExtensions(defaultValue: _options.injectIntoExtensions) {
			_extensionInjections.append((relativePath, rule.weak))
		}
	}

	// finally, handle extracted contents
	private func _handleExtractedDirectoryContents(at urls: [URL]) async throws
	{
		for url in urls {
			switch url.pathExtension.lowercased() {
			case "dylib":
				try await _handleDylib(at: url)
			case "framework":
				try await _handleFramework(at: url)
			case "bundle":
				let destinationURL = _app.appendingPathComponent(
					url.lastPathComponent
				)
				try _fileManager.moveFileIfNeeded(from: url, to: destinationURL)
			default:
				Logger.misc.warning(
					"Unsupported file type: \(url.lastPathComponent), skipping."
				)
			}
		}
	}

	private func _registerInjectedDependencies(_ urls: [URL]) {
		let knownURLs = Set(_urls.map(\.lastPathComponent))
		let missingURLs = urls.filter {
			!knownURLs.contains($0.lastPathComponent)
		}
		_urls.append(contentsOf: missingURLs)
	}

	private func _handleFramework(at url: URL) async throws {
		var isDirectory: ObjCBool = false
		let isFrameworkDirectory =
			_fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
			&& isDirectory.boolValue

		guard url.pathExtension.lowercased() == "framework",
			isFrameworkDirectory
		else {
			Logger.misc.warning(
				"Skipping invalid framework input: \(url.lastPathComponent)"
			)
			return
		}

		let destinationDirectory = (_rule(for: url).folder ?? _options.injectFolder) == .frameworks
			? _app.appendingPathComponent("Frameworks") : _app
		try _fileManager.createDirectoryIfNeeded(at: destinationDirectory)

		let destinationURL = destinationDirectory.appendingPathComponent(
			url.lastPathComponent
		)
		try _fileManager.removeFileIfNeeded(at: destinationURL)
		try _fileManager.moveItem(at: url, to: destinationURL)

		try await _handleDylib(framework: destinationURL, source: url)
	}

	// Inject imported dylib file
	private func _handleDylib(at url: URL) async throws {
		let relativePath = _relativePath(for: url)
		let destinationURL = _app.appendingPathComponent(relativePath)
		try _fileManager.createDirectoryIfNeeded(at: destinationURL.deletingLastPathComponent())
		try _fileManager.moveFileIfNeeded(from: url, to: destinationURL)

		guard let appexe = Bundle(url: _app)?.executableURL else {
			return
		}

		// change paths because some tweaks hardlink, which is not ideal.
		// this is not a good solution, at most this would work for basic tweaks
		// we recommend you use newer theos to compile, and make sure it works
		// using the ellekit framework
		_ = Zsign.changeDylibPath(
			appExecutable: destinationURL.path,
			for: "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
			with: "@rpath/CydiaSubstrate.framework/CydiaSubstrate"
		)
		_fixCommonDependencies(in: destinationURL)
		_fixInjectedDependencies(in: destinationURL)
		// inject if there's a valid app main executable
		_inject(url, relativePath: relativePath, executable: appexe)
	}

	// Inject imported framework dir
	private func _handleDylib(framework: URL, source: URL) async throws {
		guard
			let fexe = Bundle(url: framework)?.executableURL,
			let appexe = Bundle(url: _app)?.executableURL
		else {
			return
		}

		// change paths because some tweaks hardlink, which is not ideal.
		// this is not a good solution, at most this would work for basic tweaks
		// we recommend you use newer theos to compile, and make sure it works
		// using the ellekit framework
		_ = Zsign.changeDylibPath(
			appExecutable: fexe.path,
			for: "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
			with: "@rpath/CydiaSubstrate.framework/CydiaSubstrate"
		)
		_fixCommonDependencies(in: fexe)
		_fixInjectedDependencies(in: fexe)
		// inject if there's a valid app main executable
		let prefix = framework.deletingLastPathComponent() == _app ? "" : "Frameworks/"
		_inject(source, relativePath: prefix + framework.lastPathComponent + "/" + fexe.lastPathComponent,
				executable: appexe)
	}

	private func _fixCommonDependencies(in executable: URL) {
		let dependencies = Zsign.listDylibs(appExecutable: executable.path)

		for dependency in dependencies {
			let lowercaseDependency = dependency.lowercased()

			for rule in _commonDependencyPaths {
				guard lowercaseDependency.contains(rule.needle),
					dependency != rule.target
				else { continue }

				let didChange = Zsign.changeDylibPath(
					appExecutable: executable.path,
					for: dependency,
					with: rule.target
				)

				if didChange {
					Logger.misc.info(
						"Fixed dependency in \(executable.lastPathComponent): \(dependency) -> \(rule.target)"
					)
				}
			}
		}
	}

	private func _fixInjectedDependencies(in executable: URL) {
		let dependencies = Zsign.listDylibs(appExecutable: executable.path)

		for dependency in dependencies {
			for url in _urls {
				let name = url.lastPathComponent
				guard dependency.contains(name) else { continue }

				let relative = _relativePath(for: url)
				let target = "@rpath/" + (relative.hasPrefix("Frameworks/")
					? String(relative.dropFirst("Frameworks/".count)) : relative)

				guard dependency != target else { continue }

				let didChange = Zsign.changeDylibPath(
					appExecutable: executable.path,
					for: dependency,
					with: target
				)

				if didChange {
					Logger.misc.info(
						"Fixed injected dependency in \(executable.lastPathComponent): \(dependency) -> \(target)"
					)
				}
			}
		}
	}

	// Extracy imported deb file
	private func _handleDeb(at url: URL, baseTmpDir: URL) async throws {
		let uniqueSubDir = baseTmpDir.appendingPathComponent(UUID().uuidString)
		try _fileManager.createDirectoryIfNeeded(at: uniqueSubDir)

		// I don't particularly like this code
		// but it somehow works well enough,
		// do note large lzma's are slow as hell

		let handler = AR(with: url)
		let arFiles = try await handler.extract()

		for arFile in arFiles {
			if ["data.tar.lzma", "data.tar.gz", "data.tar.xz", "data.tar.bz2", "data.tar"]
				.contains(arFile.name)
			{
				let outputPath = uniqueSubDir.appendingPathComponent(arFile.name)
				try arFile.content.write(to: outputPath)
				var fileToProcess = outputPath
				if arFile.name != "data.tar" {
					try extractFile(at: &fileToProcess)
				}
				try extractFile(at: &fileToProcess)
				_directoriesToCheck.append((fileToProcess, _rule(for: url)))
			}
		}
	}

	// Read extracted deb file, locate all neccessary contents to copy over to the .app
	private func _handleDirectories(at urls: [URL]) async throws {
		enum DirectoryType: String {
			case frameworks = "Frameworks"
			case dynamicLibraries = "MobileSubstrate/DynamicLibraries"
			case applicationSupport = "Application Support"
		}

		let directoryPaths: [DirectoryType: [String]] = [
			.frameworks: ["Library/Frameworks/", "var/jb/Library/Frameworks/"],
			.dynamicLibraries: [
				"Library/MobileSubstrate/DynamicLibraries/",
				"var/jb/Library/MobileSubstrate/DynamicLibraries/",
			],
			.applicationSupport: [
				"Library/Application Support/",
				"var/jb/Library/Application Support/",
			],
		]

		for baseURL in urls {
			for (directoryType, paths) in directoryPaths {
				for path in paths {
					let directoryURL = baseURL.appendingPathComponent(path)

					guard _fileManager.fileExists(atPath: directoryURL.path)
					else {
						Logger.misc.warning(
							"Directory does not exist: \(directoryURL.path). Skipping."
						)
						continue
					}

					switch directoryType {
					case .dynamicLibraries:
						let dylibFiles = try await _locateDylibFiles(
							in: directoryURL
						)
						_urlsToInject.append(contentsOf: dylibFiles)

					case .frameworks:
						let frameworkDirectories =
							try await _locateFrameworkDirectories(
								in: directoryURL
							)
						_urlsToInject.append(contentsOf: frameworkDirectories)

					case .applicationSupport:
						try await _searchForBundles(in: directoryURL)
					}
				}
			}
		}
	}

	// Discovers all .appex bundles in the app's PlugIns and Extensions directories
	private func _discoverAppExtensions() -> [URL] {
		var extensions: [URL] = []

		let plugInsPath = _app.appendingPathComponent("PlugIns")
		let extensionsPath = _app.appendingPathComponent("Extensions")

		for directory in [plugInsPath, extensionsPath] {
			guard _fileManager.fileExists(atPath: directory.path) else {
				continue
			}

			do {
				let contents = try _fileManager.contentsOfDirectory(
					at: directory,
					includingPropertiesForKeys: nil,
					options: [.skipsHiddenFiles]
				)

				let appexBundles = contents.filter { url in
					url.pathExtension.lowercased() == "appex"
						&& url.hasDirectoryPath
				}

				extensions.append(contentsOf: appexBundles)
			} catch {
				Logger.misc.warning(
					"Failed to enumerate \(directory.path): \(error.localizedDescription)"
				)
			}
		}

		return extensions
	}


}

// MARK: - Find correct files in debs
extension TweakHandler {
	private func _searchForBundles(in directory: URL) async throws {
		let fileManager = FileManager.default
		let allFiles = try fileManager.contentsOfDirectory(
			at: directory,
			includingPropertiesForKeys: nil,
			options: [.skipsHiddenFiles]
		)

		let bundleDirectories = allFiles.filter { url in
			let attributes = try? fileManager.attributesOfItem(atPath: url.path)
			let isSymlink =
				attributes?[.type] as? FileAttributeType == .typeSymbolicLink
			return url.pathExtension.lowercased() == "bundle"
				&& url.hasDirectoryPath && !isSymlink
		}

		for bundleURL in bundleDirectories {
			_urlsToInject.append(bundleURL)
		}

		let directoriesToSearch = allFiles.filter { url in
			let attributes = try? fileManager.attributesOfItem(atPath: url.path)
			let isSymlink =
				attributes?[.type] as? FileAttributeType == .typeSymbolicLink
			return url.hasDirectoryPath && !bundleDirectories.contains(url)
				&& !isSymlink
		}

		for dirURL in directoriesToSearch {
			try await _searchForBundles(in: dirURL)
		}
	}

	private func _locateDylibFiles(in directory: URL) async throws -> [URL] {
		let fileManager = FileManager.default
		let files = try fileManager.contentsOfDirectory(
			at: directory,
			includingPropertiesForKeys: nil,
			options: []
		)

		let dylibFiles = files.filter { url in
			let attributes = try? fileManager.attributesOfItem(atPath: url.path)
			let isSymlink =
				attributes?[.type] as? FileAttributeType == .typeSymbolicLink
			return url.pathExtension.lowercased() == "dylib" && !isSymlink
		}

		return dylibFiles
	}

	private func _locateFrameworkDirectories(in directory: URL) async throws
		-> [URL]
	{
		let fileManager = FileManager.default
		let files = try fileManager.contentsOfDirectory(
			at: directory,
			includingPropertiesForKeys: nil,
			options: [.skipsHiddenFiles]
		)

		let frameworkDirectories = files.filter { url in
			let attributes = try? fileManager.attributesOfItem(atPath: url.path)
			let isSymlink =
				attributes?[.type] as? FileAttributeType == .typeSymbolicLink
			return url.pathExtension.lowercased() == "framework"
				&& url.hasDirectoryPath && !isSymlink
		}

		return frameworkDirectories
	}
}

enum TweakHandlerError: Error {
	case unsupportedFileExtension(String)
	case decompressionFailed(String)
	case missingFile(String)
	case noAccess
}
