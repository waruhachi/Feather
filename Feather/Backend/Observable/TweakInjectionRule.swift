import Foundation

struct TweakInjectionRule: Codable, Equatable {
	enum Target: String, Codable, CaseIterable {
		case inherited = "Use Signing Defaults"
		case app = "App Only"
		case extensions = "Extensions Only"
		case both = "App and Extensions"
	}

	var path: Options.InjectPath?
	var folder: Options.InjectFolder?
	var target: Target = .inherited
	var weak = true

	func includesApp() -> Bool { target != .extensions }

	func includesExtensions(defaultValue: Bool) -> Bool {
		switch target {
		case .inherited: defaultValue
		case .app: false
		case .extensions, .both: true
		}
	}
}
