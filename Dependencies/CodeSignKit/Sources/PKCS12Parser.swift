//
//  PKCS12Parser.swift
//  CodeSignKit
//
//  Created by Magesh K on 28/08/26.
//  Copyright © 2026 CodeSignKit. All rights reserved.
//

import Foundation
import Crypto
import _CryptoExtras
import SwiftASN1

public final class PKCS12Parser {

    public private(set) var leafCertificate: X509Certificate?
    public private(set) var intermediateCertificates: [X509Certificate] = []
    public private(set) var privateKeyDER: Data?
    public private(set) var rsaPrivateKey: _RSA.Signing.PrivateKey?

    public init(p12Data: Data, password: String = "") throws {
        try parse(data: p12Data, password: password)
    }

    private func parse(data: Data, password: String) throws {
        // PFX: SEQUENCE { version INTEGER, authSafe ContentInfo, macData MacData OPTIONAL }
        guard let pfxTLV = ASN1Helper.parseTLV(from: data), pfxTLV.tag == 0x30 else {
            throw CodeSignerError.certificateError("Invalid PKCS#12 structure (not an ASN.1 SEQUENCE)")
        }

        let pfxChildren = ASN1Helper.parseSequenceChildren(from: pfxTLV.value)
        guard pfxChildren.count >= 2 else {
            throw CodeSignerError.certificateError("Truncated PKCS#12 PFX structure")
        }

        // authSafe ContentInfo: SEQUENCE { contentType OBJECT IDENTIFIER, content [0] EXPLICIT ANY }
        let authSafeTLV = pfxChildren[1]
        let authSafeChildren = ASN1Helper.parseSequenceChildren(from: authSafeTLV.value)
        guard authSafeChildren.count >= 2 else {
            throw CodeSignerError.certificateError("Invalid authSafe ContentInfo")
        }

        let contentTypeData = authSafeChildren[0].rawDER
        guard let contentWrappedTLV = ASN1Helper.parseTLV(from: authSafeChildren[1].value) else {
            throw CodeSignerError.certificateError("Missing content in authSafe")
        }

        let authenticatedSafeBytes: Data
        if contentTypeData == ASN1Helper.oidData {
            // Unencrypted AuthenticatedSafe
            authenticatedSafeBytes = contentWrappedTLV.value
        } else if contentTypeData == ASN1Helper.oidEncryptedData {
            // Encrypted AuthenticatedSafe
            authenticatedSafeBytes = try decryptEncryptedContentInfo(contentWrappedTLV.value, password: password)
        } else {
            authenticatedSafeBytes = contentWrappedTLV.value
        }

        // AuthenticatedSafe: SEQUENCE OF ContentInfo
        let contentInfos: [(tag: UInt8, value: Data, rawDER: Data)]
        if let authSafeSeq = ASN1Helper.parseTLV(from: authenticatedSafeBytes), authSafeSeq.tag == 0x30 {
            contentInfos = ASN1Helper.parseSequenceChildren(from: authSafeSeq.value)
        } else {
            contentInfos = ASN1Helper.parseSequenceChildren(from: authenticatedSafeBytes)
        }

        for safeContentCI in contentInfos {
            guard safeContentCI.tag == 0x30 else { continue }
            let ciChildren = ASN1Helper.parseSequenceChildren(from: safeContentCI.value)
            guard ciChildren.count >= 2 else { continue }

            let ciType = ciChildren[0].rawDER
            let ciContentWrapped = ciChildren[1]

            let safeBagsBytes: Data
            if ciType == ASN1Helper.oidData {
                // [0] EXPLICIT OCTET STRING containing SafeContents SEQUENCE
                if let octetTLV = ASN1Helper.parseTLV(from: ciContentWrapped.value) {
                    safeBagsBytes = octetTLV.value
                } else {
                    safeBagsBytes = ciContentWrapped.value
                }
            } else if ciType == ASN1Helper.oidEncryptedData {
                safeBagsBytes = try decryptEncryptedContentInfo(ciContentWrapped.value, password: password)
            } else {
                continue
            }

            // SafeContents: SEQUENCE OF SafeBag
            let safeBags: [(tag: UInt8, value: Data, rawDER: Data)]
            if let scSeq = ASN1Helper.parseTLV(from: safeBagsBytes), scSeq.tag == 0x30 {
                safeBags = ASN1Helper.parseSequenceChildren(from: scSeq.value)
            } else {
                safeBags = ASN1Helper.parseSequenceChildren(from: safeBagsBytes)
            }

            for bag in safeBags {
                guard bag.tag == 0x30 else { continue }
                try processSafeBag(bag.value, password: password)
            }
        }

        guard self.rsaPrivateKey != nil, self.leafCertificate != nil else {
            throw CodeSignerError.certificateError("Failed to extract private key and certificate from PKCS#12")
        }
    }

    private func processSafeBag(_ bagValue: Data, password: String) throws {
        // SafeBag: SEQUENCE { bagId OBJECT IDENTIFIER, bagValue [0] EXPLICIT ANY, bagAttributes SET OF PKCS12Attribute OPTIONAL }
        let bagChildren = ASN1Helper.parseSequenceChildren(from: bagValue)
        guard bagChildren.count >= 2 else { return }

        let bagId = bagChildren[0].rawDER
        let bagContentWrapped = bagChildren[1]

        if bagId == ASN1Helper.oidCertBag {
            // CertBag: SEQUENCE { certId OBJECT IDENTIFIER, certValue [0] EXPLICIT OCTET STRING }
            guard let certBagTLV = ASN1Helper.parseTLV(from: bagContentWrapped.value), certBagTLV.tag == 0x30 else { return }
            let certBagChildren = ASN1Helper.parseSequenceChildren(from: certBagTLV.value)
            if certBagChildren.count >= 2 {
                guard let certOctetTLV = ASN1Helper.parseTLV(from: certBagChildren[1].value) else { return }
                if let cert = X509Certificate(der: certOctetTLV.value) {
                    if self.leafCertificate == nil {
                        self.leafCertificate = cert
                    } else {
                        self.intermediateCertificates.append(cert)
                    }
                }
            }
        } else if bagId == ASN1Helper.oidPkcs8ShroudedKeyBag {
            // EncryptedPrivateKeyInfo: SEQUENCE { encryptionAlgorithm AlgorithmIdentifier, encryptedData OCTET STRING }
            let decryptedKeyDER = try decryptEncryptedPrivateKeyInfo(bagContentWrapped.value, password: password)
            self.privateKeyDER = decryptedKeyDER
            try loadRSAPrivateKey(from: decryptedKeyDER)
        } else if bagId == ASN1Helper.oidKeyBag {
            // Unencrypted PrivateKeyInfo
            self.privateKeyDER = bagContentWrapped.value
            try loadRSAPrivateKey(from: bagContentWrapped.value)
        }
    }

    private func loadRSAPrivateKey(from der: Data) throws {
        // Try PKCS#8 or PKCS#1 RSAPrivateKey
        if let key = try? _RSA.Signing.PrivateKey(derRepresentation: der) {
            self.rsaPrivateKey = key
            return
        }

        // If der is PrivateKeyInfo, extract the inner privateKey OCTET STRING (PKCS#1)
        if let tlv = ASN1Helper.parseTLV(from: der), tlv.tag == 0x30 {
            let children = ASN1Helper.parseSequenceChildren(from: tlv.value)
            for child in children {
                if child.tag == 0x04 { // OCTET STRING containing RSAPrivateKey
                    if let key = try? _RSA.Signing.PrivateKey(derRepresentation: child.value) {
                        self.rsaPrivateKey = key
                        return
                    }
                }
            }
        }

        throw CodeSignerError.certificateError("Unsupported private key format in PKCS#12 (only RSA is supported)")
    }

    // PKCS#12 / PBES Decryption
    private func decryptEncryptedContentInfo(_ contentData: Data, password: String) throws -> Data {
        // contentData can be EncryptedData: SEQUENCE { version INTEGER, encryptedContentInfo EncryptedContentInfo }
        // or directly EncryptedContentInfo: SEQUENCE { contentType OBJECT IDENTIFIER, contentEncryptionAlgorithm AlgorithmIdentifier, encryptedContent [0] IMPLICIT OCTET STRING OPTIONAL }
        guard let tlv = ASN1Helper.parseTLV(from: contentData), tlv.tag == 0x30 else {
            throw CodeSignerError.certificateError("Invalid EncryptedData/EncryptedContentInfo")
        }
        let children = ASN1Helper.parseSequenceChildren(from: tlv.value)

        let eciValue: Data
        if children.count >= 2 && children[0].tag == 0x02 { // EncryptedData (version, encryptedContentInfo)
            eciValue = children[1].value
        } else {
            eciValue = tlv.value
        }

        let eciChildren = ASN1Helper.parseSequenceChildren(from: eciValue)
        guard eciChildren.count >= 3 else {
            throw CodeSignerError.certificateError("Invalid EncryptedContentInfo structure")
        }

        let algData = eciChildren[1].rawDER
        var encryptedBytes = eciChildren[2].value
        if eciChildren[2].tag == 0xA0 || eciChildren[2].tag == 0x24 {
            if let innerTLV = ASN1Helper.parseTLV(from: encryptedBytes), innerTLV.tag == 0x04 {
                encryptedBytes = innerTLV.value
            }
        }
        return try decryptData(encryptedBytes, algorithmDER: algData, password: password)
    }

    private func decryptEncryptedPrivateKeyInfo(_ epkiData: Data, password: String) throws -> Data {
        // EncryptedPrivateKeyInfo: SEQUENCE { encryptionAlgorithm AlgorithmIdentifier, encryptedData OCTET STRING }
        guard let tlv = ASN1Helper.parseTLV(from: epkiData), tlv.tag == 0x30 else {
            throw CodeSignerError.certificateError("Invalid EncryptedPrivateKeyInfo")
        }
        let children = ASN1Helper.parseSequenceChildren(from: tlv.value)
        guard children.count >= 2 else {
            throw CodeSignerError.certificateError("Truncated EncryptedPrivateKeyInfo")
        }

        let algData = children[0].rawDER
        var encryptedBytes = children[1].value
        if children[1].tag == 0xA0 || children[1].tag == 0x24 {
            if let innerTLV = ASN1Helper.parseTLV(from: encryptedBytes), innerTLV.tag == 0x04 {
                encryptedBytes = innerTLV.value
            }
        }
        return try decryptData(encryptedBytes, algorithmDER: algData, password: password)
    }

    private func decryptData(_ cipher: Data, algorithmDER: Data, password: String) throws -> Data {
        guard let algTLV = ASN1Helper.parseTLV(from: algorithmDER), algTLV.tag == 0x30 else {
            throw CodeSignerError.certificateError("Invalid AlgorithmIdentifier")
        }
        let algChildren = ASN1Helper.parseSequenceChildren(from: algTLV.value)
        guard !algChildren.isEmpty else {
            throw CodeSignerError.certificateError("Missing algorithm in AlgorithmIdentifier")
        }

        let algOID = algChildren[0].rawDER

        if algOID == ASN1Helper.oidPBES2 {
            // PBES2: SEQUENCE { keyDerivationFunc (PBKDF2), encryptionScheme (AES-CBC) }
            guard algChildren.count >= 2 else {
                throw CodeSignerError.certificateError("Invalid PBES2 parameters")
            }
            let pbes2Params = ASN1Helper.parseSequenceChildren(from: algChildren[1].value)
            guard pbes2Params.count >= 2 else {
                throw CodeSignerError.certificateError("Truncated PBES2 parameters")
            }

            // 1. Key Derivation (PBKDF2)
            let pbkdf2Children = ASN1Helper.parseSequenceChildren(from: pbes2Params[0].value)
            guard pbkdf2Children.count >= 2 else {
                throw CodeSignerError.certificateError("Invalid PBKDF2 parameters")
            }
            let pbkdf2ParamChildren = ASN1Helper.parseSequenceChildren(from: pbkdf2Children[1].value)
            guard pbkdf2ParamChildren.count >= 2 else {
                throw CodeSignerError.certificateError("Invalid PBKDF2 inner parameters")
            }

            let salt = pbkdf2ParamChildren[0].value
            let rounds = parseInteger(from: pbkdf2ParamChildren[1].value)

            // PRF OID if present
            var prfOID: Data? = nil
            if pbkdf2ParamChildren.count >= 4 {
                let prfChildren = ASN1Helper.parseSequenceChildren(from: pbkdf2ParamChildren[3].value)
                if !prfChildren.isEmpty {
                    prfOID = prfChildren[0].rawDER
                }
            }

            // 2. Encryption Scheme
            let encSchemeChildren = ASN1Helper.parseSequenceChildren(from: pbes2Params[1].value)
            guard encSchemeChildren.count >= 2 else {
                throw CodeSignerError.certificateError("Invalid encryption scheme parameters")
            }
            let encOID = encSchemeChildren[0].rawDER
            let iv = encSchemeChildren[1].value

            let keyLength: Int
            if encOID == ASN1Helper.oidAES256CBC {
                keyLength = 32
            } else if encOID == ASN1Helper.oidDesEde3Cbc {
                keyLength = 24
            } else {
                keyLength = 16
            }

            let pwdData = Data(password.utf8)
            let derivedKey = try derivePBKDF2Key(password: pwdData, salt: salt, rounds: rounds, keyLength: keyLength, prfOID: prfOID)

            if encOID == ASN1Helper.oidDesEde3Cbc {
                return try TripleDESCipher.decryptCBC(cipher: cipher, key: derivedKey, iv: iv)
            } else {
                let symmetricKey = SymmetricKey(data: derivedKey)
                let ivObj = try AES._CBC.IV(ivBytes: iv)
                return try AES._CBC.decrypt(cipher, using: symmetricKey, iv: ivObj, noPadding: false)
            }
        } else if algOID == ASN1Helper.oidPbeWithSHAAnd3KeyTripleDESCBC ||
                    algOID == ASN1Helper.oidPbeWithSHAAnd40BitRC2CBC {
            // PKCS#12 PBE
            guard algChildren.count >= 2 else {
                throw CodeSignerError.certificateError("Missing PKCS#12 PBE parameters")
            }
            let pbeParams = ASN1Helper.parseSequenceChildren(from: algChildren[1].value)
            guard pbeParams.count >= 2 else {
                throw CodeSignerError.certificateError("Truncated PKCS#12 PBE parameters")
            }
            let salt = pbeParams[0].value
            let rounds = max(1, parseInteger(from: pbeParams[1].value))

            let is3DES = (algOID == ASN1Helper.oidPbeWithSHAAnd3KeyTripleDESCBC)
            let keyLength = is3DES ? 24 : 5
            let ivLength = 8

            let derivedKey = derivePKCS12Key(id: 1, password: password, salt: salt, rounds: rounds, length: keyLength)
            let derivedIV = derivePKCS12Key(id: 2, password: password, salt: salt, rounds: rounds, length: ivLength)

            if is3DES {
                return try TripleDESCipher.decryptCBC(cipher: cipher, key: derivedKey, iv: derivedIV)
            } else {
                return try RC2Cipher.decryptCBC(cipher: cipher, key: derivedKey, iv: derivedIV, effectiveKeyBits: 40)
            }
        }

        throw CodeSignerError.certificateError("Unsupported encryption algorithm in PKCS#12")
    }

    private func parseInteger(from data: Data) -> Int {
        var val = 0
        for byte in data {
            val = (val << 8) | Int(byte)
        }
        return val
    }

    // PBKDF2 Derivation (SHA-256 or SHA-1)
    private func derivePBKDF2Key(password: Data, salt: Data, rounds: Int, keyLength: Int, prfOID: Data? = nil) throws -> Data {
        let isSHA1 = (prfOID == ASN1Helper.encodeOID("1.2.840.113549.2.7"))
        if isSHA1 {
            let hLen = 20
            let l = (keyLength + hLen - 1) / hLen
            var dk = Data()

            for i in 1...l {
                var counter = Data(count: 4)
                counter[0] = UInt8((i >> 24) & 0xFF)
                counter[1] = UInt8((i >> 16) & 0xFF)
                counter[2] = UInt8((i >> 8) & 0xFF)
                counter[3] = UInt8(i & 0xFF)

                let saltAndCounter = salt + counter
                let key = SymmetricKey(data: password)
                var u = Data(HMAC<Insecure.SHA1>.authenticationCode(for: saltAndCounter, using: key))
                var t = u

                if rounds > 1 {
                    for _ in 2...rounds {
                        u = Data(HMAC<Insecure.SHA1>.authenticationCode(for: u, using: key))
                        for k in 0..<hLen {
                            t[k] ^= u[k]
                        }
                    }
                }
                dk.append(t)
            }
            return dk.prefix(keyLength)
        } else {
            let hLen = 32
            let l = (keyLength + hLen - 1) / hLen
            var dk = Data()

            for i in 1...l {
                var counter = Data(count: 4)
                counter[0] = UInt8((i >> 24) & 0xFF)
                counter[1] = UInt8((i >> 16) & 0xFF)
                counter[2] = UInt8((i >> 8) & 0xFF)
                counter[3] = UInt8(i & 0xFF)

                let saltAndCounter = salt + counter
                let key = SymmetricKey(data: password)
                var u = Data(HMAC<SHA256>.authenticationCode(for: saltAndCounter, using: key))
                var t = u

                if rounds > 1 {
                    for _ in 2...rounds {
                        u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                        for k in 0..<hLen {
                            t[k] ^= u[k]
                        }
                    }
                }
                dk.append(t)
            }
            return dk.prefix(keyLength)
        }
    }

    // PKCS#12 KDF (RFC 7292 Appendix B)
    private func derivePKCS12Key(id: UInt8, password: String, salt: Data, rounds: Int, length: Int) -> Data {
        let v = 64 // SHA-1 block size
        let u = 20 // SHA-1 digest size

        let d = Data(repeating: id, count: v)

        // Password as UTF-16BE bytes including trailing null
        var pBytes = Data()
        for scalar in password.utf16 {
            pBytes.append(UInt8((scalar >> 8) & 0xFF))
            pBytes.append(UInt8(scalar & 0xFF))
        }
        pBytes.append(0x00)
        pBytes.append(0x00)

        // S' (salt extended to multiple of v)
        var sPrime = Data()
        if !salt.isEmpty {
            let sLen = v * ((salt.count + v - 1) / v)
            while sPrime.count < sLen {
                sPrime.append(salt)
            }
            sPrime = sPrime.prefix(sLen)
        }

        // P' (password extended to multiple of v)
        var pPrime = Data()
        if !pBytes.isEmpty {
            let pLen = v * ((pBytes.count + v - 1) / v)
            while pPrime.count < pLen {
                pPrime.append(pBytes)
            }
            pPrime = pPrime.prefix(pLen)
        }

        let iBlock = sPrime + pPrime
        let c = (length + u - 1) / u
        var derived = Data()

        var currentI = iBlock

        for _ in 1...c {
            var a = Data(Insecure.SHA1.hash(data: d + currentI))
            if rounds > 1 {
                for _ in 2...rounds {
                    a = Data(Insecure.SHA1.hash(data: a))
                }
            }

            derived.append(a)

            if derived.count >= length { break }

            // B = repeat(A, v)
            var b = Data()
            while b.count < v {
                b.append(a)
            }
            b = b.prefix(v)

            // For each v-byte block in currentI: Ij = (Ij + B + 1) mod 2^(8*v)
            let kBlocks = currentI.count / v
            for blockIdx in 0..<kBlocks {
                var carry: UInt32 = 1
                let blockStart = blockIdx * v
                let blockEnd = blockStart + v
                for j in stride(from: blockEnd - 1, through: blockStart, by: -1) {
                    let sum = UInt32(currentI[j]) + UInt32(b[j - blockStart]) + carry
                    currentI[j] = UInt8(sum & 0xFF)
                    carry = sum >> 8
                }
            }
        }

        return derived.prefix(length)
    }
}
