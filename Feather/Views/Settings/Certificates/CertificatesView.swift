//
//  CertificatesView.swift
//  Feather
//
//  Created by samara on 15.04.2025.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct CertificatesView: View {
	@AppStorage("feather.selectedCert") private var _storedSelectedCert: Int = 0
	
	@State private var _isAddingPresenting = false
	@State private var _isRenamingPresenting = false
	@State private var _isSelectedInfoPresenting: CertificatePair?
	@State private var _certToRename: CertificatePair?
	@State private var _newNickname: String = ""
	@State private var search = ""
	@AppStorage("Feather.certificateSort") private var sort = CertificateSort.newest
	@AppStorage("Feather.pinnedCertificate") private var pinnedCertificate = ""

	private enum CertificateSort: String, CaseIterable {
		case newest = "Newest"
		case name = "Name"
		case expiration = "Expiration"
	}

	private var visibleCertificates: [(offset: Int, element: CertificatePair)] {
		let candidates = _certificates.enumerated().map { index, cert in
			let profile = Storage.shared.getProvisionFileDecoded(for: cert)
			return (index, cert, cert.nickname ?? profile?.Name ?? "", profile?.TeamName ?? "", profile?.ExpirationDate)
		}.filter { item in
			search.isEmpty || item.2.localizedCaseInsensitiveContains(search) || item.3.localizedCaseInsensitiveContains(search)
		}
		return candidates.sorted { lhs, rhs in
			let lhsPinned = lhs.1.uuid == pinnedCertificate
			let rhsPinned = rhs.1.uuid == pinnedCertificate
			if lhsPinned != rhsPinned { return lhsPinned }
			switch sort {
			case .newest: return lhs.0 < rhs.0
			case .name:
				let order = lhs.2.localizedStandardCompare(rhs.2)
				return order == .orderedSame ? lhs.0 < rhs.0 : order == .orderedAscending
			case .expiration:
				let left = lhs.4 ?? .distantFuture
				let right = rhs.4 ?? .distantFuture
				return left == right ? lhs.0 < rhs.0 : left < right
			}
		}.map { ($0.0, $0.1) }
	}

	// MARK: Fetch
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var _certificates: FetchedResults<CertificatePair>
	
	//
	private var _bindingSelectedCert: Binding<Int>?
	private var _selectedCertBinding: Binding<Int> {
		_bindingSelectedCert ?? $_storedSelectedCert
	}
	
	init(selectedCert: Binding<Int>? = nil) {
		self._bindingSelectedCert = selectedCert
	}
	
	// MARK: Body
	var body: some View {
		NBGrid {
			ForEach(visibleCertificates, id: \.element.objectID) { index, cert in
				_cellButton(for: cert, at: index)
			}
		}
		.navigationTitle(.localized("Certificates"))
		.searchable(text: $search, prompt: Text(.localized("Search certificates")))
		.overlay {
			if _certificates.isEmpty {
				if #available(iOS 17, *) {
					ContentUnavailableView {
						Label(.localized("No Certificates"), systemImage: "questionmark.folder.fill")
					} description: {
						Text(.localized("Get started signing by importing your first certificate."))
					} actions: {
						Button {
							_isAddingPresenting = true
						} label: {
							NBButton(.localized("Import"), style: .text)
						}
					}
				}
			}
		}
		.toolbar {
			ToolbarItem(placement: .topBarTrailing) {
				Menu {
					Picker(.localized("Sort"), selection: $sort) {
						ForEach(CertificateSort.allCases, id: \.self) { choice in
							Text(.localized(choice.rawValue)).tag(choice)
						}
					}
				} label: {
					Label(.localized("Sort"), systemImage: "arrow.up.arrow.down")
				}
			}
			if _bindingSelectedCert == nil {
				NBToolbarButton(
					systemImage: "plus",
					style: .icon,
					placement: .topBarTrailing
				) {
					_isAddingPresenting = true
				}
			}
		}
		.sheet(item: $_isSelectedInfoPresenting) { cert in
			CertificatesInfoView(cert: cert)
		}
		.sheet(isPresented: $_isAddingPresenting) {
			CertificatesAddView()
				.presentationDetents([.medium])
		}
		.alert(.localized("Change Nickname"), isPresented: $_isRenamingPresenting, presenting: _certToRename) { cert in
			TextField(.localized("Nickname"), text: $_newNickname)
			Button(.localized("Cancel"), role: .cancel) { }
			Button(.localized("OK")) {
				cert.nickname = _newNickname.isEmpty ? nil : _newNickname
				Storage.shared.saveContext()
			}
		}
	}
}

// MARK: - View extension
extension CertificatesView {
	@ViewBuilder
	private func _cellButton(for cert: CertificatePair, at index: Int) -> some View {
		let cornerRadius = {
			if #available(iOS 26.0, *) {
				28.0
			} else {
				10.5
			}
		}()
		
		Button {
			_selectedCertBinding.wrappedValue = index
		} label: {
			CertificatesCellView(
				cert: cert
			)
			.padding()
			.background(
				RoundedRectangle(cornerRadius: cornerRadius)
					.fill(Color(uiColor: .quaternarySystemFill))
			)
			.overlay(
				RoundedRectangle(cornerRadius: cornerRadius)
					.strokeBorder(
						_selectedCertBinding.wrappedValue == index ? Color.accentColor : Color.clear,
						lineWidth: 2
					)
			)
			.contextMenu {
				_contextActions(for: cert)
				if cert.isDefault != true {
					Divider()
					_actions(for: cert)
				}
			}
			.transaction {
				$0.animation = nil
			}
		}
		.buttonStyle(.plain)
	}
	
	@ViewBuilder
	private func _actions(for cert: CertificatePair) -> some View {
		Button(.localized("Delete"), systemImage: "trash", role: .destructive) {
			Storage.shared.deleteCertificate(for: cert)
		}
	}
	
	@ViewBuilder
	private func _contextActions(for cert: CertificatePair) -> some View {
		Button(.localized("Get Info"), systemImage: "info.circle") {
			_isSelectedInfoPresenting = cert
		}
		Button(.localized("Change Nickname"), systemImage: "pencil") {
			_newNickname = cert.nickname ?? ""
			_certToRename = cert
			_isRenamingPresenting = true
		}
		if let uuid = cert.uuid {
			Button(.localized(pinnedCertificate == uuid ? "Unpin" : "Move to Top"), systemImage: "arrow.up.to.line") {
				pinnedCertificate = pinnedCertificate == uuid ? "" : uuid
			}
		}
		Divider()
		Button(.localized("Check Revocation"), systemImage: "person.text.rectangle") {
			Storage.shared.revokagedCertificate(for: cert)
		}
	}
}
