//
//  ASN1Helper.swift
//  CodeSignKit
//
//  Created by Magesh K on 28/08/26.
//  Copyright © 2026 CodeSignKit. All rights reserved.
//

import Foundation
import SwiftASN1
import Crypto

public struct ASN1Helper {

    // Helper to encode dotted OID string to DER Data via SwiftASN1
    public static func encodeOID(_ oidString: String) -> Data {
        let parts = oidString.split(separator: ".").compactMap { UInt(String($0)) }
        guard let oid = try? ASN1ObjectIdentifier(elements: parts) else { return Data() }
        var serializer = DER.Serializer()
        try! serializer.serialize(oid)
        return Data(serializer.serializedBytes)
    }

    // Common Pre-encoded OIDs (including tag 0x06)
    public static let oidData                          = encodeOID("1.2.840.113549.1.7.1")
    public static let oidSignedData                    = encodeOID("1.2.840.113549.1.7.2")
    public static let oidEncryptedData                 = encodeOID("1.2.840.113549.1.7.6")

    public static let oidContentType                   = encodeOID("1.2.840.113549.1.9.3")
    public static let oidMessageDigest                 = encodeOID("1.2.840.113549.1.9.4")
    public static let oidSigningTime                   = encodeOID("1.2.840.113549.1.9.5")
    public static let oidTimeStampToken                = encodeOID("1.2.840.113549.1.9.16.2.14")

    public static let oidSHA256                        = encodeOID("2.16.840.1.101.3.4.2.1")
    public static let oidSHA1                          = encodeOID("1.3.14.3.2.26")
    public static let oidRsaEncryption                 = encodeOID("1.2.840.113549.1.1.1")
    public static let oidSha256WithRSAEncryption       = encodeOID("1.2.840.113549.1.1.11")

    public static let oidAppleCDHashes                 = encodeOID("1.2.840.113635.100.9.1")
    public static let oidAppleCDHashes2                = encodeOID("1.2.840.113635.100.9.2")

    // PKCS#12 SafeBag OIDs
    public static let oidKeyBag                        = encodeOID("1.2.840.113549.1.12.10.1.1")
    public static let oidPkcs8ShroudedKeyBag           = encodeOID("1.2.840.113549.1.12.10.1.2")
    public static let oidCertBag                       = encodeOID("1.2.840.113549.1.12.10.1.3")
    public static let oidX509Certificate               = encodeOID("1.2.840.113549.1.9.22.1")

    // PBES OIDs
    public static let oidPBES2                         = encodeOID("1.2.840.113549.1.5.13")
    public static let oidPBKDF2                        = encodeOID("1.2.840.113549.1.5.12")
    public static let oidAES256CBC                     = encodeOID("2.16.840.1.101.3.4.1.42")
    public static let oidAES128CBC                     = encodeOID("2.16.840.1.101.3.4.1.2")
    public static let oidDesEde3Cbc                    = encodeOID("1.2.840.113549.3.7")
    public static let oidPbeWithSHAAnd3KeyTripleDESCBC = encodeOID("1.2.840.113549.1.12.1.3")
    public static let oidPbeWithSHAAnd40BitRC2CBC      = encodeOID("1.2.840.113549.1.12.1.6")

    // DER Length Encoding
    public static func encodeLength(_ length: Int) -> Data {
        if length < 128 {
            return Data([UInt8(length)])
        }
        var len = length
        var bytes: [UInt8] = []
        while len > 0 {
            bytes.insert(UInt8(len & 0xFF), at: 0)
            len >>= 8
        }
        return Data([UInt8(0x80 | bytes.count)] + bytes)
    }

    // DER TLV Encoding
    public static func encodeTLV(tag: UInt8, value: Data) -> Data {
        return Data([tag]) + encodeLength(value.count) + value
    }

    public static func sequence(_ content: Data) -> Data {
        return encodeTLV(tag: 0x30, value: content)
    }

    public static func set(_ content: Data) -> Data {
        return encodeTLV(tag: 0x31, value: content)
    }

    public static func octetString(_ content: Data) -> Data {
        return encodeTLV(tag: 0x04, value: content)
    }

    public static func integer(_ value: Int) -> Data {
        if value == 0 { return Data([0x02, 0x01, 0x00]) }
        if value > 0 && value < 128 { return Data([0x02, 0x01, UInt8(value)]) }
        var temp = value
        var bytes: [UInt8] = []
        while temp > 0 {
            bytes.insert(UInt8(temp & 0xFF), at: 0)
            temp >>= 8
        }
        if (bytes[0] & 0x80) != 0 {
            bytes.insert(0x00, at: 0)
        }
        return encodeTLV(tag: 0x02, value: Data(bytes))
    }

    public static func integer(data: Data) -> Data {
        var trimmed = data
        while trimmed.count > 1 && trimmed[0] == 0 && (trimmed[1] & 0x80) == 0 {
            trimmed.removeFirst()
        }
        if let first = trimmed.first, (first & 0x80) != 0 {
            return encodeTLV(tag: 0x02, value: Data([0x00]) + trimmed)
        }
        return encodeTLV(tag: 0x02, value: trimmed)
    }

    public static func null() -> Data {
        return Data([0x05, 0x00])
    }

    public static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let str = formatter.string(from: date)
        let bytes = Data(str.utf8)
        return encodeTLV(tag: 0x17, value: bytes)
    }

    public static func generalizedTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let str = formatter.string(from: date)
        let bytes = Data(str.utf8)
        return encodeTLV(tag: 0x18, value: bytes)
    }

    public static func algorithmIdentifier(oidData: Data, hasNullParam: Bool = true) -> Data {
        let params = hasNullParam ? null() : Data()
        return sequence(oidData + params)
    }

    public static func contextual(_ tagNumber: UInt8, content: Data, constructed: Bool = true) -> Data {
        let tag: UInt8 = (constructed ? 0xA0 : 0x80) | (tagNumber & 0x1F)
        return encodeTLV(tag: tag, value: content)
    }

    // TLV Parsing
    public static func parseTLV(from data: Data, at offset: Int = 0) -> (tag: UInt8, value: Data, totalLength: Int)? {
        guard offset < data.count else { return nil }
        let tag = data[offset]
        var current = offset + 1
        guard current < data.count else { return nil }

        let firstLen = data[current]
        current += 1

        let length: Int
        if (firstLen & 0x80) == 0 {
            length = Int(firstLen)
        } else {
            let numBytes = Int(firstLen & 0x7F)
            guard numBytes > 0, current + numBytes <= data.count else { return nil }
            var len = 0
            for i in 0..<numBytes {
                len = (len << 8) | Int(data[current + i])
            }
            current += numBytes
            length = len
        }

        guard current + length <= data.count else { return nil }
        let value = data.subdata(in: current..<current + length)
        let total = current + length - offset
        return (tag, value, total)
    }

    public static func parseSequenceChildren(from sequenceContent: Data) -> [(tag: UInt8, value: Data, rawDER: Data)] {
        var items: [(tag: UInt8, value: Data, rawDER: Data)] = []
        var offset = 0
        while offset < sequenceContent.count {
            guard let tlv = parseTLV(from: sequenceContent, at: offset) else { break }
            let raw = sequenceContent.subdata(in: offset..<offset + tlv.totalLength)
            items.append((tlv.tag, tlv.value, raw))
            offset += tlv.totalLength
        }
        return items
    }
    public static func bitString(_ content: Data) -> Data {
        return encodeTLV(tag: 0x03, value: Data([0x00]) + content)
    }

    public static func parseTime(_ tag: UInt8, value: Data) -> Date? {
        guard let str = String(data: value, encoding: .ascii) else { return nil }
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if tag == 0x17 { // UTCTime
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            return formatter.date(from: str)
        } else if tag == 0x18 { // GeneralizedTime
            formatter.dateFormat = "yyyyMMddHHmmss'Z'"
            return formatter.date(from: str)
        }
        return nil
    }

    public static func decodePEM(_ pem: String) -> Data? {
        let lines = pem.components(separatedBy: .newlines)
        let base64 = lines.filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
    }
}

// X.509 Certificate Helper
public struct X509Certificate: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var id: String { serialNumberHex }

    public let rawDER: Data
    public let serialNumberDER: Data
    public let serialNumberHex: String
    public let issuerDER: Data
    public let subjectDER: Data
    public let subjectSummary: String
    public let commonName: String?
    public let organizationalUnit: String?
    public let notBefore: Date?
    public let notAfter: Date?
    public let subjectPublicKeyInfoDER: Data
    public let sha1Fingerprint: Data

    public var metadata: [String: String]

    public init?(der: Data, metadata: [String: String] = [:]) {
        self.rawDER = der
        self.sha1Fingerprint = Data(Insecure.SHA1.hash(data: der))
        self.metadata = metadata

        // Certificate: SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
        guard let certTLV = ASN1Helper.parseTLV(from: der), certTLV.tag == 0x30 else { return nil }
        let certChildren = ASN1Helper.parseSequenceChildren(from: certTLV.value)
        guard certChildren.count >= 3 else { return nil }

        let tbsTLV = certChildren[0]
        guard tbsTLV.tag == 0x30 else { return nil }
        let tbsChildren = ASN1Helper.parseSequenceChildren(from: tbsTLV.value)

        var idx = 0
        if idx < tbsChildren.count && (tbsChildren[idx].tag & 0xC0) == 0x80 { // [0] EXPLICIT version
            idx += 1
        }

        guard idx < tbsChildren.count else { return nil }
        self.serialNumberDER = tbsChildren[idx].rawDER
        var sBytes = [UInt8](tbsChildren[idx].value)
        while sBytes.count > 1 && sBytes[0] == 0 {
            sBytes.removeFirst()
        }
        self.serialNumberHex = sBytes.map { String(format: "%02X", $0) }.joined()
        idx += 1 // skip serialNumber

        guard idx < tbsChildren.count else { return nil }
        idx += 1 // skip signature algorithm

        guard idx < tbsChildren.count else { return nil }
        self.issuerDER = tbsChildren[idx].rawDER
        idx += 1 // skip issuer

        guard idx < tbsChildren.count else { return nil }
        var nbDate: Date? = nil
        var naDate: Date? = nil
        if tbsChildren[idx].tag == 0x30 {
            let times = ASN1Helper.parseSequenceChildren(from: tbsChildren[idx].value)
            if times.count >= 2 {
                nbDate = ASN1Helper.parseTime(times[0].tag, value: times[0].value)
                naDate = ASN1Helper.parseTime(times[1].tag, value: times[1].value)
            }
        }
        self.notBefore = nbDate
        self.notAfter = naDate
        idx += 1 // skip validity

        guard idx < tbsChildren.count else { return nil }
        self.subjectDER = tbsChildren[idx].rawDER
        self.subjectSummary = Self.extractSubjectSummary(from: tbsChildren[idx].value)
        self.commonName = Self.extractCommonName(from: tbsChildren[idx].value)
        self.organizationalUnit = Self.extractOU(from: tbsChildren[idx].value)
        idx += 1 // skip subject

        guard idx < tbsChildren.count else { return nil }
        self.subjectPublicKeyInfoDER = tbsChildren[idx].rawDER
    }

    private static func extractSubjectSummary(from subjectContent: Data) -> String {
        // Parse RDN sequences and extract CN, OU, O, C strings
        let parts = ASN1Helper.parseSequenceChildren(from: subjectContent)
            .flatMap { ASN1Helper.parseSequenceChildren(from: $0.value) }
            .compactMap { atv -> String? in
                let items = ASN1Helper.parseSequenceChildren(from: atv.value)
                guard items.count >= 2 else { return nil }
                let val = items[1].value
                return String(data: val, encoding: .utf8) ?? String(data: val, encoding: .ascii)
            }
        return parts.joined(separator: ", ")
    }

    private static func extractCommonName(from subjectContent: Data) -> String? {
        let cnOID = ASN1Helper.encodeOID("2.5.4.3")
        for rdn in ASN1Helper.parseSequenceChildren(from: subjectContent) {
            for atv in ASN1Helper.parseSequenceChildren(from: rdn.value) {
                let items = ASN1Helper.parseSequenceChildren(from: atv.value)
                if items.count >= 2 && items[0].rawDER == cnOID {
                    return String(data: items[1].value, encoding: .utf8) ?? String(data: items[1].value, encoding: .ascii)
                }
            }
        }
        return nil
    }

    private static func extractOU(from subjectContent: Data) -> String? {
        let ouOID = ASN1Helper.encodeOID("2.5.4.11")
        for rdn in ASN1Helper.parseSequenceChildren(from: subjectContent) {
            for atv in ASN1Helper.parseSequenceChildren(from: rdn.value) {
                let items = ASN1Helper.parseSequenceChildren(from: atv.value)
                if items.count >= 2 && items[0].rawDER == ouOID {
                    return String(data: items[1].value, encoding: .utf8) ?? String(data: items[1].value, encoding: .ascii)
                }
            }
        }
        return nil
    }
}
