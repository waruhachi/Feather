import NimbleViews
import SwiftUI

struct FileTransferView: View {
	@Environment(\.scenePhase) private var scenePhase
	@ObservedObject private var server = TransferServer.shared
	@State private var files: [URL] = []
	@State private var error: String?

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
		.alert(.localized("Error"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
			Button(.localized("OK"), role: .cancel) { error = nil }
		} message: {
			Text(error ?? "")
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
