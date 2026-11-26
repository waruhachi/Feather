import Foundation
import Security

enum CertificateRevocation {
	enum Status: Equatable {
		case valid
		case revoked
		case unavailable
	}

	/// Security validates the response and its issuer. A network or trust error
	/// other than explicit revocation leaves the certificate status unknown.
	static func check(p12: URL, password: String) -> Status {
		guard let data = try? Data(contentsOf: p12), !data.isEmpty else { return .unavailable }

		var options: [String: Any] = [kSecImportExportPassphrase as String: password]
		if #available(iOS 18.0, macOS 15.0, *) {
			options[kSecImportToMemoryOnly as String] = true
		}

		var imported: CFArray?
		guard SecPKCS12Import(data as CFData, options as CFDictionary, &imported) == errSecSuccess,
			let items = imported as? [[String: Any]],
			let certificates = items.first?[kSecImportItemCertChain as String] as? [SecCertificate],
			!certificates.isEmpty,
			let revocation = SecPolicyCreateRevocation(
				CFOptionFlags(kSecRevocationOCSPMethod | kSecRevocationRequirePositiveResponse)
			)
		else { return .unavailable }

		let policies = [SecPolicyCreateBasicX509(), revocation]
		var trust: SecTrust?
		guard SecTrustCreateWithCertificates(certificates as CFArray, policies as CFArray, &trust) == errSecSuccess,
			let trust,
			SecTrustSetNetworkFetchAllowed(trust, true) == errSecSuccess
		else { return .unavailable }

		var error: CFError?
		if SecTrustEvaluateWithError(trust, &error) { return .valid }
		if let error,
			CFEqual(CFErrorGetDomain(error), kCFErrorDomainOSStatus),
			CFErrorGetCode(error) == Int(errSecCertificateRevoked)
		{
			return .revoked
		}

		return .unavailable
	}
}
