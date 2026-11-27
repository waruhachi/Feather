import CoreData
import SwiftUI

struct AccretionStoreView: View {
	@ObservedObject private var service = AccretionService.shared
	@State private var listings: [AccretionService.Listing] = []
	@State private var search = ""
	@State private var loading = false
	@State private var error: String?

	private var visible: [AccretionService.Listing] {
		let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
		let matches = text.isEmpty ? listings : listings.filter {
			$0.n.localizedCaseInsensitiveContains(text) || $0.d.localizedCaseInsensitiveContains(text) || $0.i.localizedCaseInsensitiveContains(text)
		}
		return Array(matches.prefix(150))
	}

	var body: some View {
		List {
			Section {
				NavigationLink(.localized("Accretion Account")) { AccretionAccountView() }
				Link(.localized("Open Accretion Website"), destination: AccretionService.website)
			}
			if loading { ProgressView() }
			if let error { Text(error) }
			Section {
				ForEach(visible) { listing in
					NavigationLink {
						AccretionListingView(listing: listing)
					} label: {
						VStack(alignment: .leading) {
							Text(listing.n)
							Text(listing.d + " · " + listing.v).font(.caption).foregroundStyle(.secondary)
						}
					}
				}
			} footer: {
				if search.isEmpty, listings.count > visible.count {
					Text(.localized("Search to find more apps in the catalog."))
				}
			}
		}
		.navigationTitle(.localized("Accretion Store"))
		.searchable(text: $search)
		.task { await load() }
		.refreshable { await load() }
	}

	private func load() async {
		guard !loading else { return }
		loading = true
		defer { loading = false }
		do {
			listings = try await service.listings()
			error = nil
		} catch is CancellationError {
		} catch {
			self.error = error.localizedDescription
		}
	}
}

private struct AccretionListingView: View {
	let listing: AccretionService.Listing
	@ObservedObject private var service = AccretionService.shared
	@State private var builds: [AccretionService.Build] = []
	@State private var loading = true
	@State private var downloading: String?
	@State private var report: String?

	var body: some View {
		Form {
			Section {
				LabeledContent(.localized("Developer"), value: listing.d)
				LabeledContent(.localized("Bundle Identifier"), value: listing.i)
				Link(.localized("Open Store Listing"), destination: listing.webURL)
			}
			if loading { ProgressView() }
			if !loading && builds.isEmpty {
				Text(.localized("No downloadable versions are available for this listing."))
			}
			if let report { Text(report) }
			if !builds.isEmpty {
				Section(.localized("Downloads")) {
					if service.email == nil {
						NavigationLink(.localized("Sign In to Download")) { AccretionAccountView() }
					}
					ForEach(builds) { build in
						Button(build.v, systemImage: "arrow.down.circle") {
							Task { await download(build) }
						}
						.disabled(service.email == nil || downloading != nil)
						if downloading == build.id { ProgressView() }
						if let notes = build.notes, !notes.isEmpty {
							Text(notes).font(.caption).foregroundStyle(.secondary)
						}
					}
				}
			}
		}
		.navigationTitle(listing.n)
		.task {
			defer { loading = false }
			guard listing.tw != 1 else { return }
			do { builds = try await service.versions(for: listing) }
			catch is CancellationError {}
			catch { report = error.localizedDescription }
		}
	}

	private func download(_ build: AccretionService.Build) async {
		guard downloading == nil else { return }
		downloading = build.id
		defer { downloading = nil }
		do {
			let uuid = try await service.importBuild(build, for: listing)
			ImportSigning.enqueue(uuid)
			report = .localized("Added to Library")
		} catch is CancellationError {
		} catch {
			report = error.localizedDescription
		}
	}
}

struct AccretionAccountView: View {
	@ObservedObject private var service = AccretionService.shared
	@FetchRequest(sortDescriptors: [NSSortDescriptor(key: "date", ascending: false)])
	private var certificates: FetchedResults<CertificatePair>
	@State private var email = ""
	@State private var password = ""
	@State private var passphrase = ""
	@State private var certificateID = ""
	@State private var backups: [AccretionService.Backup] = []
	@State private var deleting: AccretionService.Backup?
	@State private var working = false
	@State private var report: String?

	var body: some View {
		Form {
			Section {
				if let account = service.email {
					LabeledContent(.localized("Account"), value: account)
					Button(.localized("Sign Out"), role: .destructive) {
						service.signOut()
						passphrase = ""
						backups = []
					}
				} else {
					TextField(.localized("Accretion Email"), text: $email)
						.keyboardType(.emailAddress).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
					SecureField(.localized("Accretion Password"), text: $password).textContentType(.password)
					Button(.localized("Sign In")) {
						let secret = password
						password = ""
						run {
							try await service.signIn(email: email, password: secret)
							backups = try await service.backups()
						}
					}
					.disabled(email.isEmpty || password.isEmpty)
					Link(.localized("Manage Account on Accretion"), destination: AccretionService.website)
				}
			}
			if working { ProgressView() }
			if let report { Text(report) }
			if service.email != nil {
				Section {
					SecureField(.localized("Backup Passphrase"), text: $passphrase)
					Picker(.localized("Certificate"), selection: $certificateID) {
						Text(.localized("Select Certificate")).tag("")
						ForEach(certificates.filter { $0.uuid != nil }, id: \.objectID) { certificate in
							Text(certificate.nickname ?? .localized("Certificate")).tag(certificate.uuid ?? "")
						}
					}
					Button(.localized("Upload Encrypted Backup"), systemImage: "lock.doc") {
						guard let certificate = certificates.first(where: { $0.uuid == certificateID }) else { return }
						let secret = passphrase
						run {
							try await service.upload(certificate, passphrase: secret)
							report = .localized("Encrypted Backup Uploaded")
							backups = try await service.backups()
						}
					}
					.disabled(certificateID.isEmpty || passphrase.count < 8)
				} footer: {
					Text(.localized("Feather encrypts the certificate, private key, profiles, and password on this device. Accretion stores the encrypted backup and its label."))
				}
				Section(.localized("Account Backups")) {
					Button(.localized("Refresh Backups")) { run { backups = try await service.backups() } }
					ForEach(backups) { backup in
						Menu(backup.label) {
							Button(.localized("Restore")) {
								let secret = passphrase
								run {
									let errors = try await service.restore(backup, passphrase: secret)
									report = errors.isEmpty ? .localized("Certificate Restored") : errors.joined(separator: "\n")
								}
							}
							.disabled(passphrase.isEmpty)
							Button(.localized("Delete Backup"), role: .destructive) { deleting = backup }
						}
					}
				}
			}
		}
		.disabled(working)
		.navigationTitle(.localized("Accretion Account"))
		.confirmationDialog(.localized("Delete This Hosted Backup?"), isPresented: Binding(
			get: { deleting != nil }, set: { if !$0 { deleting = nil } }
		), presenting: deleting) { backup in
			Button(.localized("Delete Backup"), role: .destructive) {
				run {
					try await service.deleteBackup(backup)
					backups.removeAll { $0.id == backup.id }
				}
			}
		}
		.task {
			if service.email != nil { run { backups = try await service.backups() } }
		}
	}

	private func run(_ task: @escaping @MainActor () async throws -> Void) {
		guard !working else { return }
		working = true
		report = nil
		Task {
			defer { working = false }
			do { try await task() }
			catch is CancellationError {}
			catch { report = error.localizedDescription }
		}
	}
}
