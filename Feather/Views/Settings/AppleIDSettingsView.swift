#if os(iOS) && !targetEnvironment(macCatalyst)
import SwiftUI

struct AppleIDSettingsView: View {
	@ObservedObject private var provisioning = AppleIDProvisioning.shared
	@AppStorage(AppleIDProvisioning.deviceKey) private var udid = ""
	@AppStorage(AppleIDProvisioning.serverKey) private var server = AppleIDProvisioning.defaultServer
	@State private var email = ""
	@State private var password = ""
	@State private var error: String?

	var body: some View {
		Form {
			Section {
				if let account = provisioning.account {
					Text(account.authentication.account.appleID)
					if provisioning.teams.count > 1 {
						Picker(.localized("Developer Team"), selection: Binding(
							get: { provisioning.account?.teamID ?? account.teamID },
							set: { choice in
								do { try provisioning.selectTeam(choice) } catch { self.error = error.localizedDescription }
							}
						)) {
							ForEach(provisioning.teams, id: \.identifier) { team in
								Text(team.name).tag(team.identifier)
							}
						}
					} else {
						LabeledContent(.localized("Developer Team"), value: account.teamName)
					}
					NavigationLink(.localized("Developer Certificates")) {
					AppleIDCertificatesView()
				}
				Button(.localized("Sign Out"), role: .destructive) {
						do { try provisioning.signOut() } catch { self.error = error.localizedDescription }
					}
				}
				TextField(.localized("Apple ID"), text: $email)
					.keyboardType(.emailAddress).textContentType(.username)
					.textInputAutocapitalization(.never).autocorrectionDisabled()
				SecureField(.localized("Password"), text: $password).textContentType(.password)
				Button(.localized("Sign In")) {
					let credential = password
					password = ""
					Task {
						do { try await provisioning.signIn(email: email, password: credential, serverAddress: server) }
						catch is CancellationError {} catch { self.error = error.localizedDescription }
					}
				}
				.disabled(email.isEmpty || password.isEmpty)
				if provisioning.working { ProgressView() }
			} footer: {
				Text(.localized("Use Apple ID in the signing sheet to create a development profile for that app. The session is stored in Keychain. Feather does not store your password."))
			}
			Section {
				TextField(.localized("Device UDID"), text: $udid).textInputAutocapitalization(.never).autocorrectionDisabled()
				TextField(.localized("Anisette Server"), text: $server).keyboardType(.URL)
					.textInputAutocapitalization(.never).autocorrectionDisabled()
			} footer: {
				Text(.localized("Leave Device UDID empty to use the pairing file. The anisette server supplies device authentication data for Apple sign-in."))
			}
			if let error { Text(error).foregroundStyle(.red) }
		}
		.disabled(provisioning.working)
		.navigationTitle(.localized("Apple ID"))
	}
}

private struct AppleIDCertificatesView: View {
	@ObservedObject private var provisioning = AppleIDProvisioning.shared
	@State private var certificates: [AppleIDProvisioning.DeveloperCertificate] = []
	@State private var selected: AppleIDProvisioning.DeveloperCertificate?
	@State private var error: String?
	@State private var loaded = false

	var body: some View {
		List {
			if provisioning.working {
				ProgressView()
			} else if loaded && certificates.isEmpty {
				Text(.localized("No developer certificates"))
			}
			if let error { Text(error).foregroundStyle(.red) }
			ForEach(certificates) { certificate in
				VStack(alignment: .leading) {
					Text(certificate.name)
					Text(certificate.id).font(.caption.monospaced()).foregroundStyle(.secondary)
					if certificate.expires != .distantPast {
						Text(certificate.expires, style: .date).font(.caption)
					}
					if certificate.isCurrent {
						Text(.localized("Used by Feather")).font(.caption).foregroundStyle(.secondary)
					}
				}
				.swipeActions(allowsFullSwipe: false) {
					Button(.localized("Revoke"), role: .destructive) { selected = certificate }
						.disabled(provisioning.working)
				}
				.contextMenu {
					Button(.localized("Revoke"), role: .destructive) { selected = certificate }
						.disabled(provisioning.working)
				}
			}
		}
		.navigationTitle(.localized("Developer Certificates"))
		.task { await refresh() }
		.refreshable { await refresh() }
		.confirmationDialog(.localized("Revoke Developer Certificate?"), isPresented: Binding(
			get: { selected != nil },
			set: { if !$0 { selected = nil } }
		), presenting: selected) { certificate in
			Button(.localized("Revoke"), role: .destructive) { Task { await revoke(certificate) } }
		} message: { certificate in
			Text(verbatim: .localized("Apps signed with %@ may stop working.", arguments: certificate.name))
		}
	}

	private func refresh() async {
		guard !provisioning.working else { return }
		do {
			certificates = try await provisioning.developerCertificates()
			loaded = true
			error = nil
		} catch is CancellationError {
		} catch {
			self.error = error.localizedDescription
		}
	}

	private func revoke(_ certificate: AppleIDProvisioning.DeveloperCertificate) async {
		do {
			try await provisioning.revokeDeveloperCertificate(certificate)
			certificates.removeAll { $0.id == certificate.id }
			await refresh()
		} catch {
			self.error = error.localizedDescription
		}
	}
}
#endif
