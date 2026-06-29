//
//  SigningTweaksView.swift
//  Feather
//
//  Created by samara on 20.04.2025.
//

import NimbleViews
import SwiftUI

// MARK: - View
struct SigningTweaksView: View {
	@State private var _isAddingPresenting = false

	@Binding var options: Options

	// MARK: Body
	var body: some View {
		NBList(.localized("Tweaks")) {
			NBSection(.localized("Injection")) {
				SigningOptionsView.picker(
					.localized("Injection Path"),
					systemImage: "doc.badge.gearshape",
					selection: $options.injectPath,
					values: Options.InjectPath.allCases
				)
				SigningOptionsView.picker(
					.localized("Injection Folder"),
					systemImage: "folder.badge.gearshape",
					selection: $options.injectFolder,
					values: Options.InjectFolder.allCases
				)

				Toggle(isOn: $options.injectIntoExtensions) {
					Label(
						.localized("Inject into Extensions"),
						systemImage: "syringe"
					)
				}
			}

			NBSection(.localized("Tweaks")) {
				if !options.injectionFiles.isEmpty {
					ForEach(options.injectionFiles, id: \.absoluteString) {
						tweak in
						_file(tweak: tweak)
					}
				} else {
					Text(verbatim: .localized("No files chosen."))
						.font(.footnote)
						.foregroundColor(.disabled())
				}
			}
		}
		.toolbar {
			NBToolbarButton(
				systemImage: "plus",
				style: .icon,
				placement: .topBarTrailing
			) {
				_isAddingPresenting = true
			}
		}
		.sheet(isPresented: $_isAddingPresenting) {
			FileImporterRepresentableView(
				allowedContentTypes: [.dylib, .deb, .framework],
				allowsMultipleSelection: true,
				onDocumentsPicked: { urls in
					guard !urls.isEmpty else { return }

					for url in urls {
						let ext = url.pathExtension.lowercased()
						guard ["dylib", "deb", "framework"].contains(ext) else {
							continue
						}
						FileManager.default.moveAndStore(
							url,
							with: "FeatherTweak"
						) { url in
							options.injectionFiles.append(url)
						}
					}
				}
			)
			.ignoresSafeArea()
		}
		.animation(.smooth, value: options.injectionFiles)
	}
}

// MARK: - Extension: View
extension SigningTweaksView {
	@ViewBuilder
	private func _file(tweak: URL) -> some View {
		Label(
			tweak.lastPathComponent,
			systemImage: _fileSystemImage(for: tweak)
		)
		.lineLimit(2)
		.frame(maxWidth: .infinity, alignment: .leading)
		.swipeActions(edge: .trailing, allowsFullSwipe: true) {
			_fileActions(tweak: tweak)
		}
		.contextMenu {
			_fileActions(tweak: tweak)
		}
	}

	@ViewBuilder
	private func _fileActions(tweak: URL) -> some View {
		Button(role: .destructive) {
			FileManager.default.deleteStored(tweak) { url in
				if let index = options.injectionFiles.firstIndex(where: {
					$0 == url
				}) {
					options.injectionFiles.remove(at: index)
				}
			}
		} label: {
			Label(.localized("Delete"), systemImage: "trash")
		}
	}

	private func _fileSystemImage(for url: URL) -> String {
		switch url.pathExtension.lowercased() {
		case "framework":
			"shippingbox"
		case "deb":
			"archivebox"
		default:
			"doc.badge.gearshape"
		}
	}
}
