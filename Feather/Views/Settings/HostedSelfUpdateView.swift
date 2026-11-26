#if os(iOS) && !targetEnvironment(macCatalyst)
import CoreData
import NimbleViews
import SwiftUI
import UIKit

struct HostedSelfUpdateView: View {
	@AppStorage("Feather.hostedUpdateServer") private var savedServer = ""
	@AppStorage("feather.selectedCert") private var defaultCertificate = 0
	@FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)])
	private var certificates: FetchedResults<CertificatePair>
	@State private var server = ""
	@State private var token = ""
	@State private var certificateID: NSManagedObjectID?
	@State private var release: HostedSelfUpdate.Release?
	@State private var checking = false
	@State private var signing = false
	@State private var message: String?
	@State private var request: InstallRequest?
	@AppStorage("Feather.ignoredReleaseTags") private var ignoredData = Data()
	@State private var browsingReleases = false

	private var ignoredTags: Set<String> {
		(try? JSONDecoder().decode(Set<String>.self, from: ignoredData)) ?? []
	}

	private func setIgnored(_ tag: String, ignored: Bool) {
		var tags = ignoredTags
		if ignored { tags.insert(tag) } else { tags.remove(tag) }
		if let data = try? JSONEncoder().encode(tags) { ignoredData = data }
	}

	private struct InstallRequest: Identifiable {
		let id = UUID()
		let server: HostedSelfUpdate.Configuration
		let token: String
		let certificate: CertificatePair
		let release: HostedSelfUpdate.Release
	}

	var body: some View {
		NBList(.localized("Feather Updates")) {
			Section {
				TextField(.localized("Signing Server"), text: $server, prompt: Text("https://updates.example.com"))
					.keyboardType(.URL)
					.textContentType(.URL)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
				SecureField(.localized("Access Token"), text: $token)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
				Button(.localized("Save Server"), action: save)
			} header: {
				Text(.localized("Hosted Self-Signing"))
			}

			Section {
				Picker(.localized("Certificate"), selection: $certificateID) {
					Text(.localized("Select Certificate")).tag(Optional<NSManagedObjectID>.none)
					ForEach(certificates, id: \.objectID) { certificate in
						Text(certificate.nickname ?? Storage.shared.getProvisionFileDecoded(for: certificate)?.Name ?? .localized("Certificate"))
							.tag(Optional(certificate.objectID))
					}
				}
				Button(.localized("Check for Updates"), action: check)
					.disabled(checking)
				if let release {
					LabeledContent(.localized("Latest Release"), value: release.version)
					if ignoredTags.contains(release.tag_name) {
						Button(.localized("Stop Ignoring This Release")) { setIgnored(release.tag_name, ignored: false) }
					} else if release.isNewer {
						Button(.localized("Sign and Install Update"), action: confirm)
							.disabled(signing || certificateID == nil)
						Button(.localized("Ignore This Release")) { setIgnored(release.tag_name, ignored: true) }
					} else {
						Text(.localized("Feather is up to date.")).foregroundStyle(.secondary)
					}
				}
				if signing || checking { ProgressView() }
				if let message { Text(message).foregroundStyle(.secondary) }
			}
			Section {
				Button(.localized("All Versions"), systemImage: "clock.arrow.circlepath") { browsingReleases = true }
				NavigationLink(.localized("Ignored Releases")) {
					List(ignoredTags.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }), id: \.self) { tag in
						LabeledContent(tag) {
							Button(.localized("Restore")) { setIgnored(tag, ignored: false) }
								.buttonStyle(.borderless)
						}
					}
					.navigationTitle(.localized("Ignored Releases"))
				}
			}
		}
		.sheet(isPresented: $browsingReleases) {
			NavigationStack {
				FeatherReleaseHistoryView(ignored: ignoredTags) { selected in
					release = selected
					browsingReleases = false
				}
			}
		}
		.disabled(signing)
		.onAppear {
			if server.isEmpty {
				server = savedServer
				if let configuration = try? HostedSelfUpdate.Configuration(savedServer) {
					token = HostedSelfUpdate.storedToken(for: configuration.origin) ?? ""
				}
			}
			if certificateID == nil, certificates.indices.contains(defaultCertificate) {
				certificateID = certificates[defaultCertificate].objectID
			}
		}
		.onChange(of: server) { address in
			// Never carry an existing host’s token into a new host.
			let current = try? HostedSelfUpdate.Configuration(address)
			token = current.flatMap { HostedSelfUpdate.storedToken(for: $0.origin) } ?? ""
		}
		.confirmationDialog(
			.localized("Send Signing Credentials?"),
			isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
			titleVisibility: .visible,
			presenting: request
		) { request in
			Button(.localized("Send and Sign")) { sign(request) }
			Button(.localized("Cancel"), role: .cancel) {}
		} message: { request in
			Text(String.localized("Feather will send the selected certificate, its password, and its provisioning profile to %@.", arguments: request.server.origin.absoluteString))
		}
	}

	private func save() {
		do {
			let configuration = try HostedSelfUpdate.Configuration(server)
			try HostedSelfUpdate.saveToken(token, for: configuration.origin)
			savedServer = configuration.origin.absoluteString
			message = .localized("Server Saved")
		} catch { message = error.localizedDescription }
	}

	private func check() {
		checking = true
		message = nil
		Task {
			defer { checking = false }
			do { release = try await HostedSelfUpdate.latestRelease() }
			catch { release = nil; message = error.localizedDescription }
		}
	}

	private func confirm() {
		do {
			let configuration = try HostedSelfUpdate.Configuration(server)
			guard !token.isEmpty else { throw HostedSelfUpdate.Failure.unauthorized }
			guard let release, !ignoredTags.contains(release.tag_name), let certificate = certificates.first(where: { $0.objectID == certificateID }) else {
				throw HostedSelfUpdate.Failure.certificateMissing
			}
			request = InstallRequest(server: configuration, token: token, certificate: certificate, release: release)
		} catch { message = error.localizedDescription }
	}

	private func sign(_ request: InstallRequest) {
		signing = true
		message = nil
		Task {
			defer { signing = false }
			do {
				let url = try await HostedSelfUpdate.requestInstall(
					release: request.release, configuration: request.server, token: request.token, certificate: request.certificate
				)
				if await UIApplication.shared.open(url) {
					message = .localized("Confirm the install in iOS.")
				} else {
					message = .localized("iOS did not open the installation link.")
				}
			} catch { message = error.localizedDescription }
		}
	}
}

private struct FeatherReleaseHistoryView: View {
	@Environment(\.dismiss) private var dismiss
	@State private var releases: [HostedSelfUpdate.Release] = []
	@State private var query = ""
	@State private var nextPage = 1
	@State private var hasMore = true
	@State private var loading = false
	@State private var message: String?
	let ignored: Set<String>
	let select: (HostedSelfUpdate.Release) -> Void

	var body: some View {
		List {
			ForEach(releases.filter { query.isEmpty || $0.version.localizedCaseInsensitiveContains(query) }) { release in
				NavigationLink {
					List {
						if let notes = release.body, !notes.isEmpty { Text(notes).textSelection(.enabled) }
						Link(.localized("Open on GitHub"), destination: release.page)
						if release.isNewer && !ignored.contains(release.id) {
							Button(.localized("Choose This Update")) { select(release) }
						}
					}
					.navigationTitle(release.tag_name)
				} label: {
					LabeledContent(release.tag_name, value: ignored.contains(release.id) ? String.localized("Ignored") : "")
				}
			}
			if let message { Text(message).foregroundStyle(.secondary) }
			if loading { ProgressView() }
			if hasMore && !loading {
				Button(.localized(nextPage == 1 ? "Load Releases" : "Load More")) { Task { await load() } }
			}
		}
		.navigationTitle(.localized("All Versions"))
		.searchable(text: $query)
		.toolbar { ToolbarItem(placement: .cancellationAction) { Button(.localized("Done")) { dismiss() } } }
		.task { if releases.isEmpty { await load() } }
	}

	private func load() async {
		guard !loading, hasMore else { return }
		loading = true
		defer { loading = false }
		do {
			let page = try await HostedSelfUpdate.releaseHistory(page: nextPage)
			let known = Set(releases.map(\.id))
			releases += page.releases.filter { !known.contains($0.id) }
			nextPage += 1
			hasMore = page.hasMore
			message = releases.isEmpty && !hasMore ? .localized("No releases available.") : nil
		} catch { message = error.localizedDescription }
	}
}
#endif
