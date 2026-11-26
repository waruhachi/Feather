import CoreData
import NimbleViews
import SwiftUI

struct LibraryWork: Identifiable {
	enum Purpose {
		case updates, signing, installation
	}

	let id = UUID()
	let purpose: Purpose
	let apps: [AppInfoPresentable]
	let sources: [AltSource]
	var offersReplacementCertificate = false
}

struct LibraryWorkView: View {
	@Environment(\.dismiss) private var dismiss
	@ObservedObject private var updates = UpdateManager.shared
	@FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)])
	private var certificates: FetchedResults<CertificatePair>
	@AppStorage("feather.selectedCert") private var defaultCertificate = 0
	@State private var choices: [String: AppUpdate] = [:]
	@State private var selected: Set<String> = []
	@State private var search = ""
	@State private var action = Action.download
	@State private var results: [String: String] = [:]
	@State private var activeID: String?
	@State private var task: Task<Void, Never>?
	@State private var installQueue: [InstallItem] = []
	@State private var inFlight: [InstallItem] = []
	@State private var showingInstalls = false
	@AppStorage("Feather.dismissInstallAfterFinish") private var dismissAfterFinish = false
	@AppStorage("Feather.openImportAfterInstall") private var openImportAfterInstall = false
	@State private var loaded = false
	@State private var replacementCertificateID: String?
	@State private var completedCount = 0
	@State private var workCount = 0

	private var replacementCertificates: [CertificatePair] {
		certificates.filter { $0.uuid != nil && !$0.revoked && ($0.expiration.map { $0 > Date() } ?? false) }
	}

	private struct InstallItem: Identifiable {
		let id = UUID()
		let rowID: String
		let app: AppInfoPresentable
	}

	let work: LibraryWork

	private enum Action: String, CaseIterable {
		case download = "Add to Library"
		case sign = "Sign"
		case install = "Sign and Install"
	}

	private var title: String {
		switch work.purpose {
		case .updates: .localized("Updates")
		case .signing: .localized("Batch Sign")
		case .installation: .localized("Install Queue")
		}
	}

	var body: some View {
		NBNavigationView(title, displayMode: .inline) {
			Form {
				if work.offersReplacementCertificate {
					Section {
						Picker(.localized("Replacement Certificate"), selection: $replacementCertificateID) {
							Text(.localized("Select Certificate")).tag(nil as String?)
							ForEach(replacementCertificates, id: \.objectID) { cert in
								Text(cert.nickname ?? .localized("Certificate")).tag(cert.uuid)
							}
						}
						.disabled(task != nil)
					} footer: {
						Text(.localized("A different signing team may require installing a fresh copy."))
					}
				}
				if work.purpose == .updates {
					Picker(.localized("Action"), selection: $action) {
						ForEach(Action.allCases, id: \.self) { action in
							Text(.localized(action.rawValue)).tag(action)
						}
					}
					.disabled(task != nil)
				}

				Section {
					ForEach(work.apps.compactMap(makeRow)) { row in
						if search.isEmpty || row.name.localizedCaseInsensitiveContains(search) {
							rowView(row)
						}
					}
				}

				if !installQueue.isEmpty {
					Section(.localized("Install Queue")) {
						ForEach(installQueue) { app in
							Text(app.app.name ?? .localized("Unknown"))
						}
						Button(.localized("Install Next"), action: { installNext() })
					}
				}
			}
			.safeAreaInset(edge: .bottom) {
				if task != nil && workCount > 0 {
					ProgressView(value: Double(completedCount), total: Double(workCount)) {
						Text(verbatim: String.localized("%lld of %lld processed", arguments: completedCount, workCount))
					}
					.padding()
					.background(.regularMaterial)
				}
			}
			.searchable(text: $search)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button(.localized(task == nil ? "Done" : "Stop After Current")) {
						if let task { task.cancel() } else { dismiss() }
					}
				}
				ToolbarItem(placement: .confirmationAction) {
					Button(.localized(work.purpose == .updates ? "Update All" : "Start"), action: start)
						.disabled(selected.isEmpty || task != nil || !inFlight.isEmpty
							|| (work.offersReplacementCertificate && replacementCertificateID == nil))
				}
			}
			.sheet(isPresented: $showingInstalls, onDismiss: {
				for item in inFlight {
					results[item.rowID] = .localized("Install Unconfirmed")
				}
				inFlight.removeAll()
			}) {
				ZStack {
					ForEach(inFlight) { item in
						InstallPreviewView(app: item.app, onOutcome: { message in
							finishInstall(item, message: message)
						}, onTransferStarted: {
							installNext(overlap: true)
						}, protectedCopies: {
							Set((inFlight + installQueue).compactMap { $0.app.uuid })
						})
						.opacity(inFlight.last?.id == item.id ? 1 : 0)
						.accessibilityHidden(inFlight.last?.id != item.id)
						.allowsHitTesting(inFlight.last?.id == item.id)
					}
				}
				.presentationDetents([.height(240)])
			}
		}
		.onAppear {
			guard !loaded else { return }
			loaded = true
			selected = Set(work.apps.compactMap { app in
				if work.purpose == .updates, let update = updates.update(for: app), !update.canDownload { return nil }
				return app.uuid
			})
			if work.purpose == .installation { start() }
		}
		.interactiveDismissDisabled(task != nil)
	}

	private struct Row: Identifiable {
		let id: String
		let name: String
		let app: AppInfoPresentable
		let update: AppUpdate?
	}

	private func makeRow(_ app: AppInfoPresentable) -> Row? {
		guard let uuid = app.uuid else { return nil }
		let update = choices[uuid] ?? updates.update(for: app)
		return Row(id: uuid, name: app.name ?? .localized("Unknown"), app: app, update: update)
	}

	private func rowView(_ row: Row) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			if work.purpose == .updates, let update = row.update, !update.canDownload {
				if let url = update.webURL { Link(row.name, destination: url) }
				Text(.localized("Open in App Store"))
					.font(.caption)
					.foregroundStyle(.secondary)
			} else {
				Toggle(row.name, isOn: Binding(
					get: { selected.contains(row.id) },
					set: { enabled in
						if enabled { selected.insert(row.id) } else { selected.remove(row.id) }
					}
				))
				.disabled(task != nil)
				if let result = results[row.id] {
					Text(result).font(.caption).foregroundStyle(.secondary)
				} else if activeID == row.id {
					ProgressView()
				}
			}

			if work.purpose == .updates, let update = row.update, update.providerKind == .featherSource {
				NavigationLink {
					UpdateSourcePicker(app: row.app, sources: work.sources, selected: update) { choice in
						choices[row.id] = choice
					}
				} label: {
					LabeledContent(.localized("Source"), value: update.sourceProvenance?.sourceRepositoryName ?? update.sourceURL?.host ?? update.remoteVersion)
						.font(.subheadline)
				}
				.disabled(task != nil)
			}
		}
	}

	private func start() {
		let pending = work.apps.compactMap(makeRow).filter { selected.contains($0.id) }
		completedCount = 0
		workCount = pending.count
		task = Task { @MainActor in
			defer { task = nil; activeID = nil }
			for row in pending {
				guard !Task.isCancelled else { break }
				activeID = row.id
				results[row.id] = nil
				do {
					try await run(row)
					selected.remove(row.id)
				} catch {
					results[row.id] = error.localizedDescription
				}
				completedCount += 1
			}
			if inFlight.isEmpty { installNext() }
		}
	}

	private func run(_ row: Row) async throws {
		if work.purpose == .installation {
			installQueue.append(InstallItem(rowID: row.id, app: row.app))
			results[row.id] = .localized("Queued")
			return
		}

		let input: AppInfoPresentable
		if work.purpose == .updates {
			guard let update = row.update, updates.canApply(update), let url = update.downloadURL else {
				throw WorkflowError.unavailable
			}
			let uuid: String = try await withCheckedThrowingContinuation { continuation in
				_ = DownloadManager.shared.startDownload(
					from: url,
					id: "FeatherManualDownload_Update_\(UUID().uuidString)",
					sourceProvenance: update.sourceProvenance,
					importOrigin: update.sourceProvenance == nil ? .remoteURL(update.sourceURL ?? url) : nil,
					updateFromUUID: update.localUUID,
					onImport: { continuation.resume(with: $0) }
				)
			}
			let request = Imported.fetchRequest()
			request.predicate = NSPredicate(format: "uuid == %@", uuid)
			guard let imported = try Storage.shared.context.fetch(request).first else { throw WorkflowError.unavailable }
			if action == .download {
				results[row.id] = .localized("Added to Library")
				return
			}
			let originalIdentifier = Storage.shared.sourceMetadata(for: row.id)?.sourceAppIdentifier ?? update.bundleIdentifier
			guard imported.identifier == originalIdentifier else { throw WorkflowError.identifierMismatch }
			input = imported
		} else {
			input = row.app
		}

		let recipe = try (row.app.identifier ?? input.identifier).flatMap { try SigningRecipe.load(for: $0) }
		let fallback = Storage.shared.getCertificate(from: row.app)
			?? (certificates.indices.contains(defaultCertificate) ? certificates[defaultCertificate] : nil)
		let certificate: CertificatePair?
		if work.offersReplacementCertificate {
			certificate = replacementCertificates.first { $0.uuid == replacementCertificateID }
		} else if let pin = recipe?.certificateID {
			guard let match = certificates.first(where: { $0.uuid == pin }) else {
				throw SigningPreflight.savedCertificateUnavailable
			}
			certificate = match
		} else {
			certificate = fallback
		}
		guard let certificate else { throw WorkflowError.noCertificate }

		let defaults = OptionsManager.shared.options
		// The existing signed bundle already contains the recipe's modifications.
		var options = work.offersReplacementCertificate ? .defaultOptions : recipe?.options(using: defaults) ?? defaults
		options.signingOption = .default
		// The single-app signing sheet owns confirmation of extension replacements.
		options.injectedAppExtensions = []
		if row.app.isSigned && (work.purpose == .updates || work.offersReplacementCertificate) {
			options.appIdentifier = row.app.identifier
		} else if recipe == nil, let identifier = input.identifier {
			if options.ppqProtection, certificate.ppQCheck {
				options.appIdentifier = identifier + "." + options.ppqString
			}
			options.appIdentifier = options.identifiers[identifier] ?? options.appIdentifier
		}
		if recipe == nil && !work.offersReplacementCertificate {
			options.appName = input.name.flatMap { options.displayNames[$0] } ?? options.appName
		}
		if work.purpose == .updates && row.app.isSigned {
			try SigningPreflight.checkReplacement(of: row.app, with: input, options: options, certificate: certificate)
		}
		if work.purpose == .updates, action == .install,
			let minimum = SigningPreflight.requiredSystemVersion(for: input, options: options)
		{
			throw SigningPreflight.newerSystemRequired(minimum)
		}
		let uuid = try await FR.signPackage(input, using: options, icon: work.offersReplacementCertificate ? nil : recipe?.icon, certificate: certificate)
		if work.offersReplacementCertificate, let recipe, let identifier = row.app.identifier {
			do {
				try SigningRecipe.save(for: identifier, options: recipe.options, certificate: certificate, icon: recipe.icon)
			} catch {
				results[row.id] = .localized("Re-signed. Could not update the saved certificate.")
				return
			}
		}
		if options.post_deleteAppAfterSigned, !input.isSigned {
			Storage.shared.deleteApp(for: input)
		}
		if work.purpose == .updates && action == .install {
			let request = Signed.fetchRequest()
			request.predicate = NSPredicate(format: "uuid == %@", uuid)
			guard let signed = try Storage.shared.context.fetch(request).first else { throw WorkflowError.unavailable }
			installQueue.append(InstallItem(rowID: row.id, app: signed))
		}
		results[row.id] = .localized("Signed")
	}

	private func installNext(overlap: Bool = false) {
		guard let next = installQueue.first, overlap || inFlight.isEmpty else { return }
		// LaunchServices tracks by bundle ID, so never overlap installs of the same app.
		guard !inFlight.contains(where: { $0.app.identifier == next.app.identifier }) else { return }
		installQueue.removeFirst()
		results[next.rowID] = .localized("Installing")
		inFlight.append(next)
		showingInstalls = true
	}

	private func finishInstall(_ item: InstallItem, message: String) {
		results[item.rowID] = message
		inFlight.removeAll { $0.id == item.id }
		installNext(overlap: UserDefaults.standard.integer(forKey: "Feather.installationMethod") == 0)
		guard inFlight.isEmpty else { return }
		showingInstalls = false
		let completed = message == .localized("Installed") || message == .localized("Finished. Check Home Screen.")
		if completed && (dismissAfterFinish || openImportAfterInstall) {
			if openImportAfterInstall { NotificationCenter.default.post(name: .featherImportAfterInstall, object: nil) }
			dismiss()
		}
	}

	private enum WorkflowError: LocalizedError {
		case unavailable, identifierMismatch, noCertificate
		var errorDescription: String? {
			switch self {
			case .unavailable: .localized("This update is no longer available. Check for updates again.")
			case .identifierMismatch: .localized("The downloaded app does not match the original bundle identifier. It was added to the Library without signing.")
			case .noCertificate: .localized("No Certificate")
			}
		}
	}
}

private struct UpdateSourcePicker: View {
	@Environment(\.dismiss) private var dismiss
	@State private var choices: [AppUpdate]?
	let app: AppInfoPresentable
	let sources: [AltSource]
	let selected: AppUpdate
	let onSelect: (AppUpdate) -> Void

	var body: some View {
		List {
			if let choices {
				ForEach(choices, id: \.sourceURL) { choice in
					Section {
						Button {
							onSelect(choice)
							dismiss()
						} label: {
							LabeledContent(
								choice.sourceProvenance?.sourceRepositoryName ?? choice.sourceURL?.absoluteString ?? choice.appName,
								value: choice.remoteVersion
							)
						}
						Button(.localized("Pin Source")) {
							UpdateManager.shared.pinSource(choice, for: choice.localUUID)
							onSelect(choice)
							dismiss()
						}
					}
				}
				if let uuid = app.uuid, Storage.shared.pinnedUpdateSource(for: uuid) != nil {
					Button(.localized("Reset Update Source")) {
						UpdateManager.shared.pinSource(nil, for: uuid)
						Task {
							await UpdateManager.shared.checkForUpdate(sources: sources, localApp: app)
							if let update = UpdateManager.shared.update(for: app) { onSelect(update) }
							dismiss()
						}
					}
				}
			} else {
				ProgressView()
			}
		}
		.navigationTitle(.localized("Update Source"))
		.task {
			choices = await UpdateManager.shared.sourceChoices(for: app, sources: sources)
		}
	}
}
