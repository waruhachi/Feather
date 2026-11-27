import NimbleViews
import SwiftUI
import UniformTypeIdentifiers

struct FeatherBackupView: View {
	@State private var password = ""
	@State private var components = Set(FeatherBackup.Component.allCases)
	@State private var backup: BackupDocument?
	@State private var exporting = false
	@State private var importing = false
	@State private var working = false
	@State private var message: String?

	var body: some View {
		NBList(.localized("Backup & Restore")) {
			NavigationLink(.localized("Documents Migration")) {
				DocumentsMigrationView()
			}
			Section(.localized("Components")) {
				ForEach(FeatherBackup.Component.allCases, id: \.self) { component in
					Toggle(component.title, isOn: Binding(
						get: { components.contains(component) },
						set: { selected in
							if selected { components.insert(component) } else { components.remove(component) }
						}
					))
				}
			}
			.disabled(working)
			Section {
				SecureField(.localized("Backup Password"), text: $password)
					.textContentType(.password)
				Button(.localized("Create Backup"), systemImage: "externaldrive.badge.plus", action: exportBackup)
					.disabled(working || password.count < 8 || components.isEmpty)
				Button(.localized("Restore Backup"), systemImage: "externaldrive.badge.arrow.down") { importing = true }
					.disabled(working || password.isEmpty || components.isEmpty)
				if working { ProgressView() }
				if let message { Text(message).foregroundStyle(.secondary) }
			} footer: {
				Text(.localized("Choose what to include in an encrypted backup or restore from a file. Restore adds missing items and applies selected preferences."))
			}
		}
		.fileExporter(isPresented: $exporting, document: backup, contentType: BackupDocument.backupType, defaultFilename: "Feather") { result in
			if case .failure(let error) = result { message = error.localizedDescription }
			backup = nil
		}
		.fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
			switch result {
			case .success(let file):
				let password = self.password
				let components = self.components
				working = true
				Task {
					defer { working = false }
					do {
						let problems = try await FeatherBackup.restore(file: file, password: password, components: components)
						message = problems.isEmpty ? .localized("Backup Restored") : problems.joined(separator: "\n")
					} catch { message = error.localizedDescription }
				}
			case .failure(let error):
				message = error.localizedDescription
			}
		}
	}

	private func exportBackup() {
		let password = self.password
		let components = self.components
		working = true
		message = nil
		Task {
			defer { working = false }
			do {
				backup = BackupDocument(data: try await FeatherBackup.export(password: password, components: components))
				exporting = true
			} catch { message = error.localizedDescription }
		}
	}

	private struct BackupDocument: FileDocument {
		static let backupType = UTType(filenameExtension: "featherbackup", conformingTo: .data) ?? .data
		static var readableContentTypes: [UTType] { [backupType] }
		let data: Data

		init(data: Data) { self.data = data }

		init(configuration: ReadConfiguration) throws {
			guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
			self.data = data
		}

		func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
			FileWrapper(regularFileWithContents: data)
		}
	}
}
