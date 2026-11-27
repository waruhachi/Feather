import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import Zip

struct WorkspaceFilesView: View {
	private static let root = URL.documentsDirectory.appendingPathComponent("Workspace", isDirectory: true)
	var directory: URL = Self.root
	@State private var files: [URL] = []
	@State private var importing = false
	@State private var preview: URL?
	@State private var pendingName: NameAction?
	@State private var deleting: URL?
	@State private var name = ""
	@State private var working = false
	@State private var error: String?

	private enum NameAction {
		case folder, text, rename(URL)
	}

	var body: some View {
		List {
			ForEach(files, id: \.self) { url in
				if url.hasDirectoryPath {
					NavigationLink {
						WorkspaceFilesView(directory: url)
					} label: {
						Label(url.lastPathComponent, systemImage: "folder")
					}
					.contextMenu { actions(for: url) }
				} else {
					Button { preview = url } label: {
						Label(url.lastPathComponent, systemImage: "doc")
					}
					.contextMenu { actions(for: url) }
				}
			}
			if files.isEmpty {
				Text(.localized("No Files")).foregroundStyle(.secondary)
			}
		}
		.navigationTitle(directory == Self.root ? .localized("File Manager") : directory.lastPathComponent)
		.toolbar {
			ToolbarItem(placement: .topBarTrailing) {
				Menu {
					Button(.localized("Import Files"), systemImage: "square.and.arrow.down") { importing = true }
					Button(.localized("New Folder"), systemImage: "folder.badge.plus") { prompt(.folder) }
					Button(.localized("New Text File"), systemImage: "doc.badge.plus") { prompt(.text) }
				} label: {
					Label(.localized("Add"), systemImage: "plus")
				}
			}
		}
		.disabled(working)
		.overlay { if working { ProgressView().padding().background(.regularMaterial, in: Capsule()) } }
		.task { perform { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } }
		.refreshable { perform {} }
		.quickLookPreview($preview)
		.fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
			perform {
				for url in try result.get() {
					let access = url.startAccessingSecurityScopedResource()
					defer { if access { url.stopAccessingSecurityScopedResource() } }
					try FileManager.default.copyItem(at: url, to: child(url.lastPathComponent))
				}
			}
		}
		.alert(.localized("File Name"), isPresented: Binding(get: { pendingName != nil }, set: { if !$0 { pendingName = nil } })) {
			TextField(.localized("Name"), text: $name)
			Button(.localized("Cancel"), role: .cancel) {}
			Button(.localized("Save")) { saveName() }
		}
		.confirmationDialog(.localized("Delete File?"), isPresented: Binding(
			get: { deleting != nil }, set: { if !$0 { deleting = nil } }
		), presenting: deleting) { url in
			Button(.localized("Delete"), role: .destructive) {
				perform { try FileManager.default.removeItem(at: url) }
			}
		} message: { url in
			Text(url.lastPathComponent)
		}
		.alert(.localized("File Error"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
			Button(.localized("OK"), role: .cancel) {}
		} message: {
			Text(error ?? "")
		}
	}

	@ViewBuilder
	private func actions(for url: URL) -> some View {
		ShareLink(item: url)
		Button(.localized("Rename"), systemImage: "pencil") { prompt(.rename(url), initial: url.lastPathComponent) }
		if !url.hasDirectoryPath {
			if url.pathExtension.lowercased() == "plist" {
				NavigationLink(.localized("Edit Property List")) {
					SigningPlistEditor(title: url.lastPathComponent, read: {
						try SigningPlistEditor.dictionary(from: WorkspaceFileEditor.read(url))
					}, save: {
						try SigningPlistEditor.encode($0).write(to: url, options: .atomic)
					})
				}
			}
			if UTType(filenameExtension: url.pathExtension)?.conforms(to: .text) == true || url.pathExtension.isEmpty {
				NavigationLink(.localized("Edit Text")) { WorkspaceFileEditor(url: url, hex: false) }
			}
			NavigationLink(.localized("Edit Hex")) { WorkspaceFileEditor(url: url, hex: true) }
			if ["zip", "ipa", "tipa"].contains(url.pathExtension.lowercased()) {
				Button(.localized("Extract Archive"), systemImage: "archivebox") { archive(url, extract: true) }
			}
			if ["ipa", "tipa"].contains(url.pathExtension.lowercased()) {
				Button(.localized("Import to Library"), systemImage: "square.and.arrow.down") {
					Task {
						do { _ = try await FR.importPackage(url, importOrigin: .localFile) }
						catch { self.error = error.localizedDescription }
					}
				}
			}
		} else if url.pathExtension.lowercased() == "app" {
			Button(.localized("Package as IPA"), systemImage: "archivebox") { archive(url, extract: false) }
		}
		Button(.localized("Delete"), systemImage: "trash", role: .destructive) { deleting = url }
	}

	private func child(_ name: String) throws -> URL {
		guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."), !name.contains("/"),
			!name.contains("\\"), !name.contains("\0")
		else { throw CocoaError(.fileWriteInvalidFileName) }
		return directory.appendingPathComponent(name)
	}

	private func prompt(_ action: NameAction, initial: String = "") {
		name = initial
		pendingName = action
	}

	private func saveName() {
		guard let action = pendingName else { return }
		perform {
			let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
			let target = try child(name)
			switch action {
			case .folder: try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
			case .text: try Data().write(to: name.contains(".") ? target : target.appendingPathExtension("txt"), options: .withoutOverwriting)
			case .rename(let source):
				if source != target { try FileManager.default.moveItem(at: source, to: target) }
			}
		}
	}

	private func perform(_ action: () throws -> Void) {
		do { try action() } catch { self.error = error.localizedDescription }
		do {
			files = try FileManager.default.contentsOfDirectory(
				at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey], options: .skipsHiddenFiles
			).filter {
				(try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
			}.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
		} catch { self.error = error.localizedDescription }
	}

	private func archive(_ url: URL, extract: Bool) {
		working = true
		Task {
			defer { working = false; perform {} }
			do {
				let name = url.deletingPathExtension().lastPathComponent
				let destination = try child(extract ? name : name + ".ipa")
				try await Task.detached(priority: .userInitiated) {
					let manager = FileManager.default
					let staging = self.directory.appendingPathComponent(".workspace-" + UUID().uuidString, isDirectory: true)
					try manager.createDirectory(at: staging, withIntermediateDirectories: false)
					defer { try? manager.removeItem(at: staging) }
					if extract {
						let extracted = staging.appendingPathComponent("Extracted", isDirectory: true)
						try manager.createDirectory(at: extracted, withIntermediateDirectories: false)
						try IPAExtraction.extract(url, to: extracted, control: ImportControl(), progress: { _ in }, maximumExtractedBytes: 8 * 1024 * 1024 * 1024)
						try manager.moveItem(at: extracted, to: destination)
					} else {
						let payload = staging.appendingPathComponent("Payload", isDirectory: true)
						try manager.createDirectory(at: payload, withIntermediateDirectories: false)
						try manager.copyItem(at: url, to: payload.appendingPathComponent(url.lastPathComponent))
						let ipa = staging.appendingPathComponent("Package.ipa")
						try Zip.zipFiles(paths: [payload], zipFilePath: ipa, password: nil, compression: .DefaultCompression, progress: nil)
						try manager.moveItem(at: ipa, to: destination)
					}
				}.value
			} catch { self.error = error.localizedDescription }
		}
	}
}

private struct WorkspaceFileEditor: View {
	@Environment(\.dismiss) private var dismiss
	let url: URL
	let hex: Bool
	@State private var text = ""
	@State private var loaded = false
	@State private var error: String?

	var body: some View {
		Form {
			TextEditor(text: $text)
				.font(.system(.body, design: .monospaced))
				.autocorrectionDisabled()
				.textInputAutocapitalization(.never)
				.frame(minHeight: 320)
			if let error { Text(error).foregroundStyle(.red) }
		}
		.navigationTitle(url.lastPathComponent)
		.toolbar {
			Button(.localized("Save")) {
				do {
					try editedData().write(to: url, options: .atomic)
					dismiss()
				} catch { self.error = error.localizedDescription }
			}
			.disabled(!loaded)
		}
		.task {
			guard !loaded else { return }
			do {
				let data = try Self.read(url)
				if hex {
					text = data.map { String(format: "%02X", $0) }.joined(separator: " ")
				} else {
					guard let value = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
					text = value
				}
				loaded = true
			} catch { self.error = error.localizedDescription }
		}
	}

	static func read(_ url: URL) throws -> Data {
		let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
		guard size <= 512 * 1024 else { throw CocoaError(.fileReadTooLarge) }
		return try Data(contentsOf: url)
	}

	private func editedData() throws -> Data {
		guard hex else { return Data(text.utf8) }
		let chars = text.filter { !$0.isWhitespace }
		guard chars.utf8.count <= 1024 * 1024, chars.count.isMultiple(of: 2) else { throw CocoaError(.fileWriteUnknown) }
		var data = Data()
		var cursor = chars.startIndex
		while cursor < chars.endIndex {
			let end = chars.index(cursor, offsetBy: 2)
			guard let byte = UInt8(chars[cursor..<end], radix: 16) else { throw CocoaError(.fileWriteUnknown) }
			data.append(byte)
			cursor = end
		}
		return data
	}
}
