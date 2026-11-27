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
#endif
