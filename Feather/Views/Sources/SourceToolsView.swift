import AltSourceKit
import SwiftUI
import UniformTypeIdentifiers

struct SourceToolsView: View {
	@State private var draft = SourceDraft()
	@State private var sourceURL = ""
	@State private var report = ""
	@State private var checking = false
	@State private var exporting = false
	@State private var document: SourceDocument?

	var body: some View {
		Form {
			Section(.localized("Validate Source")) {
				TextField(.localized("Source URL"), text: $sourceURL)
					.keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
				Button(.localized("Validate"), systemImage: "checkmark.seal") {
					Task { await validateRemoteSource() }
				}
				.disabled(checking || webURL(sourceURL) == nil)
				if checking { ProgressView() }
			}
			Section(.localized("Create Source")) {
				TextField(.localized("Source Name"), text: $draft.name)
				TextField(.localized("Source Identifier"), text: $draft.identifier)
					.textInputAutocapitalization(.never).autocorrectionDisabled()
				ForEach($draft.apps) { $app in
					DisclosureGroup(app.name.isEmpty ? .localized("App") : app.name) {
						TextField(.localized("App Name"), text: $app.name)
						TextField(.localized("Bundle Identifier"), text: $app.bundleIdentifier)
							.textInputAutocapitalization(.never).autocorrectionDisabled()
						TextField(.localized("Version"), text: $app.latest.version)
						TextField(.localized("IPA Size in Bytes"), value: $app.latest.size, format: .number.grouping(.never))
							.keyboardType(.numberPad)
						TextField(.localized("Description"), text: $app.localizedDescription, axis: .vertical)
						TextField(.localized("IPA Download URL"), text: $app.latest.downloadURL)
							.keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
						TextField(.localized("Icon URL"), text: $app.iconURL)
							.keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
						TextField(.localized("Developer Name"), text: $app.developerName)
					}
				}
				.onDelete { draft.apps.remove(atOffsets: $0) }
				Button(.localized("Add App"), systemImage: "plus") { draft.apps.append(.init()) }
				Button(.localized("Export JSON"), systemImage: "square.and.arrow.up", action: export)
			}
			if !report.isEmpty { Text(report).textSelection(.enabled) }
		}
		.navigationTitle(.localized("Source Tools"))
		.fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "source.json") { result in
			if case .failure(let error) = result { report = error.localizedDescription }
			document = nil
		}
	}

	private func validateRemoteSource() async {
		guard !checking, let url = webURL(sourceURL) else { return }
		checking = true
		defer { checking = false }
		do {
			let (data, response) = try await URLSession.shared.data(from: url)
			guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
				throw URLError(.badServerResponse)
			}
			report = try validationReport(data)
		} catch {
			report = error.localizedDescription
		}
	}

	private func export() {
		do {
			let encoder = JSONEncoder()
			encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
			let data = try encoder.encode(draft)
			let source = try JSONDecoder().decode(ASRepository.self, from: data)
			guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
				validIdentifier(draft.identifier),
				draft.apps.allSatisfy({ !$0.developerName.isEmpty && !$0.localizedDescription.isEmpty && $0.latest.size > 0 && webURL($0.iconURL) != nil }),
				source.apps.allSatisfy(hasRequiredFields)
			else {
				report = .localized("Enter a source name and identifier, and complete the name, developer, description, icon, version, size, bundle identifier, and download URL for each app.")
				return
			}
			report = try validationReport(data)
			document = SourceDocument(data: data)
			exporting = true
		} catch {
			report = error.localizedDescription
		}
	}

	private func validationReport(_ data: Data) throws -> String {
		let source = try JSONDecoder().decode(ASRepository.self, from: data)
		let invalid = source.apps.filter { !hasRequiredFields($0) }
		guard invalid.isEmpty else {
			return .localized("Missing or invalid update fields for %@.", arguments: invalid.map(\.currentName).joined(separator: ", "))
		}
		return .localized("Feather can read this source. It contains %lld app listings.", arguments: source.apps.count)
	}

	private func hasRequiredFields(_ app: ASRepository.App) -> Bool {
		guard let name = app.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
			let identifier = app.id, validIdentifier(identifier),
			let version = app.currentVersion, !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
			let url = app.currentDownloadUrl, webURL(url.absoluteString) != nil
		else { return false }
		return true
	}

	private func validIdentifier(_ identifier: String) -> Bool {
		identifier.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil
	}

	private func webURL(_ address: String) -> URL? {
		guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
			let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
			url.host?.isEmpty == false, url.user == nil, url.password == nil
		else { return nil }
		return url
	}
}

private struct SourceDraft: Encodable {
	var name = ""
	var identifier = ""
	var apps = [App()]

	struct App: Encodable, Identifiable {
		let id = UUID()
		var name = ""
		var bundleIdentifier = ""
		var developerName = ""
		var localizedDescription = ""
		var iconURL = ""
		var latest = Release()

		private enum CodingKeys: String, CodingKey {
			case name, bundleIdentifier, developerName, localizedDescription, iconURL, versions
		}

		func encode(to encoder: Encoder) throws {
			var container = encoder.container(keyedBy: CodingKeys.self)
			try container.encode(name, forKey: .name)
			try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
			try container.encode(developerName, forKey: .developerName)
			try container.encode(localizedDescription, forKey: .localizedDescription)
			try container.encode(iconURL, forKey: .iconURL)
			try container.encode([latest], forKey: .versions)
		}
	}

	struct Release: Encodable {
		var version = ""
		var downloadURL = ""
		var size: UInt64 = 0
		let date = ISO8601DateFormatter().string(from: Date())

	}
}

private struct SourceDocument: FileDocument {
	static var readableContentTypes: [UTType] { [.json] }
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
