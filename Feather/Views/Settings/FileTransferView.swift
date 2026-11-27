import CoreData
import IDeviceSwift
import NimbleViews
import SwiftUI

struct FileTransferView: View {
	@Environment(\.scenePhase) private var scenePhase
	@ObservedObject private var server = TransferServer.shared
	@State private var files: [URL] = []
	@State private var error: String?

	@FetchRequest(sortDescriptors: [NSSortDescriptor(key: "date", ascending: false)])
	private var signed: FetchedResults<Signed>
	@FetchRequest(sortDescriptors: [NSSortDescriptor(key: "date", ascending: false)])
	private var imported: FetchedResults<Imported>
	@State private var shareMessage: String?
	@State private var sharing = false
	@State private var askForPassword = false
	@State private var password = ""

	var body: some View {
		NBList(.localized("File Transfer")) {
			Section {
				if let address = server.address {
					LabeledContent(.localized("Browser"), value: address.absoluteString).textSelection(.enabled)
					LabeledContent("WebDAV", value: address.appendingPathComponent("files", isDirectory: true).absoluteString)
						.textSelection(.enabled)
					LabeledContent(.localized("Username"), value: TransferServer.username).textSelection(.enabled)
					if let password = server.password {
						LabeledContent(.localized("Password"), value: password).textSelection(.enabled)
					}
					Button(.localized("Stop File Transfer"), role: .destructive) {
						Task { await server.stop(); refresh() }
					}
				} else {
					Button(.localized("Start File Transfer")) {
						Task {
							do { try await server.start() } catch is CancellationError {} catch { self.error = error.localizedDescription }
						}
					}
					.disabled(server.isStarting)
				}
			} footer: {
				Text(.localized("Use a trusted Wi-Fi network. Transfers use local HTTP and stop when Feather goes into the background."))
			}
			if let session = server.address {
				Section(.localized("Share With Browser")) {
					Menu(.localized("Share Library App"), systemImage: "square.and.arrow.up") {
						Section(.localized("Signed")) {
							ForEach(signed, id: \.objectID) { app in
								Button(app.name ?? .localized("Unknown")) { shareApp(app, session: session) }
							}
						}
						Section(.localized("Imported")) {
							ForEach(imported, id: \.objectID) { app in
								Button(app.name ?? .localized("Unknown")) { shareApp(app, session: session) }
							}
						}
					}
					.disabled(sharing || (signed.isEmpty && imported.isEmpty))
					let tweaks = TweakLibrary.files().filter { ["deb", "dylib"].contains($0.pathExtension.lowercased()) }
					Menu(.localized("Share Tweak"), systemImage: "shippingbox") {
						ForEach(tweaks, id: \.self) { file in
							Button(file.lastPathComponent) {
								share {
									try server.share(file, name: file.lastPathComponent, session: session)
								}
							}
						}
					}
					.disabled(sharing || tweaks.isEmpty)
					Button(.localized("Share Encrypted Certificate Backup"), systemImage: "lock.doc") {
						password = ""
						askForPassword = true
					}
					.disabled(sharing)
					if sharing { ProgressView() }
					if let shareMessage { Text(shareMessage).foregroundStyle(.secondary) }
				}
			}
			Section(.localized("Inbox")) {
				ForEach(files, id: \.self) { file in
					Menu(String(file.path.dropFirst(TransferServer.inbox.path.count + 1))) {
						Button(.localized("Import")) { importFile(file) }
						Button(.localized("Delete"), role: .destructive) {
							do { try FileManager.default.removeItem(at: file) } catch { self.error = error.localizedDescription }
							refresh()
						}
					}
				}
				Button(.localized("Refresh Inbox"), action: refresh)
			}
		}
		.task { refresh() }
		.refreshable { refresh() }
		.onChange(of: scenePhase) { phase in
			if phase == .background { Task { await server.stop() } }
		}
		.onDisappear { Task { await server.stop() } }
		.alert(.localized("Certificate Backup Password"), isPresented: $askForPassword) {
			SecureField(.localized("Password"), text: $password)
			Button(.localized("Share")) {
				let password = self.password
				self.password = ""
				guard let session = server.address else { return }
				share {
					let data = try await FeatherBackup.export(password: password, components: [.certificates])
					let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
					try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.protectionKey: FileProtectionType.complete])
					defer { try? FileManager.default.removeItem(at: directory) }
					let file = directory.appendingPathComponent("Feather Certificates.featherbackup")
					try data.write(to: file, options: [.atomic, .completeFileProtection])
					try server.share(file, name: file.lastPathComponent, session: session)
				}
			}
			.disabled(password.count < 8)
			Button(.localized("Cancel"), role: .cancel) { password = "" }
		}
		.alert(.localized("Error"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
			Button(.localized("OK"), role: .cancel) { error = nil }
		} message: {
			Text(error ?? "")
		}
	}

	private func shareApp(_ app: AppInfoPresentable, session: URL) {
		share {
			let title = app.name ?? .localized("Application")
			let archive = ArchiveHandler(app: app, viewModel: InstallerStatusViewModel(isIdevice: false))
			try await archive.move()
			let file = try await archive.archive()
			try server.share(file, name: title + ".ipa", session: session)
		}
	}

	private func share(_ prepare: @escaping @MainActor () async throws -> Void) {
		guard !sharing else { return }
		sharing = true
		shareMessage = nil
		Task {
			defer { sharing = false }
			do {
				try await prepare()
				shareMessage = .localized("Available in the browser. Refresh its shared files list.")
			} catch is CancellationError {
			} catch {
				self.error = error.localizedDescription
			}
		}
	}

	private func refresh() {
		let types = TweakLibrary.extensions + ["ipa", "tipa"]
		let entries = FileManager.default.enumerator(at: TransferServer.inbox, includingPropertiesForKeys: [.isSymbolicLinkKey], options: .skipsHiddenFiles)
		var discovered: [URL] = []
		while let file = entries?.nextObject() as? URL {
			guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
				entries?.skipDescendants()
				continue
			}
			if types.contains(file.pathExtension.lowercased()) {
				discovered.append(file)
				entries?.skipDescendants()
			}
		}
		files = discovered.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
	}

	private func importFile(_ file: URL) {
		Task {
			do {
				if ["ipa", "tipa"].contains(file.pathExtension.lowercased()) {
					_ = try await FR.importPackage(file)
				} else {
					try TweakLibrary.add(file)
				}
				try FileManager.default.removeItem(at: file)
				refresh()
			} catch { self.error = error.localizedDescription }
		}
	}
}
