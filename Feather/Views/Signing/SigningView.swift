//
//  SigningView.swift
//  Feather
//
//  Created by samara on 14.04.2025.
//

import CoreData
import SwiftUI
import PhotosUI
import NimbleViews

// MARK: - View
struct SigningView: View {
	@Environment(\.dismiss) var dismiss
	@StateObject private var _optionsManager = OptionsManager.shared
	
	@State private var _temporaryOptions: Options = OptionsManager.shared.options
	@State private var _temporaryCertificate: Int
	@State private var _isAltPickerPresenting = false
	@State private var _isFilePickerPresenting = false
	@State private var _isImagePickerPresenting = false
	@State private var _isSigning = false
	#if os(iOS) && !targetEnvironment(macCatalyst)
	@ObservedObject private var appleID = AppleIDProvisioning.shared
	@State private var useAppleID = false
	#endif

	private var usesAppleID: Bool {
		#if os(iOS) && !targetEnvironment(macCatalyst)
		useAppleID && appleID.account != nil && _temporaryOptions.signingOption == .default
		#else
		false
		#endif
	}
	@State private var _selectedPhoto: PhotosPickerItem? = nil
	@State private var _rememberRecipe = false
	@State private var _loadedSettings = false
	@State private var _recipeIdentifier: String?
	@State var appIcon: UIImage?
	
	// MARK: Fetch
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var certificates: FetchedResults<CertificatePair>
	
	private func _selectedCert() -> CertificatePair? {
		guard certificates.indices.contains(_temporaryCertificate) else { return nil }
		return certificates[_temporaryCertificate]
	}
	
	var app: AppInfoPresentable
	var onSigned: ((String) -> Void)?
	
	init(app: AppInfoPresentable, onSigned: ((String) -> Void)? = nil) {
		self.app = app
		self.onSigned = onSigned
		let storedCert = UserDefaults.standard.integer(forKey: "feather.selectedCert")
		__temporaryCertificate = State(initialValue: storedCert)
	}
		
	// MARK: Body
	var body: some View {
		NBNavigationView("", displayMode: .inline) {
			Form {
				_customizationOptions(for: app)
				_cert()
				_customizationProperties(for: app)
				
				// horrible
				Rectangle()
					.foregroundStyle(.clear)
					.frame(height: 30)
					.listRowBackground(EmptyView())
			}
			.overlay {
				VStack(spacing: 0) {
					Spacer()
					NBVariableBlurView()
						.frame(height: UIDevice.current.userInterfaceIdiom == .pad ? 60 : 80)
						.rotationEffect(.degrees(180))
						.overlay {
							Button {
								_start()
							} label: {
								NBSheetButton(title: .localized(_isSigning ? "Signing" : "Start Signing"), style: .prominent)
									.padding()
							}
							.buttonStyle(.plain)
							.offset(y: UIDevice.current.userInterfaceIdiom == .pad ? -20 : -40)
						}
				}
				.ignoresSafeArea(edges: .bottom)
			}

			.toolbar {
				NBToolbarButton(role: .dismiss)
				ToolbarItem(placement: .principal) {
					Image("Glyph")
						.resizable()
						.scaledToFit()
						.frame(height: 38)
				}
				NBToolbarButton(
					.localized("Reset"),
					style: .text,
					placement: .topBarTrailing
				) {
					_temporaryOptions = OptionsManager.shared.options
					appIcon = nil
					_rememberRecipe = false
				}
			}
			.sheet(isPresented: $_isAltPickerPresenting) { SigningAlternativeIconView(app: app, appIcon: $appIcon, isModifing: .constant(true)) }
			.sheet(isPresented: $_isFilePickerPresenting) {
				FileImporterRepresentableView(
					allowedContentTypes:  [.image],
					onDocumentsPicked: { urls in
						guard let selectedFileURL = urls.first else { return }
						self.appIcon = UIImage.fromFile(selectedFileURL)?.resizeToSquare()
					}
				)
				.ignoresSafeArea()
			}
			.photosPicker(isPresented: $_isImagePickerPresenting, selection: $_selectedPhoto)
			.onChange(of: _selectedPhoto) { newValue in
				guard let newValue else { return }
				
				Task {
					if let data = try? await newValue.loadTransferable(type: Data.self),
					   let image = UIImage(data: data)?.resizeToSquare() {
						appIcon = image
					}
				}
			}
			.disabled(_isSigning)
			.animation(.smooth, value: _isSigning)
		}
		.onAppear {
			guard !_loadedSettings else { return }
			_loadedSettings = true
			// ppq protection
			if
				_optionsManager.options.ppqProtection,
				let identifier = app.identifier,
				let cert = _selectedCert(),
				cert.ppQCheck
			{
				_temporaryOptions.appIdentifier = "\(identifier).\(_optionsManager.options.ppqString)"
			}
			
			if
				let currentBundleId = app.identifier,
				let newBundleId = _temporaryOptions.identifiers[currentBundleId]
			{
				_temporaryOptions.appIdentifier = newBundleId
			}
			
			if
				let currentName = app.name,
				let newName = _temporaryOptions.displayNames[currentName]
			{
				_temporaryOptions.appName = newName
			}

			_loadRecipe()
		}
	}
}

// MARK: - Extension: View
extension SigningView {
	@ViewBuilder
	private func _customizationOptions(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Customization")) {
			Menu {
				Button(.localized("Select Alternative Icon"), systemImage: "app.dashed") { _isAltPickerPresenting = true }
				Button(.localized("Choose from Files"), systemImage: "folder") { _isFilePickerPresenting = true }
				Button(.localized("Choose from Photos"), systemImage: "photo") { _isImagePickerPresenting = true }
			} label: {
				if let icon = appIcon {
					Image(uiImage: icon)
						.appIconStyle()
				} else {
					FRAppIconView(app: app, size: 56)
				}
			}
			
			_infoCell(.localized("Name"), desc: _temporaryOptions.appName ?? app.name) {
				SigningPropertiesView(
					title: .localized("Name"),
					initialValue: _temporaryOptions.appName ?? (app.name ?? ""),
					bindingValue: $_temporaryOptions.appName
				)
			}
			_infoCell(.localized("Identifier"), desc: _temporaryOptions.appIdentifier ?? app.identifier) {
				SigningPropertiesView(
					title: .localized("Identifier"),
					initialValue: _temporaryOptions.appIdentifier ?? (app.identifier ?? ""),
					bindingValue: $_temporaryOptions.appIdentifier
				)
			}
			_infoCell(.localized("Version"), desc: _temporaryOptions.appVersion ?? app.version) {
				SigningPropertiesView(
					title: .localized("Version"),
					initialValue: _temporaryOptions.appVersion ?? (app.version ?? ""),
					bindingValue: $_temporaryOptions.appVersion
				)
			}
		}
	}
	
	@ViewBuilder
	private func _cert() -> some View {
		NBSection(.localized("Signing")) {
			#if os(iOS) && !targetEnvironment(macCatalyst)
			if appleID.account != nil && _temporaryOptions.signingOption == .default {
				Toggle(.localized("Use Apple ID"), isOn: $useAppleID)
				if usesAppleID {
					Text(.localized("Feather removes app extensions from the signed copy when using an Apple ID profile."))
						.font(.caption).foregroundStyle(.secondary)
				}
			}
			#endif
			if let cert = _selectedCert(), !usesAppleID {
				NavigationLink {
					CertificatesView(selectedCert: $_temporaryCertificate)
				} label: {
					CertificatesCellView(
						cert: cert
					)
				}
			} else if !usesAppleID {
				NavigationLink(.localized("Select Certificate")) {
					CertificatesView(selectedCert: $_temporaryCertificate)
				}
			}
			if app.identifier != nil && _temporaryOptions.signingOption == .default {
				let title: String = _recipeIdentifier == nil ? .localized("Remember for This App") : .localized("Save Changes for This App")
				Toggle(title, isOn: $_rememberRecipe)
			}
			if let identifier = _recipeIdentifier {
				Button(.localized("Forget Saved Signing Settings"), role: .destructive) {
					do {
						try SigningRecipe.remove(for: identifier)
						if let original = app.identifier, SigningRecipe.lastTarget(for: original) == identifier {
							SigningRecipe.setLastTarget(nil, for: original)
						}
						_recipeIdentifier = nil
						_rememberRecipe = false
						_temporaryOptions = _optionsManager.options
						_temporaryCertificate = UserDefaults.standard.integer(forKey: "feather.selectedCert")
						appIcon = nil
					} catch {
						UIAlertController.showAlertWithOk(title: .localized("Error"), message: error.localizedDescription)
					}
				}
			}
		}
	}
	
	@ViewBuilder
	private func _customizationProperties(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Advanced")) {
			DisclosureGroup(.localized("Modify")) {
				NavigationLink(.localized("Existing Dylibs")) {
					SigningDylibView(
						app: app,
						options: $_temporaryOptions.optional()
					)
				}
				
				NavigationLink(.localized("Frameworks & PlugIns")) {
					SigningFrameworksView(
						app: app,
						options: $_temporaryOptions.optional()
					)
				}
				
				NavigationLink(.localized("Extensions")) {
					SigningExtensionsView(
						app: app,
						options: $_temporaryOptions
					)
				}
				NavigationLink(.localized("Entitlements") + " (BETA)") {
					SigningEntitlementsView(
						executable: Storage.shared.getAppDirectory(for: app).flatMap { Bundle(url: $0)?.executableURL },
						bindingValue: $_temporaryOptions.appEntitlementsFile
					)
				}
				NavigationLink(.localized("Edit Info.plist")) {
					SigningPlistEditor(
						title: .localized("Info.plist"),
						read: {
							if let edited = _temporaryOptions.appInfoPlist {
								return try SigningPlistEditor.dictionary(from: edited)
							}
							guard let directory = Storage.shared.getAppDirectory(for: app) else {
								throw SigningFileHandlerError.appNotFound
							}
							return try SigningPlistEditor.dictionary(from: Data(contentsOf: directory.appendingPathComponent("Info.plist")))
						},
						save: { dictionary in
							_temporaryOptions.appInfoPlist = try SigningPlistEditor.encode(dictionary)
						}
					)
				}
				NavigationLink(.localized("Tweaks")) {
					SigningTweaksView(
						options: $_temporaryOptions
					)
				}
			}
			
			NavigationLink(.localized("Properties")) {
				Form { SigningOptionsView(
					options: $_temporaryOptions,
					temporaryOptions: _optionsManager.options
				)}
				.navigationTitle(.localized("Properties"))
			}
		}
	}
	
	@ViewBuilder
	private func _infoCell<V: View>(_ title: String, desc: String?, @ViewBuilder destination: () -> V) -> some View {
		NavigationLink {
			destination()
		} label: {
			LabeledContent(title) {
				Text(desc ?? .localized("Unknown"))
			}
		}
	}
}

// MARK: - Extension: View (import)
extension SigningView {
	private func _loadRecipe() {
		guard let identifier = app.identifier else { return }
		let target = app.isSigned ? identifier : SigningRecipe.lastTarget(for: identifier)
			?? SigningPreflight.bundleIdentifier(for: app, options: _temporaryOptions) ?? identifier
		do {
			let current = try SigningRecipe.load(for: target)
			let recipe = try current ?? (target != identifier ? SigningRecipe.load(for: identifier) : nil)
			guard let recipe else { return }
			_recipeIdentifier = current == nil ? identifier : target
			_rememberRecipe = true
			_temporaryOptions = recipe.options(using: _optionsManager.options)
			appIcon = recipe.icon
			if let pinned = recipe.certificateID {
				_temporaryCertificate = certificates.firstIndex { $0.uuid == pinned } ?? -1
			}
		} catch {
			_recipeIdentifier = target
			UIAlertController.showAlertWithOk(title: .localized("Could Not Load Saved Signing Settings"), message: error.localizedDescription)
		}
	}

	private func _start() {
		guard
			_selectedCert() != nil || usesAppleID || _temporaryOptions.signingOption != .default
		else {
			UIAlertController.showAlertWithOk(
				title: .localized("No Certificate"),
				message: _temporaryCertificate == -1
					? SigningPreflight.savedCertificateUnavailable.localizedDescription
					: .localized("Please go to settings and import a valid certificate"),
				isCancel: true
			)
			return
		}

		if _temporaryOptions.signingOption == .default,
			let minimum = SigningPreflight.requiredSystemVersion(for: app, options: _temporaryOptions)
		{
			let proceed = UIAlertAction(title: .localized("Continue Signing"), style: .default) { _ in
				_confirmExtensionReplacements()
			}
			UIAlertController.showAlert(
				title: .localized("Newer iOS Required"),
				message: SigningPreflight.newerSystemRequired(minimum).localizedDescription,
				actions: [UIAlertAction(title: .localized("Cancel"), style: .cancel), proceed]
			)
			return
		}
		_confirmExtensionReplacements()
	}

	private func _confirmExtensionReplacements() {
		if _temporaryOptions.injectedAppExtensions.isEmpty {
			_beginSigning()
			return
		}

		let collisions = _extensionCollisions()
		guard !collisions.isEmpty else {
			_beginSigning()
			return
		}

		let preview = collisions
			.prefix(3)
			.map(\.displayName)
			.joined(separator: "\n")

		let message = preview.isEmpty
			? .localized("One or more extensions already exist in this app.")
			: .localized("The following extensions already exist and would be replaced:") + "\n\n" + preview

		let replace = UIAlertAction(title: .localized("Replace"), style: .destructive) { _ in
			_beginSigning()
		}
		let cancel = UIAlertAction(title: .localized("Cancel Signing"), style: .cancel)

		UIAlertController.showAlert(
			title: .localized("Extension Conflict"),
			message: message,
			actions: [cancel, replace]
		)
	}

	private func _beginSigning() {
		FeatherHaptics.action()
		_isSigning = true

		Task { @MainActor in
			defer { _isSigning = false }
			do {
				var certificate = _selectedCert()
				var options = _temporaryOptions
				#if os(iOS) && !targetEnvironment(macCatalyst)
				if usesAppleID, let identifier = SigningPreflight.bundleIdentifier(for: app, options: options) {
					certificate = try await appleID.prepare(bundleID: identifier, name: options.appName ?? app.name ?? identifier)
					options.injectedAppExtensions = []
					options.removeFiles.append(contentsOf: ["PlugIns", "Extensions"])
				}
				#endif
				let signedUUID = try await FR.signPackage(app, using: options, icon: appIcon, certificate: certificate)
				if _rememberRecipe, _temporaryOptions.signingOption == .default,
					let target = SigningPreflight.bundleIdentifier(for: app, options: _temporaryOptions)
				{
					do {
						try SigningRecipe.save(for: target, options: options, certificate: certificate, icon: appIcon)
						if !app.isSigned, let original = app.identifier {
							SigningRecipe.setLastTarget(target, for: original)
						}
					} catch {
						UIAlertController.showAlertWithOk(
							title: .localized("App Signed, but Settings Could Not Be Saved"),
							message: error.localizedDescription
						) { _finishSigning(signedUUID) }
						return
					}
				}
				_finishSigning(signedUUID)
			} catch {
				FeatherHaptics.result(.error)
				UIAlertController.showAlertWithOk(title: .localized("Error"), message: error.localizedDescription)
			}
		}
	}

	private func _finishSigning(_ uuid: String) {
		if _temporaryOptions.post_deleteAppAfterSigned, !app.isSigned {
			Storage.shared.deleteApp(for: app)
		}
		dismiss()
		if let onSigned {
			onSigned(uuid)
		} else if _temporaryOptions.post_installAppAfterSigned {
			NotificationCenter.default.post(name: .featherInstallApp, object: uuid)
		}
	}

	private func _extensionCollisions() -> [SigningExtensionCollision] {
		guard
			let appURL = Storage.shared.getAppDirectory(for: app)
		else {
			return []
		}

		let existing = _discoverExtensions(at: appURL)
		let queued = _temporaryOptions.injectedAppExtensions.map(SigningExtensionCollisionCandidate.init)

		var collisions: [SigningExtensionCollision] = []

		for queuedItem in queued {
			if let exactNameMatch = existing.first(where: { $0.folderName == queuedItem.folderName }) {
				collisions.append(SigningExtensionCollision(displayName: queuedItem.folderName, reason: .folderName, existing: exactNameMatch))
				continue
			}

			if
				let queuedBundleID = queuedItem.bundleIdentifier,
				let existingBundleIDMatch = existing.first(where: { $0.bundleIdentifier == queuedBundleID })
			{
				collisions.append(SigningExtensionCollision(displayName: queuedItem.folderName, reason: .bundleIdentifier, existing: existingBundleIDMatch))
			}
		}

		return collisions
	}

	private func _discoverExtensions(at appURL: URL) -> [SigningExtensionCollisionCandidate] {
		let directories = ["PlugIns", "Extensions"].map {
			appURL.appendingPathComponent($0)
		}

		var results: [SigningExtensionCollisionCandidate] = []

		for directory in directories {
			guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
				continue
			}

			for url in contents where url.pathExtension == "appex" {
				results.append(SigningExtensionCollisionCandidate(url: url))
			}
		}

		return results
	}
}

private struct SigningExtensionCollisionCandidate {
	let folderName: String
	let bundleIdentifier: String?

	init(url: URL) {
		self.folderName = url.lastPathComponent
		self.bundleIdentifier = (NSDictionary(contentsOf: url.appendingPathComponent("Info.plist"))?["CFBundleIdentifier"] as? String)
	}
}

private struct SigningExtensionCollision {
	enum Reason {
		case folderName
		case bundleIdentifier
	}

	let displayName: String
	let reason: Reason
	let existing: SigningExtensionCollisionCandidate
}
