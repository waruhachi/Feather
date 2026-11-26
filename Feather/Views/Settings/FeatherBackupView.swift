import NimbleViews
import SwiftUI
import UniformTypeIdentifiers

struct FeatherBackupView: View {
	@State private var password = ""
	@State private var backup: BackupDocument?
	@State private var exporting = false
	@State private var importing = false
	@State private var working = false
	@State private var message: String?

	var body: some View {
		NBList(.localized("Backup & Restore")) {
			Section {
				SecureField(.localized("Backup Password"), text: $password)
					.textContentType(.password)
				Button(.localized("Create Backup"), systemImage: "externaldrive.badge.plus", action: exportBackup)
					.disabled(working || password.count < 8)
				Button(.localized("Restore Backup"), systemImage: "externaldrive.badge.arrow.down") { importing = true }
					.disabled(working || password.isEmpty)
				if working { ProgressView() }
				if let message { Text(message).foregroundStyle(.secondary) }
			} footer: {
				Text(.localized("Encrypted backups contain certificates, sources, saved tweaks, and preferences. Restore adds missing items and applies the saved preferences. Apps and pairing records are excluded."))
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
				working = true
				Task {
					defer { working = false }
					do {
						let problems = try await FeatherBackup.restore(file: file, password: password)
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
		working = true
		message = nil
		Task {
			defer { working = false }
			do {
				backup = BackupDocument(data: try await FeatherBackup.export(password: password))
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
