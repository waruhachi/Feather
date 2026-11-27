import SwiftUI
import UniformTypeIdentifiers

struct DocumentsMigrationView: View {
	@State private var password = ""
	@State private var pickingFolder = false
	@State private var isExporting = false
	@State private var working = false
	@State private var report: String?

	var body: some View {
		Form {
			Section {
				SecureField(.localized("Backup Password"), text: $password)
				Button(.localized("Export to Folder"), systemImage: "folder.badge.plus") {
					isExporting = true
					pickingFolder = true
				}
				.disabled(password.count < 8)
				Button(.localized("Restore from Folder"), systemImage: "folder") {
					isExporting = false
					pickingFolder = true
				}
				.disabled(password.isEmpty)
			} footer: {
				Text(.localized("Choose a location in Files to export a folder containing Library apps, IPA archives, and an encrypted backup of certificates, sources, tweaks, preferences, and pairing. To restore, select the exported Feather Migration folder. Existing Library items are kept."))
			}
			.disabled(working)
			if working { ProgressView() }
			if let report { Text(report) }
		}
		.navigationTitle(.localized("Documents Migration"))
		.fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
			switch result {
			case .success(let folder):
				let exporting = isExporting
				let secret = password
				password = ""
				working = true
				report = nil
				Task {
					defer { working = false }
					do {
						if exporting {
							let name = try await DocumentsMigration.export(to: folder, password: secret)
							report = .localized("Exported %@.", arguments: name)
						} else {
							let errors = try await DocumentsMigration.restore(from: folder, password: secret)
							report = errors.isEmpty ? .localized("Migration Restored") : errors.joined(separator: "\n")
						}
					} catch {
						report = error.localizedDescription
					}
				}
			case .failure(let error):
				report = error.localizedDescription
			}
		}
	}
}
