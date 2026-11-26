//
//  ServerView.swift
//  Feather
//
//  Created by samara on 6.05.2025.
//

import SwiftUI

struct ServerView: View {
	@Environment(\.scenePhase) private var scenePhase
	@AppStorage("Feather.ipFix") private var _ipFix = false
	@AppStorage("Feather.serverMethod") private var _serverMethod: Int = 0
	@AppStorage(LocalCertificate.enabledKey) private var useOnDeviceCertificate = false
	@State private var isTrusted = false
	@State private var isRefreshing = false
	@State private var message: String?

	private let _serverMethods: [String] = [.localized("Fully Local"), .localized("Semi Local")]

	var body: some View {
		Group {
			Section {
				Picker(.localized("Server Type"), systemImage: "server.rack", selection: $_serverMethod) {
					ForEach(_serverMethods.indices, id: \.description) { index in
						Text(_serverMethods[index]).tag(index)
					}
				}
				Toggle(.localized("Only use localhost address"), systemImage: "lifepreserver", isOn: $_ipFix)
					.disabled(_serverMethod != 1)
			}

			if _serverMethod == 0 {
				Section {
					#if os(iOS) && !targetEnvironment(macCatalyst)
					Picker(.localized("TLS Certificate"), systemImage: "lock.shield", selection: $useOnDeviceCertificate) {
						Text(.localized("Public Certificate")).tag(false)
						Text(.localized("On Device")).tag(true)
					}
					if useOnDeviceCertificate {
						LabeledContent(.localized("Status"), value: String.localized(isTrusted ? "Trusted" : "Not Trusted"))
						Button(.localized("Install Feather Profile"), systemImage: "arrow.down.doc") {
							do { try LocalCertificateProfileServer.open() }
							catch { message = error.localizedDescription }
						}
					} else {
						updateButton
					}
					#else
					updateButton
					#endif
				} footer: {
					#if os(iOS) && !targetEnvironment(macCatalyst)
					if useOnDeviceCertificate {
						Text(.localized("Once the profile is installed, enable full trust in iOS Settings › General › About › Certificate Trust Settings."))
					}
					#endif
				}
			}
		}
		.task(id: useOnDeviceCertificate) { await refreshTrust() }
		.onChange(of: scenePhase) { phase in
			if phase == .active { Task { await refreshTrust() } }
		}
		.alert(.localized("SSL Certificates"), isPresented: Binding(
			get: { message != nil }, set: { if !$0 { message = nil } }
		)) {
			Button(.localized("OK"), role: .cancel) {}
		} message: {
			Text(message ?? "")
		}
	}

	private var updateButton: some View {
		Button(.localized("Update SSL Certificates"), systemImage: "arrow.down.doc") {
			isRefreshing = true
			Task {
				defer { isRefreshing = false }
				do {
					try await InstallTLSCertificates.shared.refresh()
					message = .localized("Certificates updated successfully.")
				} catch { message = error.localizedDescription }
			}
		}
		.disabled(isRefreshing)
	}

	private func refreshTrust() async {
		guard LocalCertificate.isEnabled else { return }
		let trusted = await Task.detached(priority: .utility) { LocalCertificate.isTrusted }.value
		if !Task.isCancelled { isTrusted = trusted }
	}
}
