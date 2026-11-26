import CryptoKit
import UIKit

@MainActor
struct SigningRecipe {
	let options: Options
	let certificateID: String?
	let icon: UIImage?

	private struct Record: Codable {
		let options: Options
		let certificateID: String?
		let generation: UUID
		let hasIcon: Bool
	}

	static func lastTarget(for original: String) -> String? {
		UserDefaults.standard.string(forKey: "Feather.signingRecipeTarget." + original)
	}

	static func setLastTarget(_ target: String?, for original: String) {
		UserDefaults.standard.set(target, forKey: "Feather.signingRecipeTarget." + original)
	}

	static func owns(_ url: URL) -> Bool {
		url.path.hasPrefix(root.path + "/")
	}

	static func load(for identifier: String) throws -> SigningRecipe? {
		_ = removeUnusedGenerations
		let folder = directory(for: identifier)
		let manifest = folder.appendingPathComponent("Recipe.json")
		guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
		let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: manifest))
		let assets = folder.appendingPathComponent(record.generation.uuidString, isDirectory: true)
		let options = try remapTweaks(in: record.options) { _, url in
			let file = assets.appendingPathComponent(url.pathComponents.suffix(2).joined(separator: "/"))
			guard FileManager.default.fileExists(atPath: file.path) else {
				throw CocoaError(.fileNoSuchFile)
			}
			return file
		}
		let icon = record.hasIcon ? UIImage(contentsOfFile: assets.appendingPathComponent("Icon.png").path) : nil
		if record.hasIcon && icon == nil { throw CocoaError(.fileReadCorruptFile) }
		return SigningRecipe(options: options, certificateID: record.certificateID, icon: icon)
	}

	static func save(for identifier: String, options: Options, certificate: CertificatePair?, icon: UIImage?) throws {
		_ = removeUnusedGenerations
		let folder = directory(for: identifier)
		let manifest = folder.appendingPathComponent("Recipe.json")
		let generation = UUID()
		let assets = folder.appendingPathComponent(generation.uuidString, isDirectory: true)
		let manager = FileManager.default

		do {
			try manager.createDirectory(at: assets, withIntermediateDirectories: true)
			var saved = try remapTweaks(in: options) { index, url in
				let group = assets.appendingPathComponent(String(index), isDirectory: true)
				try manager.createDirectory(at: group, withIntermediateDirectories: false)
				try manager.copyItem(at: url, to: group.appendingPathComponent(url.lastPathComponent))
				return URL(fileURLWithPath: "/\(index)/\(url.lastPathComponent)")
			}
			// Keep version-specific edits and post-sign actions scoped to the current run.
			saved.appIdentifier = identifier
			saved.appVersion = nil
			saved.appInfoPlist = nil
			saved.appEntitlementsFile = nil
			saved.injectedAppExtensions = []
			saved.signingOption = .default
			saved.post_deleteAppAfterSigned = false
			saved.post_installAppAfterSigned = false
			if let icon {
				guard let data = icon.pngData() else { throw CocoaError(.fileWriteUnknown) }
				try data.write(to: assets.appendingPathComponent("Icon.png"))
			}
			let record = Record(options: saved, certificateID: certificate?.uuid, generation: generation, hasIcon: icon != nil)
			try JSONEncoder().encode(record).write(to: manifest, options: .atomic)
		} catch {
			try? manager.removeItem(at: assets)
			throw error
		}
	}

	static func remove(for identifier: String) throws {
		_ = removeUnusedGenerations
		let manifest = directory(for: identifier).appendingPathComponent("Recipe.json")
		if FileManager.default.fileExists(atPath: manifest.path) {
			try FileManager.default.removeItem(at: manifest)
		}
	}

	static func reset() {
		try? FileManager.default.removeItem(at: root)
	}

	// Keep previous assets until the next launch. An open sheet or queued job may
	// still refer to them after a recipe is replaced or forgotten.
	private static let removeUnusedGenerations: Void = {
		let manager = FileManager.default
		guard let recipes = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
		for directory in recipes {
			let manifest = directory.appendingPathComponent("Recipe.json")
			let current = (try? Data(contentsOf: manifest))
				.flatMap { try? JSONDecoder().decode(Record.self, from: $0) }?.generation
			guard current != nil || !manager.fileExists(atPath: manifest.path),
				let entries = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
			else { continue }
			for entry in entries {
				if let generation = UUID(uuidString: entry.lastPathComponent), generation != current {
					try? manager.removeItem(at: entry)
				}
			}
			if current == nil { try? manager.removeItem(at: directory) }
		}
	}()

	func options(using defaults: Options) -> Options {
		var result = options
		result.post_deleteAppAfterSigned = defaults.post_deleteAppAfterSigned
		result.post_installAppAfterSigned = defaults.post_installAppAfterSigned
		return result
	}

	private static func directory(for identifier: String) -> URL {
		let key = SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
		return root.appendingPathComponent(key, isDirectory: true)
	}

	private static var root: URL {
		URL.applicationSupportDirectory.appendingPathComponent("FeatherSigningRecipes", isDirectory: true)
	}

	private static func remapTweaks(in options: Options, with transform: (Int, URL) throws -> URL) rethrows -> Options {
		var result = options
		var rules: [String: TweakInjectionRule] = [:]
		let files = options.injectionFiles + options.injectionFrameworks
		result.injectionFiles = try files.enumerated().map { index, original in
			let mapped = try transform(index, original)
			rules[mapped.absoluteString] = options.tweakInjectionRules?[original.absoluteString]
			return mapped
		}
		result.injectionFrameworks = []
		result.tweakInjectionRules = rules.isEmpty ? nil : rules
		return result
	}
}
