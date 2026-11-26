//
//  OnDevicePairingSection.swift
//  Feather
//
//  Adapted from RyukSign by Ryuk (GPL-3.0).
//

#if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
import SwiftUI

@available(iOS 27.0, *)
struct OnDevicePairingSection: View {
	@ObservedObject private var _pairing = OnDevicePairing.shared
	@Binding var hasPairingFile: Bool
	@State private var _isResetPresenting = false
	@State private var _resetError: String?

	var body: some View {
		Section {
			switch _pairing.state {
			case .waiting:
				HStack(spacing: 12) {
					ProgressView()
					Text(.localized("Waiting for Settings"))
				}
				_cancelButton
			case .pin(let pin):
				LabeledContent(.localized("PIN")) {
					Text(pin)
						.font(.title2.monospaced().weight(.semibold))
						.textSelection(.enabled)
				}
				_cancelButton
			default:
				if hasPairingFile {
					Label {
						Text(.localized("Paired"))
					} icon: {
						Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
					}
					Button(.localized("Reset Pairing"), systemImage: "arrow.counterclockwise", role: .destructive) {
						_isResetPresenting = true
					}
				} else {
					Button(.localized("Pair This Device"), systemImage: "link.badge.plus") {
						_pairing.start()
					}
				}
			}
		} header: {
			Text(.localized("On-Device Pairing"))
		} footer: {
			switch _pairing.state {
			case .failed(let message):
				Text(message)
			case .pin:
				Text(.localized("Enter this PIN in Settings."))
			case .waiting:
				Text(.localized("Open Settings › Privacy & Security › Developer Mode and tap Pair with Feather."))
			default:
				if !hasPairingFile {
					Text(.localized("Requires Developer Mode. Creates a pairing file on this iPhone."))
				}
			}
		}
		.confirmationDialog(.localized("Reset Pairing"), isPresented: $_isResetPresenting, titleVisibility: .visible) {
			Button(.localized("Reset"), role: .destructive) {
				do {
					try _pairing.reset()
					hasPairingFile = false
				} catch {
					_resetError = error.localizedDescription
				}
			}
		} message: {
			Text(.localized("You'll need to pair again to install with idevice."))
		}
		.alert(.localized("Couldn’t reset pairing"), isPresented: Binding(
			get: { _resetError != nil },
			set: { if !$0 { _resetError = nil } }
		)) {
			Button(.localized("OK"), role: .cancel) {}
		} message: {
			Text(_resetError ?? "")
		}
		.onChange(of: _pairing.state) { _, state in
			if state == .paired { hasPairingFile = true }
		}
	}

	private var _cancelButton: some View {
		Button(.localized("Cancel"), role: .destructive) {
			_pairing.cancel()
		}
	}
}

#endif
