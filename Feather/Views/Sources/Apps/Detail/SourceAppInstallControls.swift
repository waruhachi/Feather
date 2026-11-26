import AltSourceKit
import CoreData
import NimbleViews
import SwiftUI

struct SourceAppInstallControls: View {
	let sourceURL: URL?
	let source: ASRepository
	let app: ASRepository.App

	@State private var versionIndex = 0
	@State private var transfer: Download?
	@State private var imported: AnyApp?
	@State private var signed: AnyApp?
	@State private var signingSheet: AnyApp?
	@State private var installSheet: AnyApp?
	@State private var message: String?
	@State private var installedID: String?

	private var versions: [ASRepository.App.Version] {
		(app.versions ?? []).filter { $0.downloadURL != nil }
	}
	private var version: ASRepository.App.Version? { versions.indices.contains(versionIndex) ? versions[versionIndex] : nil }

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			if versions.count > 1 {
				Picker(.localized("Version"), selection: $versionIndex) {
					ForEach(versions.indices, id: \.self) { index in
						let item = versions[index]
						Text(item.version + (item.build.map { " (" + $0 + ")" } ?? "")).tag(index)
					}
				}
				.disabled(transfer != nil)
				.onChange(of: versionIndex) { _ in
					imported = nil
					signed = nil
					message = nil
					installedID = nil
				}
			}
			if let transfer {
				SourceAppTransferProgress(transfer: transfer)
			} else if let installedID {
				Button(.localized("Open")) {
					if !InstalledAppProbe.open(installedID) {
						message = .localized("Open the app from your Home Screen.")
					}
				}
				.buttonStyle(.borderedProminent)
			} else if let signed {
				Button(.localized("Install")) { installSheet = signed }
					.buttonStyle(.borderedProminent)
			} else if let imported {
				Button(.localized("Sign")) { signingSheet = imported }
					.buttonStyle(.borderedProminent)
			} else if version?.downloadURL ?? app.currentDownloadUrl != nil {
				Button(.localized("Get"), action: download)
					.buttonStyle(.borderedProminent)
			}
			if let message {
				Text(message).font(.caption).foregroundStyle(.secondary)
			}
		}
		.sheet(item: $signingSheet, onDismiss: {
			if signed == nil { message = .localized("Ready to Sign") }
		}) { item in
			SigningView(app: item.base) { uuid in
				guard let result: Signed = lookup(uuid, request: Signed.fetchRequest()) else {
					message = .localized("The signed app could not be found in Library.")
					return
				}
				signed = AnyApp(base: result)
				message = .localized("Ready to Install")
			}
		}
		.sheet(item: $installSheet) { item in
			InstallPreviewView(app: item.base, onOutcome: { status in message = status }, onVerifiedInstall: {
				installedID = item.base.identifier
			})
		}
	}

	private func download() {
		guard let url = version?.downloadURL ?? app.currentDownloadUrl else { return }
		message = nil
		transfer = DownloadManager.shared.startDownload(
			from: url,
			id: "FeatherSourceDetail_" + UUID().uuidString,
			sourceProvenance: SourceAppProvenance(sourceURL: sourceURL, repository: source, app: app, version: version)
		) { result in
			transfer = nil
			switch result {
			case .success(let uuid):
				guard let item: Imported = lookup(uuid, request: Imported.fetchRequest()),
					app.id == nil || item.identifier == app.id
				else {
					message = .localized("The downloaded app does not match the source. Check the IPA in Library.")
					return
				}
				imported = AnyApp(base: item)
				message = .localized("Ready to Sign")
			case .failure(let error):
				message = error.localizedDescription
			}
		}
	}

	private func lookup<T: NSManagedObject>(_ uuid: String, request: NSFetchRequest<T>) -> T? {
		request.predicate = NSPredicate(format: "uuid == %@", uuid)
		request.fetchLimit = 1
		return try? Storage.shared.context.fetch(request).first
	}
}

private struct SourceAppTransferProgress: View {
	@ObservedObject var transfer: Download

	var body: some View {
		ProgressView(value: transfer.overallProgress) {
			Text(.localized(transfer.isImporting ? "Importing" : "Downloading"))
		}
		Button(.localized("Cancel Download"), role: .cancel) {
			DownloadManager.shared.cancelDownload(transfer)
		}
		.buttonStyle(.borderless)
	}
}
