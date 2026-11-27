//
//  SigningEntitlementsView.swift
//  Feather
//
//  Created by samara on 20.04.2025.
//

import SwiftUI
import NimbleViews

struct SigningEntitlementsView: View {
	@State private var isImporting = false
	@State private var isNamingPreset = false
	@State private var presetName = ""
	@State private var presets: [URL] = []
	@State private var error: String?
	var executable: URL? = nil
	@Binding var bindingValue: URL?

	private var presetsDirectory: URL {
		URL.applicationSupportDirectory.appendingPathComponent("EntitlementPresets", isDirectory: true)
	}

	var body: some View {
		NBList(.localized("Entitlements")) {
			Section {
				NavigationLink(.localized("Edit Entitlements")) {
					SigningPlistEditor(
						title: .localized("Entitlements"),
						read: readEntitlements,
						save: apply
					)
				}
				Button(.localized("Select entitlements file")) { isImporting = true }
				if let entitlements = bindingValue {
					Text(entitlements.lastPathComponent)
						.swipeActions {
							Button(.localized("Remove"), role: .destructive) {
								let directory = entitlements.deletingLastPathComponent()
								if directory.lastPathComponent.hasPrefix("FeatherEntitlement_") {
									try? FileManager.default.removeItem(at: directory)
								}
								bindingValue = nil
							}
						}
				}
			}

			Section(.localized("Presets")) {
				Button(.localized("Save Current Entitlements as Preset")) {
					presetName = ""
					isNamingPreset = true
				}
				ForEach(presets, id: \.self) { preset in
					Button(preset.deletingPathExtension().lastPathComponent) {
						perform { try apply(SigningPlistEditor.dictionary(from: Data(contentsOf: preset))) }
					}
					.swipeActions(allowsFullSwipe: false) {
						Button(.localized("Delete"), role: .destructive) {
							perform {
								try FileManager.default.removeItem(at: preset)
								loadPresets()
							}
						}
					}
					.contextMenu {
						ShareLink(item: preset)
					}
				}
			}
		}
		.task { loadPresets() }
		.alert(.localized("Preset Name"), isPresented: $isNamingPreset) {
			TextField(.localized("Name"), text: $presetName)
			Button(.localized("Save")) { perform(savePreset) }
			Button(.localized("Cancel"), role: .cancel) {}
		}
		.alert(.localized("Entitlements"), isPresented: Binding(
			get: { error != nil },
			set: { if !$0 { error = nil } }
		)) {
			Button(.localized("OK"), role: .cancel) {}
		} message: {
			Text(error ?? "")
		}
		.sheet(isPresented: $isImporting) {
			FileImporterRepresentableView(
				allowedContentTypes: [.xmlPropertyList, .plist, .entitlements],
				onDocumentsPicked: { urls in
					guard let selected = urls.first else { return }
					let accessed = selected.startAccessingSecurityScopedResource()
					defer { if accessed { selected.stopAccessingSecurityScopedResource() } }
					perform { try apply(SigningPlistEditor.dictionary(from: Data(contentsOf: selected))) }
				}
			)
			.ignoresSafeArea()
		}
	}

	private func readEntitlements() throws -> [String: Any] {
		if let file = bindingValue {
			return try SigningPlistEditor.dictionary(from: Data(contentsOf: file))
		}
		return executable.flatMap(MachOEntitlements.read(forExecutableAt:)) ?? [:]
	}

	private func apply(_ dictionary: [String: Any]) throws {
		let data = try SigningPlistEditor.encode(dictionary)
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FeatherEntitlement_\(UUID().uuidString)")
		try FileManager.default.createDirectoryIfNeeded(at: directory)
		let file = directory.appendingPathComponent("Entitlements.plist")
		try data.write(to: file, options: .atomic)
		if let old = bindingValue?.deletingLastPathComponent(), old.lastPathComponent.hasPrefix("FeatherEntitlement_") {
			try? FileManager.default.removeItem(at: old)
		}
		bindingValue = file
	}

	private func loadPresets() {
		let files = (try? FileManager.default.contentsOfDirectory(
			at: presetsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
		)) ?? []
		presets = files.filter { $0.pathExtension == "plist" }
			.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
	}

	private func savePreset() throws {
		let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":"), name.utf8.count <= 120 else {
			throw CocoaError(.fileWriteInvalidFileName)
		}
		let data = try SigningPlistEditor.encode(readEntitlements())
		try FileManager.default.createDirectoryIfNeeded(at: presetsDirectory)
		let file = presetsDirectory.appendingPathComponent(name).appendingPathExtension("plist")
		guard !FileManager.default.fileExists(atPath: file.path) else {
			throw CocoaError(.fileWriteFileExists)
		}
		try data.write(to: file, options: .atomic)
		loadPresets()
	}

	private func perform(_ action: () throws -> Void) {
		do { try action() }
		catch { self.error = error.localizedDescription }
	}
}
