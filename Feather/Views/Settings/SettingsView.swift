//
//  SettingsView.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//

import SwiftUI
import NimbleViews
import UIKit
import Darwin
import IDeviceSwift

// MARK: - View
struct SettingsView: View {
	@AppStorage("feather.selectedCert") private var _storedSelectedCert: Int = 0
	@State private var _currentIcon: String? = UIApplication.shared.alternateIconName
	
	// MARK: Fetch
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var _certificates: FetchedResults<CertificatePair>
	
	private var selectedCertificate: CertificatePair? {
		guard
			_storedSelectedCert >= 0,
			_storedSelectedCert < _certificates.count
		else {
			return nil
		}
		return _certificates[_storedSelectedCert]
	}

    
	@State private var _showCertificates = false
	private let _githubUrl = "https://github.com/claration/Feather"
    
	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Settings")) {
			Form {
				_feedback()
                
				Section {
					NavigationLink(destination: AppearanceView()) {
						Label(.localized("Appearance"), systemImage: "paintbrush")
					}
					NavigationLink(destination: AppIconView(currentIcon: $_currentIcon)) {
						Label(.localized("App Icon"), systemImage: "app.badge")
					}
				}
                
				NBSection(.localized("Certificates")) {
                    
					if let cert = selectedCertificate {
						CertificatesCellView(cert: cert)
					} else {
						Text(.localized("No Certificate"))
							.font(.footnote)
							.foregroundColor(.disabled())
					}
					NavigationLink(destination: CertificatesView()) {
						Label(.localized("Certificates"), systemImage: "checkmark.seal")
					}
					#if os(iOS) && !targetEnvironment(macCatalyst)
					NavigationLink(destination: AppleIDSettingsView()) {
						Label(.localized("Apple ID"), systemImage: "person.crop.circle")
					}
					#endif
                 
				} footer: {
					Text(.localized("Add and manage certificates used for signing applications."))
				}
                
				NBSection(.localized("Features")) {
					#if !targetEnvironment(macCatalyst)
						NavigationLink(destination: HostedSelfUpdateView()) {
							Label(.localized("Feather Updates"), systemImage: "arrow.down.app")
						}
						NavigationLink(destination: LibraryUpdateSettingsView()) {
							Label(.localized("Library Updates"), systemImage: "arrow.triangle.2.circlepath")
						}
					#endif
					NavigationLink(destination: WorkflowPreferencesView()) {
						Label(.localized("Workflow"), systemImage: "slider.horizontal.3")
					}
					NavigationLink(destination: TweakLibraryView()) {
						Label(.localized("Tweak Manager"), systemImage: "shippingbox")
					}
					NavigationLink(destination: ActivityLogView()) {
						Label(.localized("Activity Log"), systemImage: "list.bullet.rectangle")
					}
					NavigationLink(destination: WorkspaceFilesView()) {
						Label(.localized("File Manager"), systemImage: "folder")
					}
					NavigationLink(destination: FileTransferView()) {
						Label(.localized("File Transfer"), systemImage: "wifi")
					}
					NavigationLink(destination: FeatherBackupView()) {
						Label(.localized("Backup & Restore"), systemImage: "externaldrive")
					}
					NavigationLink(destination: LibraryStorageView()) {
						Label(.localized("Storage"), systemImage: "internaldrive")
					}
					NavigationLink(destination: ConfigurationView()) {
						Label(.localized("Signing Options"), systemImage: "signature")
					}
					NavigationLink(destination: ArchiveView()) {
						Label(.localized("Archive & Compression"), systemImage: "archivebox")
					}
					NavigationLink(destination: InstallationView()) {
						Label(.localized("Installation"), systemImage: "arrow.down.circle")
					}
				} footer: {
					Text(.localized("Configure the apps way of installing, its zip compression levels, and custom modifications to apps."))
				}
                
				_directories()
                
				Section {
					NavigationLink(destination: ResetView()) {
						Label(.localized("Reset"), systemImage: "trash")
					}
				} footer: {
					Text(.localized("Reset the applications sources, certificates, apps, and general contents."))
				}
			}
			.navigationDestination(isPresented: $_showCertificates) { CertificatesView() }
			.onReceive(FeatherAlerts.shared.$route) { route in
				guard route == .certificates else { return }
				Task { @MainActor in
					_showCertificates = true
					FeatherAlerts.shared.clear(.certificates)
				}
			}
		}
	}
}

// MARK: - View extension
extension SettingsView {
	@ViewBuilder
	private func _feedback() -> some View {
		Section {
			NavigationLink(destination: AboutView()) {
				Label {
					Text(verbatim: .localized("About %@", arguments: Bundle.main.name))
				} icon: {
					FRAppIconView(size: 23)
				}
			}
            
			Button(.localized("Submit Feedback"), systemImage: "safari") {
				UIApplication.open(URL(string: "\(_githubUrl)/issues/new/choose")!)
			}
			Button(.localized("GitHub Repository"), systemImage: "safari") {
				UIApplication.open(_githubUrl)
			}
		} footer: {
			Text(.localized("If any issues occur within the app please report it via the GitHub repository. When submitting an issue, make sure to submit detailed information."))
		}
	}
    
	@ViewBuilder
	private func _directories() -> some View {
		NBSection(.localized("Misc")) {
			Button(.localized("Open Documents"), systemImage: "folder") {
				UIApplication.open(URL.documentsDirectory.toSharedDocumentsURL()!)
			}
			Button(.localized("Open Archives"), systemImage: "folder") {
				UIApplication.open(FileManager.default.archives.toSharedDocumentsURL()!)
			}
			Button(.localized("Open Certificates"), systemImage: "folder") {
				UIApplication.open(FileManager.default.certificates.toSharedDocumentsURL()!)
			}
		} footer: {
			Text(.localized("All of the apps files are contained in the documents directory, here are some quick links to these."))
		}
	}
}
