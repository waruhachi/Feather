import NimbleViews
import SwiftUI
import UniformTypeIdentifiers
import Zsign

enum TweakLibrary {
	static var directory: URL { URL.applicationSupportDirectory.appendingPathComponent("FeatherTweaks", isDirectory: true) }
	static let extensions = ["dylib", "deb", "framework", "bundle", "appex"]
	private static let metadataFile = ".tweak.json"

	struct Metadata: Codable, Equatable {
		var folder = ""
		var notes = ""
		var enabled = true
		var injection = TweakInjectionRule()
		var catalogURL: URL?
	}

	static func files(in root: URL = directory) -> [URL] {
		let manager = FileManager.default
		let entries = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
		return entries.flatMap { item -> [URL] in
			guard (try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true else { return [] }
			let files = (try? manager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
			return files.filter { extensions.contains($0.pathExtension.lowercased()) }
		}.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
	}

	static func metadata(for file: URL) -> Metadata {
		let url = file.deletingLastPathComponent().appendingPathComponent(metadataFile)
		return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Metadata.self, from: $0) } ?? Metadata()
	}

	static func save(_ metadata: Metadata, for file: URL) throws {
		try JSONEncoder().encode(metadata).write(
			to: file.deletingLastPathComponent().appendingPathComponent(metadataFile), options: .atomic
		)
	}

	@discardableResult
	static func add(_ file: URL, metadata: Metadata = Metadata()) throws -> URL {
		guard extensions.contains(file.pathExtension.lowercased()) else { throw CocoaError(.fileReadUnsupportedScheme) }
		let access = file.startAccessingSecurityScopedResource()
		defer { if access { file.stopAccessingSecurityScopedResource() } }
		let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let destination = folder.appendingPathComponent(file.lastPathComponent)
		let manager = FileManager.default
		try manager.createDirectoryIfNeeded(at: folder)
		do {
			try manager.copyItem(at: file, to: destination)
			try save(metadata, for: destination)
		} catch {
			try? manager.removeItem(at: folder)
			throw error
		}
		return destination
	}

	static func remove(_ file: URL) throws {
		try FileManager.default.removeItem(at: file.deletingLastPathComponent())
	}
}

struct TweakLibraryView: View {
	@State private var files: [URL] = []
	@State private var importing = false
	@State private var error: String?
	@State private var search = ""
	@State private var importFolder: String?
	@State private var newFolder = ""
	@State private var askingFolder = false
	var onSelect: (([URL]) -> Void)? = nil

	private var groups: [String: [URL]] {
		Dictionary(grouping: files.filter { file in
			search.isEmpty || file.lastPathComponent.localizedCaseInsensitiveContains(search)
				|| TweakLibrary.metadata(for: file).folder.localizedCaseInsensitiveContains(search)
		}, by: { TweakLibrary.metadata(for: $0).folder })
	}

	var body: some View {
		NBList(.localized("Tweak Manager")) {
			if onSelect == nil {
				NavigationLink(.localized("Tweak Catalog")) { TweakCatalogView() }
			}
			ForEach(groups.keys.sorted(), id: \.self) { folder in
				let members = groups[folder] ?? []
				if folder.isEmpty {
					ForEach(members, id: \.self, content: row)
				} else {
					NavigationLink {
						List {
							if let onSelect {
								let enabled = members.filter { TweakLibrary.metadata(for: $0).enabled }
								Button(.localized("Add Enabled Tweaks")) { onSelect(enabled) }.disabled(enabled.isEmpty)
							}
							ForEach(members, id: \.self, content: row)
						}
						.navigationTitle(folder)
						.toolbar {
							Button(.localized("Import"), systemImage: "plus") {
								importFolder = folder
								importing = true
							}
						}
					} label: {
						LabeledContent {
							Text(members.count.formatted())
						} label: {
							Label(folder, systemImage: "folder")
						}
					}
				}
			}
			if files.isEmpty { Text(.localized("No files chosen.")).foregroundStyle(.secondary) }
		}
		.searchable(text: $search)
		.toolbar {
			ToolbarItem(placement: .primaryAction) {
				Menu {
					Button(.localized("Import Tweaks")) { importFolder = nil; importing = true }
					Button(.localized("Import Into New Folder")) { newFolder = ""; askingFolder = true }
				} label: {
					Label(.localized("Import"), systemImage: "plus")
				}
			}
		}
		.alert(.localized("New Tweak Folder"), isPresented: $askingFolder) {
			TextField(.localized("Name"), text: $newFolder)
			Button(.localized("Cancel"), role: .cancel) {}
			Button(.localized("Continue")) { importFolder = newFolder; importing = true }
				.disabled(newFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
		}
		.sheet(isPresented: $importing) {
			FileImporterRepresentableView(
				allowedContentTypes: [.dylib, .deb, .framework, .appex, .init(filenameExtension: "bundle") ?? .package],
				allowsMultipleSelection: true,
				onDocumentsPicked: { urls in
					for url in urls {
						do { try TweakLibrary.add(url, metadata: .init(folder: importFolder ?? "")) }
						catch { self.error = error.localizedDescription }
					}
					files = TweakLibrary.files()
				}
			)
			.ignoresSafeArea()
		}
		.alert(.localized("Error"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
			Button(.localized("OK"), role: .cancel) { error = nil }
		} message: {
			Text(error ?? "")
		}
		.onAppear { files = TweakLibrary.files() }
	}

	@ViewBuilder private func row(_ file: URL) -> some View {
		if let onSelect {
			Button(file.lastPathComponent) { onSelect([file]) }.disabled(!TweakLibrary.metadata(for: file).enabled)
		} else {
			NavigationLink(file.lastPathComponent) {
				TweakLibraryDetailView(file: file) {
					files = TweakLibrary.files()
					error = $0?.localizedDescription
				}
			}
			.swipeActions(allowsFullSwipe: false) {
				Button(.localized("Delete"), role: .destructive) {
					do { try TweakLibrary.remove(file) } catch { self.error = error.localizedDescription }
					files = TweakLibrary.files()
				}
			}
		}
	}
}

private struct TweakLibraryDetailView: View {
	let file: URL
	let didSave: (Error?) -> Void
	@State private var metadata = TweakLibrary.Metadata()

	var body: some View {
		Form {
			LabeledContent(.localized("Name"), value: file.lastPathComponent)
			LabeledContent(.localized("Type"), value: file.pathExtension)
			TextField(.localized("Folder"), text: $metadata.folder)
			TextField(.localized("Notes"), text: $metadata.notes)
			Toggle(.localized("Enabled"), isOn: $metadata.enabled)
			if !["appex", "bundle"].contains(file.pathExtension.lowercased()) {
				Section(.localized("Injection")) { TweakInjectionRuleFields(rule: $metadata.injection) }
			}
			if let executable = Bundle(url: file)?.executableURL ?? (file.pathExtension == "dylib" ? file : nil) {
				let dependencies = Array(Set(Zsign.listDylibs(appExecutable: executable.path))).sorted()
				Section(.localized("Dependencies")) { ForEach(dependencies, id: \.self) { Text($0) } }
			}
			ShareLink(item: file)
		}
		.navigationTitle(.localized("Tweak Info"))
		.toolbar {
			Button(.localized("Save")) {
				metadata.folder = metadata.folder.trimmingCharacters(in: .whitespacesAndNewlines)
				do { try TweakLibrary.save(metadata, for: file); didSave(nil) }
				catch { didSave(error) }
			}
		}
		.onAppear { metadata = TweakLibrary.metadata(for: file) }
	}
}

struct TweakInjectionRuleFields: View {
	@Binding var rule: TweakInjectionRule
	var body: some View {
		Picker(.localized("Injection Path"), selection: $rule.path) {
			Text(.localized("Use Signing Defaults")).tag(Optional<Options.InjectPath>.none)
			ForEach(Options.InjectPath.allCases, id: \.self) { Text($0.localizedDescription).tag(Optional($0)) }
		}
		Picker(.localized("Injection Folder"), selection: $rule.folder) {
			Text(.localized("Use Signing Defaults")).tag(Optional<Options.InjectFolder>.none)
			ForEach(Options.InjectFolder.allCases, id: \.self) { Text($0.localizedDescription).tag(Optional($0)) }
		}
		Picker(.localized("Targets"), selection: $rule.target) {
			ForEach(TweakInjectionRule.Target.allCases, id: \.self) { Text(.localized($0.rawValue)).tag($0) }
		}
		Toggle(.localized("Weak Injection"), isOn: $rule.weak)
	}
}
