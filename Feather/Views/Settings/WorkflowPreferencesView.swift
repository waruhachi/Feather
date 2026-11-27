import NimbleViews
import SwiftUI
import UIKit

enum FeatherHaptics {
	static func navigation() {
		guard UserDefaults.standard.bool(forKey: "Feather.navigationHaptics") else { return }
		UISelectionFeedbackGenerator().selectionChanged()
	}

	static func action() {
		guard UserDefaults.standard.object(forKey: "Feather.actionHaptics") as? Bool ?? true else { return }
		UIImpactFeedbackGenerator(style: .light).impactOccurred()
	}

	static func result(_ value: UINotificationFeedbackGenerator.FeedbackType) {
		guard UserDefaults.standard.object(forKey: "Feather.resultHaptics") as? Bool ?? true else { return }
		UINotificationFeedbackGenerator().notificationOccurred(value)
	}
}

enum LibraryImportAction: String, CaseIterable {
	case menu, files, url

	var title: String {
		switch self {
		case .menu: "Choose Each Time"
		case .files: "Import from Files"
		case .url: "Import from URL"
		}
	}
}

struct WorkflowPreferencesView: View {
	@AppStorage("Feather.navigationHaptics") private var navigationHaptics = false
	@AppStorage("Feather.actionHaptics") private var actionHaptics = true
	@AppStorage("Feather.resultHaptics") private var resultHaptics = true
	@AppStorage("Feather.openImportOnLaunch") private var openImportOnLaunch = false
	@AppStorage("Feather.openImportOnReopen") private var openImportOnReopen = false
	@AppStorage(ImportSigning.preferenceKey) private var signImports = false
	@AppStorage(InstallShortcut.preferenceKey) private var installShortcut = ""
	@AppStorage("Feather.dismissInstallAfterFinish") private var dismissInstallAfterFinish = false
	@AppStorage("Feather.openImportAfterInstall") private var openImportAfterInstall = false
	@AppStorage("Feather.libraryImportAction") private var importAction = LibraryImportAction.menu

	var body: some View {
		NBList(.localized("Workflow")) {
			Section(.localized("Import")) {
				Picker(.localized("Library Import Action"), selection: $importAction) {
					ForEach(LibraryImportAction.allCases, id: \.self) { action in
						Text(.localized(action.title)).tag(action)
					}
				}
				Toggle(.localized("Open IPA Picker on Launch"), isOn: $openImportOnLaunch)
				Toggle(.localized("Open IPA Picker on Reopen"), isOn: $openImportOnReopen)
				Toggle(.localized("Auto-Sign Imports with Saved Settings"), isOn: $signImports)
			}
			Section(.localized("Installation")) {
				Toggle(.localized("Dismiss Install Panel After Finishing"), isOn: $dismissInstallAfterFinish)
				Toggle(.localized("Open IPA Picker After Installing"), isOn: $openImportAfterInstall)
			}
			Section {
				TextField(.localized("Install Shortcut Name"), text: $installShortcut)
					.autocorrectionDisabled()
			} footer: {
				Text(.localized("Optional. When you sign and install an app, Feather runs this shortcut with Installation as input. After a verified install, Feather runs it again with Installed."))
			}
			Section(.localized("Haptics")) {
				Toggle(.localized("Navigation"), isOn: $navigationHaptics)
				Toggle(.localized("Actions"), isOn: $actionHaptics)
				Toggle(.localized("Results"), isOn: $resultHaptics)
			}
		}
	}
}
