//
//  ExtractDylibView.swift
//  Feather
//
//  Created by GitHub Copilot on 2025.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - View
struct ExtractDylibView: View {
	@State private var _dylibs: [URL] = []
	@State private var _isLoading: Bool = true
	@State private var _errorMessage: String?
	
	var app: AppInfoPresentable
	
	var body: some View {
		NBList(.localized("Extract Dylibs"), type: .list) {
			if _isLoading {
				Section {
					HStack {
						Spacer()
						ProgressView()
						Spacer()
					}
				}
			} else if let errorMessage = _errorMessage {
				NBSection("Error") {
					Text(errorMessage)
						.font(.footnote)
						.foregroundColor(.red)
				}
			} else if _dylibs.isEmpty {
				NBSection("Status") {
					Text(.localized("No injected dylibs found."))
						.font(.footnote)
						.foregroundColor(.disabled())
				}
			} else {
				Section {
					ForEach(_dylibs, id: \.self) { dylibURL in
						HStack {
							Text(dylibURL.lastPathComponent)
								.font(.system(.body, design: .monospaced))
							
							Spacer()
							
							Button {
								_shareDylib(dylibURL)
							} label: {
								Image(systemName: "square.and.arrow.up")
									.foregroundColor(.accentColor)
							}
							.buttonStyle(.plain)
						}
					}
				}
			}
		}
		.onAppear(perform: _loadDylibs)
	}
}

// MARK: - Extension: View
extension ExtractDylibView {
	private func _loadDylibs() {
		Task {
			_isLoading = true
			_errorMessage = nil
			
			guard let appPath = Storage.shared.getAppDirectory(for: app) else {
				_errorMessage = "App directory not found."
				_isLoading = false
				return
			}
			
			do {
				let handler = TweakHandler(app: appPath)
				let extractedDylibs = try await handler.extractDylibs(from: appPath)
				
				await MainActor.run {
					_dylibs = extractedDylibs
					_isLoading = false
				}
			} catch {
				await MainActor.run {
					_errorMessage = "Failed to extract dylibs: \(error.localizedDescription)"
					_isLoading = false
				}
			}
		}
	}
	
	private func _shareDylib(_ url: URL) {
		UIActivityViewController.show(
			activityItems: [url]
		)
	}
}
