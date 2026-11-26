//
//  SigningEntitlementsView.swift
//  Feather
//
//  Created by samara on 20.04.2025.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct SigningEntitlementsView: View {
	@State private var _isAddingPresenting = false
	var executable: URL? = nil
	
	@Binding var bindingValue: URL?
	
	// MARK: Body
	var body: some View {
		NBList(.localized("Entitlements")) {
			NavigationLink(.localized("Edit Entitlements")) {
				SigningPlistEditor(
					title: .localized("Entitlements"),
					read: {
						if let file = bindingValue {
							return try SigningPlistEditor.dictionary(from: Data(contentsOf: file))
						}
						return executable.flatMap(MachOEntitlements.read(forExecutableAt:)) ?? [:]
					},
					save: { dictionary in
						let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FeatherEntitlement_\(UUID().uuidString)")
						try FileManager.default.createDirectoryIfNeeded(at: directory)
						let file = directory.appendingPathComponent("Entitlements.plist")
						try SigningPlistEditor.encode(dictionary).write(to: file, options: .atomic)
						bindingValue = file
					}
				)
			}
			if let ent = bindingValue {
				Text(ent.lastPathComponent)
					.swipeActions() {
						Button(.localized("Delete")) {
							FileManager.default.deleteStored(ent) { _ in
								bindingValue = nil
							}
						}
					}
			} else {
				Button(.localized("Select entitlements file")) {
					_isAddingPresenting = true
				}
			}
		}
		.sheet(isPresented: $_isAddingPresenting) {
			FileImporterRepresentableView(
				allowedContentTypes:  [.xmlPropertyList, .plist, .entitlements],
				onDocumentsPicked: { urls in
					guard let selectedFileURL = urls.first else { return }
					
					FileManager.default.moveAndStore(selectedFileURL, with: "FeatherEntitlement") { url in
						bindingValue = url
					}
				}
			)
			.ignoresSafeArea()
		}
	}
}
