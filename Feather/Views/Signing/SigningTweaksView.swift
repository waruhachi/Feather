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
	@State private var _libraryPresenting = false

	@Binding var options: Options
	var bundleIdentifier: String? = nil

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

			Button(.localized("Choose from Tweak Manager"), systemImage: "shippingbox") {
				_libraryPresenting = true
			}
			if let bundleIdentifier {
				NavigationLink(.localized("Suggested Tweaks")) {
					TweakCatalogView(bundleIdentifier: bundleIdentifier, onSelect: addLibraryTweaks)
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
		.sheet(isPresented: $_libraryPresenting) {
			NBNavigationView(.localized("Tweak Manager"), displayMode: .inline) {
				TweakLibraryView { files in
					addLibraryTweaks(files)
					_libraryPresenting = false
				}
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
	private func addLibraryTweaks(_ files: [URL]) {
		for url in files {
			let isExtension = url.pathExtension.lowercased() == "appex"
			FileManager.default.moveAndStore(url, with: isExtension ? "FeatherExtension" : "FeatherTweak") { copy in
				guard FileManager.default.fileExists(atPath: copy.path) else { return }
				if isExtension {
					options.injectedAppExtensions.append(copy)
				} else {
					options.injectionFiles.append(copy)
					if options.tweakInjectionRules == nil { options.tweakInjectionRules = [:] }
					options.tweakInjectionRules?[copy.absoluteString] = TweakLibrary.metadata(for: url).injection
				}
			}
		}
	}

	@ViewBuilder
	private func _file(tweak: URL) -> some View {
		NavigationLink {
			Form {
				TweakInjectionRuleFields(rule: Binding(
					get: { options.tweakInjectionRules?[tweak.absoluteString] ?? TweakInjectionRule() },
					set: { rule in
						if options.tweakInjectionRules == nil { options.tweakInjectionRules = [:] }
						options.tweakInjectionRules?[tweak.absoluteString] = rule
					}
				))
			}
			.navigationTitle(tweak.lastPathComponent)
		} label: {
			Label(tweak.lastPathComponent, systemImage: _fileSystemImage(for: tweak))
		}
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
			if SigningRecipe.owns(tweak) {
				removeFromSigningOptions(tweak)
			} else {
				FileManager.default.deleteStored(tweak, completion: removeFromSigningOptions)
			}
		} label: {
			Label(SigningRecipe.owns(tweak) ? .localized("Remove from Signing") : .localized("Delete"), systemImage: "trash")
		}
	}

	private func removeFromSigningOptions(_ url: URL) {
		options.injectionFiles.removeAll { $0 == url }
		options.tweakInjectionRules?.removeValue(forKey: url.absoluteString)
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
