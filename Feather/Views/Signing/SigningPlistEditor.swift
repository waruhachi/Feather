import SwiftUI

struct SigningPlistEditor: View {
	@Environment(\.dismiss) private var dismiss
	@State private var xml = ""
	@State private var error: String?
	@State private var loaded = false

	let title: String
	let read: () throws -> [String: Any]
	let save: ([String: Any]) throws -> Void

	var body: some View {
		Form {
			Section {
				TextEditor(text: $xml)
					.font(.system(.body, design: .monospaced))
					.autocorrectionDisabled()
					.textInputAutocapitalization(.never)
					.frame(minHeight: 340)
					.accessibilityLabel(title)
			}
			if let error {
				Text(error).foregroundStyle(.red)
			}
		}
		.navigationTitle(title)
		.toolbar {
			ToolbarItem(placement: .confirmationAction) {
				Button(.localized("Save")) {
					do {
						let dictionary = try Self.dictionary(from: Data(xml.utf8))
						try save(dictionary)
						dismiss()
					} catch { self.error = error.localizedDescription }
				}
				.disabled(!loaded)
			}
		}
		.task {
			guard !loaded else { return }
			do {
				xml = String(decoding: try Self.encode(read()), as: UTF8.self)
				loaded = true
			} catch { self.error = error.localizedDescription }
		}
	}

	static func dictionary(from data: Data) throws -> [String: Any] {
		guard let dictionary = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
			throw CocoaError(.propertyListReadCorrupt)
		}
		return dictionary
	}

	static func encode(_ dictionary: [String: Any]) throws -> Data {
		try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
	}
}
