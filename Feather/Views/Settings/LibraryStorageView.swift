import NimbleViews
import SwiftUI

struct LibraryStorageView: View {
	@AppStorage("Feather.deleteOlderSignedCopies") private var deleteOlderSignedCopies = false
	@AppStorage("Feather.deleteEqualSignedCopies") private var deleteEqualSignedCopies = false
	@AppStorage("Feather.deleteNewerSignedCopies") private var deleteNewerSignedCopies = false
	@AppStorage("Feather.deleteInstalledSignedCopy") private var deleteInstalledSignedCopy = false
	@AppStorage("Feather.clearCacheAfterInstall") private var clearCacheAfterInstall = false
	@ObservedObject private var options = OptionsManager.shared
	@State private var usage: [String: Int64] = [:]
	@State private var archives: [URL] = []
	@State private var removing: URL?
	@State private var error: String?

	private var directories: [(label: String, url: URL)] {
		let manager = FileManager.default
		return [
			("Signed", manager.signed),
			("Imported", manager.unsigned),
			("Archives", manager.archives),
			("Saved Tweaks", TweakLibrary.directory),
			("Transfer Inbox", TransferServer.inbox),
		]
	}

	var body: some View {
		NBList(.localized("Storage")) {
			Section(.localized("Library Storage")) {
				ForEach(directories, id: \.label) { directory in
					LabeledContent(.localized(directory.label), value: usage[directory.label].map {
						ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
					} ?? "…")
				}
			}
			Section {
				Toggle(.localized("Delete Imported Copy After Signing"), isOn: $options.options.post_deleteAppAfterSigned)
				Toggle(.localized("Delete the Installed Library Copy"), isOn: $deleteInstalledSignedCopy)
				Toggle(.localized("Delete Older Signed Copies"), isOn: $deleteOlderSignedCopies)
				Toggle(.localized("Delete Same-Version Signed Copies"), isOn: $deleteEqualSignedCopies)
				Toggle(.localized("Delete Newer Signed Copies"), isOn: $deleteNewerSignedCopies)
				Toggle(.localized("Clear Network Cache After Installing"), isOn: $clearCacheAfterInstall)
			} header: {
				Text(.localized("Automatic Cleanup"))
			} footer: {
				Text(.localized("Post-install cleanup only runs after confirmation. Files queued for installation are kept."))
			}
			Section(.localized("Archives")) {
				ForEach(archives, id: \.self) { file in
					ShareLink(item: file) { Text(file.lastPathComponent) }
						.swipeActions(allowsFullSwipe: false) {
							Button(.localized("Delete"), role: .destructive) { removing = file }
						}
				}
			}
		}
		.task { await refresh() }
		.refreshable { await refresh() }
		.confirmationDialog(.localized("Delete Archive"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { file in
			Button(.localized("Delete"), role: .destructive) {
				do {
					try FileManager.default.removeItem(at: file)
					Task { await refresh() }
				} catch { self.error = error.localizedDescription }
			}
		} message: { file in
			Text(file.lastPathComponent)
		}
		.alert(.localized("Error"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
			Button(.localized("OK"), role: .cancel) { error = nil }
		} message: {
			Text(error ?? "")
		}
	}

	private func refresh() async {
		let directories = self.directories
		usage = await Task.detached(priority: .utility) {
			Dictionary(uniqueKeysWithValues: directories.map { directory in
				let keys: [URLResourceKey] = [.fileAllocatedSizeKey, .isRegularFileKey]
				let files = FileManager.default.enumerator(at: directory.url, includingPropertiesForKeys: keys)
				var size: Int64 = 0
				while let url = files?.nextObject() as? URL {
					if let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
						size += Int64(values.fileAllocatedSize ?? 0)
					}
				}
				return (directory.label, size)
			})
		}.value
		archives = (try? FileManager.default.contentsOfDirectory(at: FileManager.default.archives, includingPropertiesForKeys: nil, options: .skipsHiddenFiles))?.filter { $0.pathExtension == "ipa" }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
	}
}
