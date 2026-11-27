//
//  SignatureVerifier.swift
//  CodeSignKit
//
//  Created by Magesh K on 28/08/26.
//  Copyright © 2026 CodeSignKit. All rights reserved.
//

import Foundation
import Crypto
import _CryptoExtras
import SwiftASN1

public struct VerificationResult {
    public let isValid: Bool
    public let path: String
    public let bundleIdentifier: String?
    public let teamIdentifier: String?
    public let cdHash: String?
    public let signerCertificateSubject: String?
    public let errors: [String]
    public let warnings: [String]

    public init(
        isValid: Bool,
        path: String,
        bundleIdentifier: String? = nil,
        teamIdentifier: String? = nil,
        cdHash: String? = nil,
        signerCertificateSubject: String? = nil,
        errors: [String] = [],
        warnings: [String] = []
    ) {
        self.isValid = isValid
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.cdHash = cdHash
        self.signerCertificateSubject = signerCertificateSubject
        self.errors = errors
        self.warnings = warnings
    }
}

public final class SignatureVerifier {

    public static func verify(url: URL, deep: Bool = true, strict: Bool = false) -> VerificationResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return VerificationResult(
                isValid: false,
                path: url.path,
                errors: ["Path does not exist: \(url.path)"]
            )
        }

        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        if isDir {
            return verifyBundle(at: url, deep: deep, strict: strict)
        } else {
            do {
                let data = try Data(contentsOf: url)
                return verify(binaryData: data, path: url.path)
            } catch {
                return VerificationResult(
                    isValid: false,
                    path: url.path,
                    errors: ["Failed to read binary file: \(error.localizedDescription)"]
                )
            }
        }
    }

    public static func verify(binaryData: Data, path: String = "") -> VerificationResult {
        guard binaryData.count >= 4 else {
            return VerificationResult(
                isValid: false,
                path: path,
                errors: ["Binary too short to be Mach-O"]
            )
        }

        let magic = binaryData.readUInt32(at: 0)

        // FAT binary
        if magic == CodeSigningConstants.FAT_MAGIC || magic == CodeSigningConstants.FAT_CIGAM ||
           magic == CodeSigningConstants.FAT_MAGIC_64 || magic == CodeSigningConstants.FAT_CIGAM_64 {
            return verifyFatBinary(binaryData: binaryData, path: path)
        } else if magic == CodeSigningConstants.MH_MAGIC_64 || magic == CodeSigningConstants.MH_CIGAM_64 ||
                  magic == CodeSigningConstants.MH_MAGIC || magic == CodeSigningConstants.MH_CIGAM {
            return verifyThinBinary(sliceData: binaryData, path: path)
        } else {
            return VerificationResult(
                isValid: false,
                path: path,
                errors: ["Unrecognized Mach-O magic: \(String(format: "0x%08X", magic))"]
            )
        }
    }

    private static func verifyThinBinary(sliceData: Data, path: String) -> VerificationResult {
        let parser = MachOParser(data: sliceData)

        var errors: [String] = []
        let warnings: [String] = []

        let bundleID = parser.bundleIdentifier()
        let teamID = parser.teamID()
        let cdHashes = parser.getCDHashes()
        let primaryCDHash = cdHashes.first

        // Verify page digests against CodeDirectory
        let thinData = (try? parser.getThinBinaryData()) ?? sliceData
        guard let cdBlob = try? parser.extractCodeDirectoryBlob() else {
            return VerificationResult(
                isValid: false,
                path: path,
                bundleIdentifier: bundleID,
                teamIdentifier: teamID,
                cdHash: primaryCDHash,
                errors: ["No CodeDirectory found in signature"]
            )
        }

        let pageVerification = verifyCodeDirectoryPages(cdBlob: cdBlob, thinData: thinData)
        if !pageVerification.isValid {
            errors.append(contentsOf: pageVerification.errors)
        }

        // Read CodeDirectory flags
        let cdFlags = (cdBlob.count >= 16) ? cdBlob.readUInt32BigEndian(at: 12) : 0
        let isAdHoc = (cdFlags & CodeSigningConstants.CS_ADHOC) != 0

        // Verify CMS Signature
        var signerSubject: String? = nil
        if let sigBlob = try? parser.extractSignatureBlob(), !sigBlob.isEmpty {
            let cmsResult = verifyCMSSignatureBlob(sigBlob: sigBlob, codeDirectoryBlob: cdBlob)
            signerSubject = cmsResult.signerSubject
            if !cmsResult.isValid {
                if let err = cmsResult.error {
                    errors.append(err)
                }
            }
        } else if isAdHoc {
            signerSubject = "Ad-Hoc Signature"
        } else {
            errors.append("No CMS signature blob found")
        }

        let isValid = errors.isEmpty
        return VerificationResult(
            isValid: isValid,
            path: path,
            bundleIdentifier: bundleID,
            teamIdentifier: teamID,
            cdHash: primaryCDHash,
            signerCertificateSubject: signerSubject,
            errors: errors,
            warnings: warnings
        )
    }

    private static func verifyFatBinary(binaryData: Data, path: String) -> VerificationResult {
        let is64 = (binaryData.readUInt32(at: 0) == CodeSigningConstants.FAT_MAGIC_64 ||
                    binaryData.readUInt32(at: 0) == CodeSigningConstants.FAT_CIGAM_64)
        let swap = (binaryData.readUInt32(at: 0) == CodeSigningConstants.FAT_CIGAM ||
                    binaryData.readUInt32(at: 0) == CodeSigningConstants.FAT_CIGAM_64)

        let nfatArch = Int(swap ? binaryData.readUInt32(at: 4).byteSwapped : binaryData.readUInt32(at: 4))
        let archHeaderSize = is64 ? 32 : 20
        var headerOffset = 8

        var allErrors: [String] = []
        var allWarnings: [String] = []
        var primaryID: String? = nil
        var primaryTeam: String? = nil
        var primaryHash: String? = nil
        var primarySubject: String? = nil

        for archIndex in 0..<nfatArch {
            guard headerOffset + archHeaderSize <= binaryData.count else {
                return VerificationResult(isValid: false, path: path, errors: ["Truncated FAT header"])
            }

            let offset = Int(swap ? binaryData.readUInt32(at: headerOffset + 8).byteSwapped : binaryData.readUInt32(at: headerOffset + 8))
            let size = Int(swap ? binaryData.readUInt32(at: headerOffset + 12).byteSwapped : binaryData.readUInt32(at: headerOffset + 12))

            guard offset + size <= binaryData.count else {
                return VerificationResult(isValid: false, path: path, errors: ["Invalid FAT slice offset/size"])
            }

            let sliceData = binaryData.subdata(in: offset..<offset + size)
            let result = verifyThinBinary(sliceData: sliceData, path: "\(path) (slice \(archIndex))")

            if primaryID == nil { primaryID = result.bundleIdentifier }
            if primaryTeam == nil { primaryTeam = result.teamIdentifier }
            if primaryHash == nil { primaryHash = result.cdHash }
            if primarySubject == nil { primarySubject = result.signerCertificateSubject }

            if !result.isValid {
                allErrors.append(contentsOf: result.errors)
            }
            allWarnings.append(contentsOf: result.warnings)

            headerOffset += archHeaderSize
        }

        return VerificationResult(
            isValid: allErrors.isEmpty,
            path: path,
            bundleIdentifier: primaryID,
            teamIdentifier: primaryTeam,
            cdHash: primaryHash,
            signerCertificateSubject: primarySubject,
            errors: allErrors,
            warnings: allWarnings
        )
    }

    private static func verifyBundle(at bundleURL: URL, deep: Bool, strict: Bool) -> VerificationResult {
        var errors: [String] = []
        let warnings: [String] = []

        guard let executableURL = MachOParser.findExecutable(at: bundleURL) else {
            // Pure resource bundle e.g. *.bundle without Mach-O binary 
            // thse are usually already sealed by parent CodeResources
            let codeSigURL = bundleURL.appendingPathComponent("_CodeSignature/CodeResources")
            if FileManager.default.fileExists(atPath: codeSigURL.path),
               let resData = try? Data(contentsOf: codeSigURL),
               let plist = try? PropertyListSerialization.propertyList(from: resData, options: [], format: nil) as? [String: any Sendable] {
                if let files2 = plist["files2"] as? [String: any Sendable] {
                    for (relPath, info) in files2 {
                        let fileURL = bundleURL.appendingPathComponent(relPath)
                        guard FileManager.default.fileExists(atPath: fileURL.path) else {
                            errors.append("Sealed resource missing: \(relPath)")
                            continue
                        }
                        if let fileDict = info as? [String: any Sendable], let expectedHash = fileDict["hash2"] as? Data {
                            if let fileData = try? Data(contentsOf: fileURL) {
                                let actualHash = Data(SHA256.hash(data: fileData))
                                if actualHash != expectedHash {
                                    errors.append("Resource modified: \(relPath)")
                                }
                            }
                        }
                    }
                }
            }
            return VerificationResult(
                isValid: errors.isEmpty,
                path: bundleURL.path,
                errors: errors,
                warnings: warnings
            )
        }

        // 1. Verify CodeResources sealing
        let codeSigURL = bundleURL.appendingPathComponent("_CodeSignature/CodeResources")
        if !FileManager.default.fileExists(atPath: codeSigURL.path) {
            errors.append("Missing CodeResources file at \(codeSigURL.path)")
        } else if let resData = try? Data(contentsOf: codeSigURL),
                  let plist = try? PropertyListSerialization.propertyList(from: resData, options: [], format: nil) as? [String: any Sendable] {

            // Check files2 (SHA-256)
            if let files2 = plist["files2"] as? [String: any Sendable] {
                for (relPath, info) in files2 {
                    let fileURL = bundleURL.appendingPathComponent(relPath)
                    guard FileManager.default.fileExists(atPath: fileURL.path) else {
                        errors.append("Sealed resource missing: \(relPath)")
                        continue
                    }

                    if let fileDict = info as? [String: any Sendable], let expectedHash = fileDict["hash2"] as? Data {
                        if let fileData = try? Data(contentsOf: fileURL) {
                            let actualHash = Data(SHA256.hash(data: fileData))
                            if actualHash != expectedHash {
                                errors.append("Resource modified: \(relPath)")
                            }
                        }
                    }
                }
            }
        }

        // 2. Verify main executable
        let mainResult = verify(url: executableURL, deep: false, strict: strict)
        if !mainResult.isValid {
            errors.append(contentsOf: mainResult.errors)
        }

        // 3. Deep verification of embedded frameworks, plugins, sub-bundles, and binaries if requested
        if deep {
            let canonicalBundleURL = bundleURL.resolvingSymlinksInPath()
            let canonicalExecutableURL = executableURL.resolvingSymlinksInPath()
            if let enumerator = FileManager.default.enumerator(
                at: canonicalBundleURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) {
                for case let item as URL in enumerator {
                    if item.lastPathComponent.hasPrefix(".") {
                        continue
                    }
                    let canonicalItem = item.resolvingSymlinksInPath()
                    if canonicalItem.path == canonicalBundleURL.path ||
                       canonicalItem.path == canonicalExecutableURL.path {
                        continue
                    }
                    let isDir = (try? canonicalItem.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                    let ext = item.pathExtension.lowercased()
                    let isSubBundle = isDir && Constants.bundleExtensions.contains(ext) && (MachOParser.findExecutable(at: canonicalItem) != nil)
                    let isLooseBinary = !isDir && (Constants.dynamicLibraryExtensions.contains(ext) || MachOParser.isMachOBinary(at: canonicalItem))

                    if isSubBundle || isLooseBinary {
                        let subResult = verify(url: canonicalItem, deep: false, strict: strict)
                        if !subResult.isValid {
                            errors.append(contentsOf: subResult.errors)
                        }
                    }
                }
            }
        }

        return VerificationResult(
            isValid: errors.isEmpty,
            path: bundleURL.path,
            bundleIdentifier: mainResult.bundleIdentifier,
            teamIdentifier: mainResult.teamIdentifier,
            cdHash: mainResult.cdHash,
            signerCertificateSubject: mainResult.signerCertificateSubject,
            errors: errors,
            warnings: warnings
        )
    }

    private static func verifyCodeDirectoryPages(cdBlob: Data, thinData: Data) -> (isValid: Bool, errors: [String]) {
        guard cdBlob.count >= 44 else {
            return (false, ["CodeDirectory blob too small"])
        }

        let magic = cdBlob.readUInt32BigEndian(at: 0)
        guard magic == CodeSigningConstants.CSMAGIC_CODEDIRECTORY else {
            return (false, ["Invalid CodeDirectory magic: \(String(format: "0x%08X", magic))"])
        }

        let hashOffset = Int(cdBlob.readUInt32BigEndian(at: 16))
        let _ = Int(cdBlob.readUInt32BigEndian(at: 24))
        let nCodeSlots = Int(cdBlob.readUInt32BigEndian(at: 28))
        let codeLimit = Int(cdBlob.readUInt32BigEndian(at: 32))
        let hashSize = Int(cdBlob[36])
        let hashType = cdBlob[37]
        let pageSizeShift = Int(cdBlob[39])
        let pageSize = 1 << pageSizeShift

        guard hashType == CodeSigningConstants.CS_HASHTYPE_SHA256 || hashType == CodeSigningConstants.CS_HASHTYPE_SHA1 else {
            return (false, ["Unsupported CodeDirectory hash type: \(hashType)"])
        }

        var errors: [String] = []

        // Verify code page hashes
        for slot in 0..<nCodeSlots {
            let pageStart = slot * pageSize
            guard pageStart < codeLimit else { break }
            let pageEnd = min(pageStart + pageSize, codeLimit)
            guard pageEnd <= thinData.count else {
                errors.append("Page \(slot) extends beyond binary bounds")
                break
            }

            let pageData = thinData.subdata(in: pageStart..<pageEnd)
            let actualHash: Data
            if hashType == CodeSigningConstants.CS_HASHTYPE_SHA256 {
                actualHash = Data(SHA256.hash(data: pageData))
            } else {
                actualHash = Data(Insecure.SHA1.hash(data: pageData))
            }

            let slotOffset = hashOffset + slot * hashSize
            guard slotOffset + hashSize <= cdBlob.count else {
                errors.append("CodeDirectory slots truncated at slot \(slot)")
                break
            }

            let expectedHash = cdBlob.subdata(in: slotOffset..<slotOffset + hashSize)
            if actualHash != expectedHash {
                errors.append("Code page \(slot) hash mismatch (tampered binary content)")
            }
        }

        return (errors.isEmpty, errors)
    }

    private static func verifyCMSSignatureBlob(
        sigBlob: Data,
        codeDirectoryBlob: Data
    ) -> (isValid: Bool, signerSubject: String?, error: String?) {
        // Strip BlobWrapper (0xfade0b01) if present
        var derData = sigBlob
        if derData.count >= 8 {
            let magic = derData.readUInt32BigEndian(at: 0)
            if magic == CodeSigningConstants.CSMAGIC_BLOBWRAPPER {
                let len = Int(derData.readUInt32BigEndian(at: 4))
                if len <= derData.count && len > 8 {
                    derData = derData.subdata(in: 8..<len)
                }
            }
        }

        // Parse ContentInfo: SEQUENCE { contentType OBJECT IDENTIFIER, content [0] EXPLICIT SignedData }
        guard let ciTLV = ASN1Helper.parseTLV(from: derData), ciTLV.tag == 0x30 else {
            return (false, nil, "Failed to parse CMS signature ASN.1 structure")
        }

        let ciChildren = ASN1Helper.parseSequenceChildren(from: ciTLV.value)
        guard ciChildren.count >= 2 else {
            return (false, nil, "Invalid CMS ContentInfo structure")
        }

        guard let signedDataTLV = ASN1Helper.parseTLV(from: ciChildren[1].value) else {
            return (false, nil, "Missing SignedData in CMS structure")
        }

        // SignedData: SEQUENCE { version, digestAlgorithms, encapContentInfo, certificates [0] IMPLICIT OPTIONAL, crls, signerInfos }
        let sdChildren = ASN1Helper.parseSequenceChildren(from: signedDataTLV.value)
        guard sdChildren.count >= 3 else {
            return (false, nil, "Invalid SignedData sequence")
        }

        var certificates: [X509Certificate] = []
        var signerInfosData: Data? = nil

        for child in sdChildren {
            if (child.tag & 0xC0) == 0x80 && (child.tag & 0x1F) == 0 { // [0] IMPLICIT certificates
                let certs = ASN1Helper.parseSequenceChildren(from: child.value)
                for certItem in certs {
                    if let cert = X509Certificate(der: certItem.rawDER) {
                        certificates.append(cert)
                    }
                }
            } else if child.tag == 0x31 { // SET of SignerInfo
                signerInfosData = child.value
            }
        }

        guard let siData = signerInfosData else {
            return (false, nil, "Missing SignerInfo in CMS structure")
        }

        let signerInfoList = ASN1Helper.parseSequenceChildren(from: siData)
        guard let firstSignerInfo = signerInfoList.first else {
            return (false, nil, "Empty SignerInfo list")
        }

        // SignerInfo: SEQUENCE { version, sid, digestAlg, signedAttrs [0] IMPLICIT, sigAlg, signature }
        let siChildren = ASN1Helper.parseSequenceChildren(from: firstSignerInfo.value)
        guard siChildren.count >= 6 else {
            return (false, nil, "Invalid SignerInfo structure")
        }

        let sidDER = siChildren[1].rawDER
        var signedAttrsRawContent: Data? = nil
        var signatureBytes: Data? = nil

        for child in siChildren {
            if (child.tag & 0xC0) == 0x80 && (child.tag & 0x1F) == 0 { // [0] IMPLICIT signedAttrs
                signedAttrsRawContent = child.value
            } else if child.tag == 0x04 { // OCTET STRING signature
                signatureBytes = child.value
            }
        }

        guard let signedAttrsContent = signedAttrsRawContent,
              let sigBytes = signatureBytes else {
            return (false, nil, "Missing signed attributes or signature bytes")
        }

        // Find signer certificate matching sid
        // sid: IssuerAndSerialNumber: SEQUENCE { issuer Name, serialNumber CertificateSerialNumber }
        let sidChildren = ASN1Helper.parseSequenceChildren(from: siChildren[1].value)
        let sidSerialDER = (sidChildren.count >= 2) ? sidChildren[1].rawDER : nil
        let sidIssuerDER = (sidChildren.count >= 2) ? sidChildren[0].rawDER : nil

        let signerCert: X509Certificate?
        if let sidSerial = sidSerialDER,
           let match = certificates.first(where: { $0.serialNumberDER == sidSerial && (sidIssuerDER == nil || $0.issuerDER == sidIssuerDER) }) {
            signerCert = match
        } else {
            signerCert = certificates.first
        }

        guard let cert = signerCert else {
            return (false, nil, "Signer certificate not found in CMS signature")
        }

        // Verify messageDigest attribute matches SHA-256(codeDirectoryBlob)
        let expectedCDDigest = Data(SHA256.hash(data: codeDirectoryBlob))
        let signedAttrs = ASN1Helper.parseSequenceChildren(from: signedAttrsContent)
        var messageDigestFound: Data? = nil

        for attr in signedAttrs {
            let attrChildren = ASN1Helper.parseSequenceChildren(from: attr.value)
            if attrChildren.count >= 2 {
                let attrOID = attrChildren[0].rawDER
                if attrOID == ASN1Helper.oidMessageDigest {
                    let setChildren = ASN1Helper.parseSequenceChildren(from: attrChildren[1].value)
                    if let digestOctet = setChildren.first {
                        messageDigestFound = digestOctet.value
                    }
                }
            }
        }

        guard let actualDigest = messageDigestFound, actualDigest == expectedCDDigest else {
            return (false, cert.subjectSummary, "CodeDirectory digest does not match CMS messageDigest attribute")
        }

        // Verify RSA signature over signedAttrs (encoded as DER SET tag 0x31)
        let signedAttrsSetDER = ASN1Helper.set(signedAttrsContent)
        let digestToVerify = SHA256.hash(data: signedAttrsSetDER)

        do {
            let rsaPublicKey = try _RSA.Signing.PublicKey(derRepresentation: cert.subjectPublicKeyInfoDER)
            let rsaSignature = _RSA.Signing.RSASignature(rawRepresentation: sigBytes)
            guard rsaPublicKey.isValidSignature(rsaSignature, for: digestToVerify, padding: .insecurePKCS1v1_5) else {
                return (false, cert.subjectSummary, "Cryptographic CMS signature verification failed")
            }
            return (true, cert.subjectSummary, nil)
        } catch {
            return (false, cert.subjectSummary, "RSA signature verification error: \(error.localizedDescription)")
        }
    }
}
