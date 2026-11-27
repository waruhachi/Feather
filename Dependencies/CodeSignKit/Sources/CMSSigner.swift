//
//  CMSSigner.swift
//  CodeSignKit
//
//  Created by Magesh K on 28/08/26.
//  Copyright © 2026 CodeSignKit. All rights reserved.
//

import Foundation
import Crypto
import _CryptoExtras
import SwiftASN1

public final class CMSSigner {

    // Apple Root Certificate (PEM)
    public static let AppleRootCertPEM = """
    -----BEGIN CERTIFICATE-----
    MIIEuzCCA6OgAwIBAgIBAjANBgkqhkiG9w0BAQUFADBiMQswCQYDVQQGEwJVUzET
    MBEGA1UEChMKQXBwbGUgSW5jLjEmMCQGA1UECxMdQXBwbGUgQ2VydGlmaWNhdGlv
    biBBdXRob3JpdHkxFjAUBgNVBAMTDUFwcGxlIFJvb3QgQ0EwHhcNMDYwNDI1MjE0
    MDM2WhcNMzUwMjA5MjE0MDM2WjBiMQswCQYDVQQGEwJVUzETMBEGA1UEChMKQXBw
    bGUgSW5jLjEmMCQGA1UECxMdQXBwbGUgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkx
    FjAUBgNVBAMTDUFwcGxlIFJvb3QgQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAw
    ggEKAoIBAQDkkakJH5HbHkdQ6wXtXnmELes2oldMVeyLGYne+Uts9QerIjAC6Bg+
    +FAJ039BqJj50cpmnCRrEdCju+QbKsMflZ56DKRHi1vUFjczy8QPTc4UadHJGXL1
    XQ7Vf1+b8iUDulWPTV0N8WQ1IxVLFVkds5T39pyez1C6wVhQZ48ItCD3y6wsIG9w
    tj8BMIy3Q88PnT3zK0koGsj+zrW5DtleHNbLPbU6rfQPDgCSC7EhFi501TwN22IW
    q6NxkkdTVcGvL0Gz+PvjcM3mo0xFfh9Ma1CWQYnEdGILEINBhzOKgbEwWOxaBDKM
    aLOPHd5lc/9nXmW8Sdh2nzMUZaF3lMktAgMBAAGjggF6MIIBdjAOBgNVHQ8BAf8E
    BAMCAQYwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQUK9BpR5R2Cf70a40uQKb3
    R01/CF4wHwYDVR0jBBgwFoAUK9BpR5R2Cf70a40uQKb3R01/CF4wggERBgNVHSAE
    ggEIMIIBBDCCAQAGCSqGSIb3Y2QFATCB8jAqBggrBgEFBQcCARYeaHR0cHM6Ly93
    d3cuYXBwbGUuY29tL2FwcGxlY2EvMIHDBggrBgEFBQcCAjCBthqBs1JlbGlhbmNl
    IG9uIHRoaXMgY2VydGlmaWNhdGUgYnkgYW55IHBhcnR5IGFzc3VtZXMgYWNjZXB0
    YW5jZSBvZiB0aGUgdGhlbiBhcHBsaWNhYmxlIHN0YW5kYXJkIHRlcm1zIGFuZCBj
    b25kaXRpb25zIG9mIHVzZSwgY2VydGlmaWNhdGUgcG9saWN5IGFuZCBjZXJ0aWZp
    Y2F0aW9uIHByYWN0aWNlIHN0YXRlbWVudHMuMA0GCSqGSIb3DQEBBQUAA4IBAQBc
    NplMLXi37Yyb3PN3m/J20ncwT8EfhYOFG5k9RzfyqZtAjizUsZAS2L70c5vu0mQP
    y3lPNNiiPvl4/2vIB+x9OYOLUyDTOMSxv5pPCmv/K/xZpwUJfBdAVhEedNO3iyM7
    R6PVbyTi69G3cN8PReEnyvFteO3ntRcXqNx+IjXKJdXZD9Zr1KIkIxH3oayPc4Fg
    xhtbCS+SsvhESPBgOJ4V9T0mZyCKM2r3DYLP3uujL/lTaltkwGMzd/c6ByxW69oP
    IQ7aunMZT7XZNn/Bh1XZp5m5MkL72NVxnn6hUrcbvZNCJBIqxw8dtk2cXmPIS4AX
    UKqK1drk/NAJBzewdXUh
    -----END CERTIFICATE-----
    """

    // Apple WWDR G3 Certificate (PEM)
    public static let AppleWWDRCertPEM = """
    -----BEGIN CERTIFICATE-----
    MIIEUTCCAzmgAwIBAgIQfK9pCiW3Of57m0R6wXjF7jANBgkqhkiG9w0BAQsFADBi
    MQswCQYDVQQGEwJVUzETMBEGA1UEChMKQXBwbGUgSW5jLjEmMCQGA1UECxMdQXBw
    bGUgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkxFjAUBgNVBAMTDUFwcGxlIFJvb3Qg
    Q0EwHhcNMjAwMjE5MTgxMzQ3WhcNMzAwMjIwMDAwMDAwWjB1MUQwQgYDVQQDDDtB
    cHBsZSBXb3JsZHdpZGUgRGV2ZWxvcGVyIFJlbGF0aW9ucyBDZXJ0aWZpY2F0aW9u
    IEF1dGhvcml0eTELMAkGA1UECwwCRzMxEzARBgNVBAoMCkFwcGxlIEluYy4xCzAJ
    BgNVBAYTAlVTMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA2PWJ/KhZ
    C4fHTJEuLVaQ03gdpDDppUjvC0O/LYT7JF1FG+XrWTYSXFRknmxiLbTGl8rMPPbW
    BpH85QKmHGq0edVny6zpPwcR4YS8Rx1mjjmi6LRJ7TrS4RBgeo6TjMrA2gzAg9Dj
    +ZHWp4zIwXPirkbRYp2SqJBgN31ols2N4Pyb+ni743uvLRfdW/6AWSN1F7gSwe0b
    5TTO/iK1nkmw5VW/j4SiPKi6xYaVFuQAyZ8D0MyzOhZ71gVcnetHrg21LYwOaU1A
    0EtMOwSejSGxrC5DVDDOwYqGlJhL32oNP/77HK6XF8J4CjDgXx9UO0m3JQAaN4LS
    VpelUkl8YDib7wIDAQABo4HvMIHsMBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0j
    BBgwFoAUK9BpR5R2Cf70a40uQKb3R01/CF4wRAYIKwYBBQUHAQEEODA2MDQGCCsG
    AQUFBzABhihodHRwOi8vb2NzcC5hcHBsZS5jb20vb2NzcDAzLWFwcGxlcm9vdGNh
    MC4GA1UdHwQnMCUwI6AhoB+GHWh0dHA6Ly9jcmwuYXBwbGUuY29tL3Jvb3QuY3Js
    MB0GA1UdDgQWBBQJ/sAVkPmvZAqSErkmKGMMl+ynsjAOBgNVHQ8BAf8EBAMCAQYw
    EAYKKoZIhvdjZAYCAQQCBQAwDQYJKoZIhvcNAQELBQADggEBAK1lE+j24IF3RAJH
    Qr5fpTkg6mKp/cWQyXMT1Z6b0KoPjY3L7QHPbChAW8dVJEH4/M/BtSPp3Ozxb8qA
    HXfCxGFJJWevD8o5Ja3T43rMMygNDi6hV0Bz+uZcrgZRKe3jhQxPYdwyFot30ETK
    XXIDMUacrptAGvr04NM++i+MZp+XxFRZ79JI9AeZSWBZGcfdlNHAwWx/eCHvDOs7
    bJmCS1JgOLU5gm3sUjFTvg+RTElJdI+mUcuER04ddSduvfnSXPN/wmwLCTbiZOTC
    NwMUGdXqapSqqdv+9poIZ4vvK7iqF0mDr8/LvOnP6pVxsLRFoszlh6oKw0E6eVza
    UDSdlTs=
    -----END CERTIFICATE-----
    """

    public static let appleCDHashesOID  = "1.2.840.113635.100.9.1"
    public static let appleCDHashes2OID = "1.2.840.113635.100.9.2"

    private let p12Data: Data
    private let password: String

    public init(p12Data: Data, password: String = "") {
        self.p12Data = p12Data
        self.password = password
    }

    public var leafCertificate: X509Certificate? {
        guard let parser = try? PKCS12Parser(p12Data: p12Data, password: password) else {
            return nil
        }
        return parser.leafCertificate
    }

    public func getLeafCertificateSHA1() -> Data? {
        return leafCertificate?.sha1Fingerprint
    }

    public func sign(codeDirectoryData: Data, timestampToken: Data? = nil) throws -> Data {
        let parser = try PKCS12Parser(p12Data: p12Data, password: password)

        guard let leafCert = parser.leafCertificate,
              let rsaPrivateKey = parser.rsaPrivateKey else {
            throw CodeSignerError.certificateError("Missing certificate or private key in PKCS#12")
        }

        // 1. Compute CDHash (SHA-256)
        let cdHash = Data(SHA256.hash(data: codeDirectoryData))

        // 2. Build SignedAttributes
        // 2a. Content Type (1.2.840.113549.1.9.3) -> data (1.2.840.113549.1.7.1)
        let attrContentType = ASN1Helper.sequence(
            ASN1Helper.oidContentType +
            ASN1Helper.set(ASN1Helper.oidData)
        )

        // 2b. Signing Time (1.2.840.113549.1.9.5) -> UTCTime
        let attrSigningTime = ASN1Helper.sequence(
            ASN1Helper.oidSigningTime +
            ASN1Helper.set(ASN1Helper.utcTime(Date()))
        )

        // 2c. Message Digest (1.2.840.113549.1.9.4) -> SHA-256 of codeDirectoryData
        let attrMessageDigest = ASN1Helper.sequence(
            ASN1Helper.oidMessageDigest +
            ASN1Helper.set(ASN1Helper.octetString(cdHash))
        )

        // 2d. Apple CDHashes 2 (1.2.840.113635.100.9.2) -> SET OF SEQUENCE { sha256 OID, OCTET STRING cdHash }
        let cdHashSeq = ASN1Helper.sequence(
            ASN1Helper.oidSHA256 +
            ASN1Helper.octetString(cdHash)
        )
        let attrAppleCDHashes2 = ASN1Helper.sequence(
            ASN1Helper.oidAppleCDHashes2 +
            ASN1Helper.set(cdHashSeq)
        )

        // 2e. Apple CDHashes 1 (1.2.840.113635.100.9.1) -> OCTET STRING (XML plist containing cdhashes)
        let truncatedCDHash = cdHash.prefix(20)
        let plistDict: [String: any Sendable] = ["cdhashes": [truncatedCDHash]]
        let plistData = (try? PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)) ?? Data()
        let attrAppleCDHashes1 = ASN1Helper.sequence(
            ASN1Helper.oidAppleCDHashes +
            ASN1Helper.set(ASN1Helper.octetString(plistData))
        )

        // 3. Sort signed attributes in ascending DER lexicographical order
        let rawAttributes = [attrContentType, attrSigningTime, attrMessageDigest, attrAppleCDHashes2, attrAppleCDHashes1]
        let sortedAttributes = rawAttributes.sorted { $0.lexicographicallyPrecedes($1) }

        var signedAttrsContent = Data()
        for attr in sortedAttributes {
            signedAttrsContent.append(attr)
        }

        // The bytes to sign are encoded as a DER SET (tag 0x31)
        let signedAttrsSetDER = ASN1Helper.set(signedAttrsContent)

        // 4. Compute RSA-SHA256 signature (PKCS#1 v1.5) over signedAttrsSetDER
        let digestToSign = SHA256.hash(data: signedAttrsSetDER)
        let signatureData: Data
        do {
            let sig = try rsaPrivateKey.signature(for: digestToSign, padding: .insecurePKCS1v1_5)
            signatureData = sig.rawRepresentation
        } catch {
            throw CodeSignerError.signingFailed("Failed to compute RSA signature: \(error.localizedDescription)")
        }

        // 5. Build SignerInfo
        // sid: IssuerAndSerialNumber: SEQUENCE { issuer Name, serialNumber CertificateSerialNumber }
        let issuerAndSerial = ASN1Helper.sequence(leafCert.issuerDER + leafCert.serialNumberDER)
        let digestAlg = ASN1Helper.algorithmIdentifier(oidData: ASN1Helper.oidSHA256, hasNullParam: false)
        let signedAttrsContextual = ASN1Helper.contextual(0, content: signedAttrsContent, constructed: true)
        let sigAlg = ASN1Helper.algorithmIdentifier(oidData: ASN1Helper.oidSha256WithRSAEncryption, hasNullParam: true)
        let sigOctet = ASN1Helper.octetString(signatureData)

        var signerInfoContent = ASN1Helper.integer(1) + // version 1
                                issuerAndSerial +
                                digestAlg +
                                signedAttrsContextual +
                                sigAlg +
                                sigOctet

        // 5b. Unsigned Attributes [1] IMPLICIT (RFC 3161 Timestamp Token if present)
        if let timestampToken, !timestampToken.isEmpty {
            let attrTimestamp = ASN1Helper.sequence(
                ASN1Helper.oidTimeStampToken +
                ASN1Helper.set(timestampToken)
            )
            let unsignedAttrsContextual = ASN1Helper.contextual(1, content: attrTimestamp, constructed: true)
            signerInfoContent.append(unsignedAttrsContextual)
        }

        let signerInfo = ASN1Helper.sequence(signerInfoContent)

        // 6. Build Certificates Set [0] IMPLICIT
        var allCertsContent = leafCert.rawDER
        if !parser.intermediateCertificates.isEmpty {
            for ca in parser.intermediateCertificates {
                allCertsContent.append(ca.rawDER)
            }
        } else {
            if let wwdrDER = ASN1Helper.decodePEM(CMSSigner.AppleWWDRCertPEM) {
                allCertsContent.append(wwdrDER)
            }
            if let rootDER = ASN1Helper.decodePEM(CMSSigner.AppleRootCertPEM) {
                allCertsContent.append(rootDER)
            }
        }
        let certificatesContextual = ASN1Helper.contextual(0, content: allCertsContent, constructed: true)

        // 7. Build EncapsulatedContentInfo (detached: eContent omitted)
        let encapContentInfo = ASN1Helper.sequence(
            ASN1Helper.oidData
        )

        // 8. Build SignedData
        let signedData = ASN1Helper.sequence(
            ASN1Helper.integer(1) + // version 1
            ASN1Helper.set(digestAlg) + // digestAlgorithms
            encapContentInfo +
            certificatesContextual +
            ASN1Helper.set(signerInfo)
        )

        // 9. Build ContentInfo
        let contentInfo = ASN1Helper.sequence(
            ASN1Helper.oidSignedData +
            ASN1Helper.contextual(0, content: signedData, constructed: true)
        )

        // 10. Wrap in BlobWrapper (0xfade0b01)
        let totalWrapperSize = 8 + contentInfo.count
        var wrapper = Data(count: totalWrapperSize)
        wrapper.writeUInt32BigEndian(CodeSigningConstants.CSMAGIC_BLOBWRAPPER, at: 0)
        wrapper.writeUInt32BigEndian(UInt32(totalWrapperSize), at: 4)
        wrapper.replaceSubrange(8..<totalWrapperSize, with: contentInfo)

        return wrapper
    }
}
