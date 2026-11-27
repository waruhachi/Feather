//
//  MachOParser.swift
//  CodeSignKit
//
//  Created by Magesh K on 28/08/26.
//  Copyright © 2026 CodeSignKit. All rights reserved.
//


import Foundation
import Crypto

public enum MachOParserError: Error {
    case invalidMachO       // The binary structure is invalid or malformed.
    case missingSignature   // The binary does not contain a code signature block.
}

/**
 Swift Parser for extracting code signature metadata and other binary information
 from single-arch (thin) and multi-arch (FAT) Mach-O binaries 
 based on public Mach-O specification.
 */
public final class MachOParser {

    public let url: URL?
    private let data: Data

    // Magic constants
    private static let FAT_MAGIC: UInt32               = 0xcafebabe          // FAT binary magic (Big-Endian)
    private static let FAT_CIGAM: UInt32               = 0xbebafeca          // FAT binary magic (Little-Endian)
    private static let FAT_MAGIC_64: UInt32            = 0xcafebabf          // 64-bit FAT binary magic (Big-Endian)
    private static let FAT_CIGAM_64: UInt32            = 0xbfbafeca          // 64-bit FAT binary magic (Little-Endian)

    private static let MH_MAGIC: UInt32                = 0xfeedface          // 32-bit Mach-O magic (Big-Endian)
    private static let MH_CIGAM: UInt32                = 0xcefaedfe          // 32-bit Mach-O magic (Little-Endian)
    private static let MH_MAGIC_64: UInt32             = 0xfeedfacf          // 64-bit Mach-O magic (Big-Endian)
    private static let MH_CIGAM_64: UInt32             = 0xcffaedfe          // 64-bit Mach-O magic (Little-Endian)

    private static let LC_CODE_SIGNATURE: UInt32       = 0x1d                // Load command type for code signatures
    private static let LC_LOAD_DYLIB: UInt32           = 0x0c                // Load command type for load dylib
    private static let LC_ENCRYPTION_INFO: UInt32      = 0x21                // Load command type for encryption info
    private static let LC_ENCRYPTION_INFO_64: UInt32   = 0x2c                // Load command type for encryption info (64-bit)
    private static let LC_MAIN: UInt32                 = 0x28 | 0x80000000   // Load command type for entry point offset
    private static let LC_SEGMENT: UInt32              = 0x01                // Load command type for 32-bit segment
    private static let LC_SEGMENT_64: UInt32           = 0x19                // Load command type for 64-bit segment
    private static let LC_VERSION_MIN_IPHONEOS: UInt32 = 0x25                // Load command type for min iOS version
    private static let LC_VERSION_MIN_MACOSX: UInt32   = 0x24                // Load command type for min macOS version
    private static let LC_VERSION_MIN_TVOS: UInt32     = 0x2f                // Load command type for min tvOS version
    private static let LC_VERSION_MIN_WATCHOS: UInt32  = 0x30                // Load command type for min watchOS version
    private static let LC_BUILD_VERSION: UInt32        = 0x32                // Load command type for build version (iOS 12+)

    private static let SUPERBLOB_MAGIC: UInt32         = 0xfade0cc0          // SuperBlob signature magic
    private static let BLOB_MAGIC_REQ: UInt32          = 0xfade7171          // Requirements blob magic
    private static let BLOB_MAGIC_ENT: UInt32          = 0xfade7172          // Entitlements blob magic

    public static func isMachOBinary(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let header = handle.readData(ofLength: 4)
        guard header.count == 4 else { return false }
        let magic = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return magic == MH_MAGIC_64 ||
               magic == MH_CIGAM_64 ||
               magic == MH_MAGIC ||
               magic == MH_CIGAM ||
               magic == FAT_MAGIC ||
               magic == FAT_CIGAM ||
               magic == FAT_MAGIC_64 ||
               magic == FAT_CIGAM_64
    }

    public static func findExecutable(at url: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        guard isDirectory else {
            return url
        }
        
        // 1. Check Info.plist directly first (authoritative source for CFBundleExecutable)
        var executableName: String? = nil
        let plistCandidates = [
            url.appendingPathComponent("Info.plist"),
            url.appendingPathComponent("Contents/Info.plist")
        ]
        for plistURL in plistCandidates {
            if let plistData = try? Data(contentsOf: plistURL),
               let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: any Sendable],
               let exec = plist["CFBundleExecutable"] as? String {
                executableName = exec
                break
            }
        }
        
        if executableName == nil {
            let bundle = Bundle(url: url)
            executableName = bundle?.infoDictionary?["CFBundleExecutable"] as? String ?? bundle?.executableURL?.lastPathComponent
        }

        // 2. If executableName is identified from Info.plist, check known candidate paths
        if let executableName = executableName {
            let candidates = [
                url.appendingPathComponent(executableName),
                url.appendingPathComponent("Contents/MacOS/\(executableName)"),
                url.appendingPathComponent("Resources/\(executableName)"),
                url.appendingPathComponent("Versions/Current/\(executableName)"),
                url.appendingPathComponent("Versions/A/\(executableName)")
            ]
            for candidate in candidates {
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        // 3. Fallback: check candidate matching bundle directory name
        let bundleBaseName = url.deletingPathExtension().lastPathComponent
        let namedCandidate = url.appendingPathComponent(bundleBaseName)
        if FileManager.default.fileExists(atPath: namedCandidate.path), isMachOBinary(at: namedCandidate) {
            return namedCandidate
        }

        // 4. Direct Mach-O fallback: scan immediate children (prefer non-dylib binaries first)
        if let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]) {
            for item in contents {
                let isItemDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if !isItemDir && item.pathExtension.lowercased() != "dylib" && isMachOBinary(at: item) {
                    return item
                }
            }
            for item in contents {
                let isItemDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if !isItemDir && isMachOBinary(at: item) {
                    return item
                }
            }
        }

        return nil
    }

    /**
     Initializes the parser with a local binary file URL or app bundle URL.
     */
    public init(url: URL) throws {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        if isDirectory {
            guard let execURL = Self.findExecutable(at: url) else {
                throw MachOParserError.invalidMachO
            }
            self.url = execURL
            self.data = try Data(contentsOf: execURL, options: .mappedIfSafe)
        } else {
            self.url = url
            self.data = try Data(contentsOf: url, options: .mappedIfSafe)
        }
    }

    /**
     Initializes the parser directly with binary data.
     */
    public init(data: Data) {
        self.url = nil
        self.data = data
    }

    /**
     Extracts the XML entitlements string from a bundle or binary URL.
     */
    public static func entitlements(at url: URL) throws -> String {
        do {
            let parser = try MachOParser(url: url)
            return try parser.entitlements()
        } catch MachOParserError.missingSignature {
            return ""
        }
    }

    /**
     Extracts the requirements string from a bundle or binary URL.
     */
    public static func requirements(at url: URL) throws -> String {
        do {
            let parser = try MachOParser(url: url)
            return try parser.requirements()
        } catch MachOParserError.missingSignature {
            return ""
        }
    }

    /**
     Returns the subdata of the thin binary slice matching the given criteria.
     Defaults to the arm64 slice if available, or the first valid slice.
     */
    public func getThinBinaryData() throws -> Data {
        guard data.count >= 4 else { throw MachOParserError.invalidMachO }
        let magic = data.readUInt32(at: 0)
        
        if magic == Self.FAT_MAGIC || magic == Self.FAT_CIGAM || magic == Self.FAT_MAGIC_64 || magic == Self.FAT_CIGAM_64 {
            let swap = (magic == Self.FAT_CIGAM || magic == Self.FAT_CIGAM_64)
            let is64 = (magic == Self.FAT_MAGIC_64 || magic == Self.FAT_CIGAM_64)
            
            let numArchs = swap ? data.readUInt32(at: 4).byteSwapped : data.readUInt32(at: 4)
            let archHeaderSize = is64 ? 32 : 20
            
            var bestSliceData: Data? = nil
            
            for i in 0..<Int(numArchs) {
                let offset = 8 + i * archHeaderSize
                let sliceCpuType = swap ? data.readUInt32(at: offset).byteSwapped : data.readUInt32(at: offset)
                
                let sliceOffset = is64 ?
                    (swap ? data.readUInt64(at: offset + 8).byteSwapped : data.readUInt64(at: offset + 8)) :
                    UInt64(swap ? data.readUInt32(at: offset + 8).byteSwapped : data.readUInt32(at: offset + 8))
                
                let sliceSize = is64 ?
                    (swap ? data.readUInt64(at: offset + 16).byteSwapped : data.readUInt64(at: offset + 16)) :
                    UInt64(swap ? data.readUInt32(at: offset + 12).byteSwapped : data.readUInt32(at: offset + 12))
                
                guard Int(sliceOffset) + Int(sliceSize) <= data.count else { continue }
                let sliceData = data.subdata(in: Int(sliceOffset)..<Int(sliceOffset + sliceSize))
                
                // Prefer ARM64 slice (cpu type 12 | 0x01000000 = 16777228)
                if sliceCpuType == 16777228 {
                    return sliceData
                }
                
                if bestSliceData == nil {
                    bestSliceData = sliceData
                }
            }
            if let bestSliceData {
                return bestSliceData
            }
            throw MachOParserError.invalidMachO
        } else {
            return data
        }
    }

    /**
     Extracts the XML entitlements string from the binary.
     */
    public func entitlements() throws -> String {
        let blob = try extractRawBlob(slotType: 5) // CSSLOT_ENTITLEMENTS = 5
        guard blob.count >= 8 else { throw MachOParserError.invalidMachO }
        let payload = blob.subdata(in: 8..<blob.count)
        guard let result = String(data: payload, encoding: .utf8) else {
            throw MachOParserError.invalidMachO
        }
        return result
    }

    /**
     Extracts the requirements string from the binary.
     */
    public func requirements() throws -> String {
        let blob = try extractRawBlob(slotType: 2) // CSSLOT_REQUIREMENTS = 2
        guard blob.count >= 8 else { throw MachOParserError.invalidMachO }
        let payload = blob.subdata(in: 8..<blob.count)
        guard let result = String(data: payload, encoding: .utf8) else {
            throw MachOParserError.invalidMachO
        }
        return result
    }

    /**
     Computes the CDHash (Code Directory Hash) of the binary.
     */
    public func cdHash() -> Data? {
        guard let cdBlob = try? extractRawBlob(slotType: 0) else { return nil } // CSSLOT_CODEDIRECTORY = 0
        guard cdBlob.count >= 40 else { return nil }
        
        let hashType = cdBlob[37] // offset 37 of CodeDirectory contains hashType
        // hashType: 1 = SHA-1, 2 = SHA-256
        if hashType == 1 {
            let digest = Insecure.SHA1.hash(data: cdBlob)
            return Data(digest)
        } else if hashType == 2 {
            let digest = SHA256.hash(data: cdBlob)
            return Data(digest)
        }
        return nil
    }

    public func bundleIdentifier() -> String? {
        guard let cdBlob = try? extractRawBlob(slotType: 0) else { return nil }
        guard cdBlob.count >= 24 else { return nil }

        let identOffset = Int(cdBlob.readUInt32BigEndian(at: 20))
        guard identOffset > 0, identOffset < cdBlob.count else { return nil }

        let identData = cdBlob.subdata(in: identOffset..<cdBlob.count)
        if let nullIndex = identData.firstIndex(of: 0) {
            let actualIdentData = identData.prefix(upTo: nullIndex)
            return String(data: actualIdentData, encoding: .utf8)
        }
        return String(data: identData, encoding: .utf8)
    }

    /**
     Extracts the Team ID of the signer from the Code Directory blob.
     */
    public func teamID() -> String? {
        guard let cdBlob = try? extractRawBlob(slotType: 0) else { return nil }
        guard cdBlob.count >= 52 else { return nil }

        let version = cdBlob.readUInt32BigEndian(at: 8)
        guard version >= 0x20200 else { return nil } // Team ID is only available in version >= 2.2

        let teamOffset = Int(cdBlob.readUInt32BigEndian(at: 48))
        guard teamOffset > 0, teamOffset < cdBlob.count else { return nil }
        let teamData = cdBlob.subdata(in: teamOffset..<cdBlob.count)
        // Read null-terminated string
        if let nullIndex = teamData.firstIndex(of: 0) {
            let actualTeamData = teamData.prefix(upTo: nullIndex)
            return String(data: actualTeamData, encoding: .utf8)
        }
        return String(data: teamData, encoding: .utf8)
    }

    /**
     Extracts the certificate chain (DER Data) used to sign the binary
     */
    public func certificates() -> [Data] {
        guard let signatureBlob = try? extractRawBlob(slotType: 0x10000) else { return [] } // CSSLOT_SIGNATURESLOT = 0x10000
        guard signatureBlob.count >= 8 else { return [] }
        let payload = signatureBlob.subdata(in: 8..<signatureBlob.count)

        return ASN1Decoder.findCertificates(in: payload)
    }

    public func x509Certificates() -> [X509Certificate] {
        certificates().compactMap { X509Certificate(der: $0) }
    }

    public func getCDHashes() -> [String] {
        guard let cdBlob = try? extractRawBlob(slotType: 0) else { return [] }
        guard cdBlob.count >= 40 else { return [] }

        let hashType = cdBlob[37]
        let digest: Data
        if hashType == 2 {
            digest = Data(SHA256.hash(data: cdBlob))
        } else {
            digest = Data(Insecure.SHA1.hash(data: cdBlob))
        }
        return [digest.map { String(format: "%02x", $0) }.joined()]
    }


    public func extractCodeDirectoryBlob() throws -> Data {
        return try extractRawBlob(slotType: 0)
    }

    public func extractSignatureBlob() throws -> Data {
        return try extractRawBlob(slotType: 0x10000)
    }

    public func extractEntitlementsBlob() throws -> Data {
        return try extractRawBlob(slotType: 5)
    }

    public func extractDEREntitlementsBlob() throws -> Data {
        return try extractRawBlob(slotType: 7)
    }

    public func extractRequirementsBlob() throws -> Data {
        return try extractRawBlob(slotType: 2)
    }




    /**
     Lists the CPU architectures present in the binary.
     */
    public func architectures() -> [String] {
        guard data.count >= 4 else { return [] }
        let magic = data.readUInt32(at: 0)
        
        if magic == Self.FAT_MAGIC || magic == Self.FAT_CIGAM || magic == Self.FAT_MAGIC_64 || magic == Self.FAT_CIGAM_64 {
            let swap = (magic == Self.FAT_CIGAM || magic == Self.FAT_CIGAM_64)
            let is64 = (magic == Self.FAT_MAGIC_64 || magic == Self.FAT_CIGAM_64)
            
            let numArchs = swap ? data.readUInt32(at: 4).byteSwapped : data.readUInt32(at: 4)
            let archHeaderSize = is64 ? 32 : 20
            
            var list = [String]()
            for i in 0..<Int(numArchs) {
                let offset = 8 + i * archHeaderSize
                let sliceCpuType = swap ? data.readUInt32(at: offset).byteSwapped : data.readUInt32(at: offset)
                let sliceCpuSubtype = swap ? data.readUInt32(at: offset + 4).byteSwapped : data.readUInt32(at: offset + 4)
                list.append(cpuName(type: sliceCpuType, subtype: sliceCpuSubtype))
            }
            return list
        } else if magic == Self.MH_MAGIC || magic == Self.MH_CIGAM || magic == Self.MH_MAGIC_64 || magic == Self.MH_CIGAM_64 {
            let swap = (magic == Self.MH_CIGAM || magic == Self.MH_CIGAM_64)
            let sliceCpuType = swap ? data.readUInt32(at: 4).byteSwapped : data.readUInt32(at: 4)
            let sliceCpuSubtype = swap ? data.readUInt32(at: 8).byteSwapped : data.readUInt32(at: 8)
            return [cpuName(type: sliceCpuType, subtype: sliceCpuSubtype)]
        }
        return []
    }

    /**
     Extracts the minimum OS version required to run this binary.
     */
    public func minimumOSVersion() -> String? {
        guard let thinData = try? getThinBinaryData() else { return nil }
        guard thinData.count >= 28 else { return nil }
        let magic = thinData.readUInt32(at: 0)
        let swap = (magic == Self.MH_CIGAM || magic == Self.MH_CIGAM_64)
        let is64 = (magic == Self.MH_MAGIC_64 || magic == Self.MH_CIGAM_64)
        let ncmds = swap ? thinData.readUInt32(at: 16).byteSwapped : thinData.readUInt32(at: 16)
        let headerSize = is64 ? 32 : 28
        
        var offset = headerSize
        for _ in 0..<Int(ncmds) {
            guard offset + 8 <= thinData.count else { break }
            let cmd = swap ? thinData.readUInt32(at: offset).byteSwapped : thinData.readUInt32(at: offset)
            let cmdsize = swap ? thinData.readUInt32(at: offset + 4).byteSwapped : thinData.readUInt32(at: offset + 4)
            
            if cmd == Self.LC_VERSION_MIN_IPHONEOS || cmd == Self.LC_VERSION_MIN_MACOSX || cmd == Self.LC_VERSION_MIN_TVOS || cmd == Self.LC_VERSION_MIN_WATCHOS {
                guard offset + 12 <= thinData.count else { break }
                let version = swap ? thinData.readUInt32(at: offset + 8).byteSwapped : thinData.readUInt32(at: offset + 8)
                return formatVersion(version)
            } else if cmd == Self.LC_BUILD_VERSION {
                guard offset + 16 <= thinData.count else { break }
                let minos = swap ? thinData.readUInt32(at: offset + 12).byteSwapped : thinData.readUInt32(at: offset + 12)
                return formatVersion(minos)
            }
            offset += Int(cmdsize)
        }
        return nil
    }

    private func cpuName(type: UInt32, subtype: UInt32) -> String {
        switch type {
        case 7:
            return "i386"
        case 16777223:
            return "x86_64"
        case 12:
            switch subtype {
            case 9: return "armv7"
            case 11: return "armv7s"
            default: return "arm"
            }
        case 16777228:
            switch subtype {
            case 2: return "arm64e"
            default: return "arm64"
            }
        default:
            return "Unknown (\(type))"
        }
    }

    private func formatVersion(_ version: UInt32) -> String {
        let major = (version >> 16) & 0xFFFF
        let minor = (version >> 8) & 0xFF
        let patch = version & 0xFF
        return "\(major).\(minor).\(patch)"
    }

    /**
     Identifies the target platform type (e.g. iOS, macOS, tvOS, watchOS).
     */
    public func platformType() -> String? {
        guard let thinData = try? getThinBinaryData() else { return nil }
        guard thinData.count >= 28 else { return nil }
        let magic = thinData.readUInt32(at: 0)
        let swap = (magic == Self.MH_CIGAM || magic == Self.MH_CIGAM_64)
        let is64 = (magic == Self.MH_MAGIC_64 || magic == Self.MH_CIGAM_64)
        let ncmds = swap ? thinData.readUInt32(at: 16).byteSwapped : thinData.readUInt32(at: 16)
        let headerSize = is64 ? 32 : 28
        
        var offset = headerSize
        for _ in 0..<Int(ncmds) {
            guard offset + 8 <= thinData.count else { break }
            let cmd = swap ? thinData.readUInt32(at: offset).byteSwapped : thinData.readUInt32(at: offset)
            let cmdsize = swap ? thinData.readUInt32(at: offset + 4).byteSwapped : thinData.readUInt32(at: offset + 4)
            
            if cmd == Self.LC_VERSION_MIN_IPHONEOS {
                return "iOS"
            } else if cmd == Self.LC_VERSION_MIN_MACOSX {
                return "macOS"
            } else if cmd == Self.LC_VERSION_MIN_TVOS {
                return "tvOS"
            } else if cmd == Self.LC_VERSION_MIN_WATCHOS {
                return "watchOS"
            } else if cmd == Self.LC_BUILD_VERSION {
                guard offset + 12 <= thinData.count else { break }
                let platform = swap ? thinData.readUInt32(at: offset + 8).byteSwapped : thinData.readUInt32(at: offset + 8)
                switch platform {
                case 1: return "macOS"
                case 2: return "iOS"
                case 3: return "tvOS"
                case 4: return "watchOS"
                case 6: return "iOS Simulator"
                case 7: return "tvOS Simulator"
                case 8: return "watchOS Simulator"
                case 9: return "macCatalyst"
                default: return "unknown"
                }
            }
            offset += Int(cmdsize)
        }
        return nil
    }

    /**
     Lists the paths of all linked dynamic libraries (dylibs) in the binary.
     */
    public func linkedLibraries() -> [String] {
        guard let thinData = try? getThinBinaryData() else { return [] }
        guard thinData.count >= 28 else { return [] }
        let magic = thinData.readUInt32(at: 0)
        let swap = (magic == Self.MH_CIGAM || magic == Self.MH_CIGAM_64)
        let is64 = (magic == Self.MH_MAGIC_64 || magic == Self.MH_CIGAM_64)
        let ncmds = swap ? thinData.readUInt32(at: 16).byteSwapped : thinData.readUInt32(at: 16)
        let headerSize = is64 ? 32 : 28
        
        var list = [String]()
        var offset = headerSize
        for _ in 0..<Int(ncmds) {
            guard offset + 8 <= thinData.count else { break }
            let cmd = swap ? thinData.readUInt32(at: offset).byteSwapped : thinData.readUInt32(at: offset)
            let cmdsize = swap ? thinData.readUInt32(at: offset + 4).byteSwapped : thinData.readUInt32(at: offset + 4)
            
            if cmd == Self.LC_LOAD_DYLIB {
                guard offset + 12 <= thinData.count else { break }
                let nameOffset = swap ? thinData.readUInt32(at: offset + 8).byteSwapped : thinData.readUInt32(at: offset + 8)
                let nameStart = offset + Int(nameOffset)
                guard nameStart < thinData.count else { break }
                let pathData = thinData.subdata(in: nameStart..<offset + Int(cmdsize))
                if let nullIndex = pathData.firstIndex(of: 0) {
                    let actualPathData = pathData.prefix(upTo: nullIndex)
                    if let path = String(data: actualPathData, encoding: .utf8) {
                        list.append(path)
                    }
                } else if let path = String(data: pathData, encoding: .utf8) {
                    list.append(path)
                }
            }
            offset += Int(cmdsize)
        }
        return list
    }

    /**
     Checks if the binary is encrypted with FairPlay DRM.
     */
    public func isEncrypted() -> Bool {
        guard let thinData = try? getThinBinaryData() else { return false }
        guard thinData.count >= 28 else { return false }
        let magic = thinData.readUInt32(at: 0)
        let swap = (magic == Self.MH_CIGAM || magic == Self.MH_CIGAM_64)
        let is64 = (magic == Self.MH_MAGIC_64 || magic == Self.MH_CIGAM_64)
        let ncmds = swap ? thinData.readUInt32(at: 16).byteSwapped : thinData.readUInt32(at: 16)
        let headerSize = is64 ? 32 : 28
        
        var offset = headerSize
        for _ in 0..<Int(ncmds) {
            guard offset + 8 <= thinData.count else { break }
            let cmd = swap ? thinData.readUInt32(at: offset).byteSwapped : thinData.readUInt32(at: offset)
            let cmdsize = swap ? thinData.readUInt32(at: offset + 4).byteSwapped : thinData.readUInt32(at: offset + 4)
            
            if cmd == Self.LC_ENCRYPTION_INFO || cmd == Self.LC_ENCRYPTION_INFO_64 {
                guard offset + 20 <= thinData.count else { break }
                let cryptid = swap ? thinData.readUInt32(at: offset + 16).byteSwapped : thinData.readUInt32(at: offset + 16)
                return cryptid != 0
            }
            offset += Int(cmdsize)
        }
        return false
    }

    /**
     Extracts the execution entry point offset from the binary.
     */
    public func entryPoint() -> UInt64? {
        guard let thinData = try? getThinBinaryData() else { return nil }
        guard thinData.count >= 28 else { return nil }
        let magic = thinData.readUInt32(at: 0)
        let swap = (magic == Self.MH_CIGAM || magic == Self.MH_CIGAM_64)
        let is64 = (magic == Self.MH_MAGIC_64 || magic == Self.MH_CIGAM_64)
        let ncmds = swap ? thinData.readUInt32(at: 16).byteSwapped : thinData.readUInt32(at: 16)
        let headerSize = is64 ? 32 : 28
        
        var offset = headerSize
        for _ in 0..<Int(ncmds) {
            guard offset + 8 <= thinData.count else { break }
            let cmd = swap ? thinData.readUInt32(at: offset).byteSwapped : thinData.readUInt32(at: offset)
            let cmdsize = swap ? thinData.readUInt32(at: offset + 4).byteSwapped : thinData.readUInt32(at: offset + 4)
            
            if cmd == Self.LC_MAIN {
                guard offset + 16 <= thinData.count else { break }
                let entryoff = swap ? thinData.readUInt64(at: offset + 8).byteSwapped : thinData.readUInt64(at: offset + 8)
                return entryoff
            }
            offset += Int(cmdsize)
        }
        return nil
    }

    /**
     Lists the segments parsed from the binary load commands.
     */
    public func segments() -> [(name: String, offset: UInt64, size: UInt64)] {
        guard let thinData = try? getThinBinaryData() else { return [] }
        guard thinData.count >= 28 else { return [] }
        let magic = thinData.readUInt32(at: 0)
        let swap = (magic == Self.MH_CIGAM || magic == Self.MH_CIGAM_64)
        let is64 = (magic == Self.MH_MAGIC_64 || magic == Self.MH_CIGAM_64)
        let ncmds = swap ? thinData.readUInt32(at: 16).byteSwapped : thinData.readUInt32(at: 16)
        let headerSize = is64 ? 32 : 28
        
        var list = [(name: String, offset: UInt64, size: UInt64)]()
        var offset = headerSize
        for _ in 0..<Int(ncmds) {
            guard offset + 8 <= thinData.count else { break }
            let cmd = swap ? thinData.readUInt32(at: offset).byteSwapped : thinData.readUInt32(at: offset)
            let cmdsize = swap ? thinData.readUInt32(at: offset + 4).byteSwapped : thinData.readUInt32(at: offset + 4)
            
            if cmd == Self.LC_SEGMENT {
                guard offset + 32 <= thinData.count else { break }
                let nameData = thinData.subdata(in: offset + 8..<offset + 24)
                let name = String(data: nameData.prefix(while: { $0 != 0 }), encoding: .utf8) ?? "unknown"
                let vmaddr = swap ? thinData.readUInt32(at: offset + 24).byteSwapped : thinData.readUInt32(at: offset + 24)
                let vmsize = swap ? thinData.readUInt32(at: offset + 28).byteSwapped : thinData.readUInt32(at: offset + 28)
                list.append((name: name, offset: UInt64(vmaddr), size: UInt64(vmsize)))
            } else if cmd == Self.LC_SEGMENT_64 {
                guard offset + 40 <= thinData.count else { break }
                let nameData = thinData.subdata(in: offset + 8..<offset + 24)
                let name = String(data: nameData.prefix(while: { $0 != 0 }), encoding: .utf8) ?? "unknown"
                let vmaddr = swap ? thinData.readUInt64(at: offset + 24).byteSwapped : thinData.readUInt64(at: offset + 24)
                let vmsize = swap ? thinData.readUInt64(at: offset + 32).byteSwapped : thinData.readUInt64(at: offset + 32)
                list.append((name: name, offset: vmaddr, size: vmsize))
            }
            offset += Int(cmdsize)
        }
        return list
    }

    private func extractRawBlob(slotType: UInt32) throws -> Data {
        let thinData = try getThinBinaryData()
        guard thinData.count >= 28 else { throw MachOParserError.invalidMachO }
        let magic = thinData.readUInt32(at: 0)
        guard magic == Self.MH_MAGIC || magic == Self.MH_CIGAM || magic == Self.MH_MAGIC_64 || magic == Self.MH_CIGAM_64 else {
            throw MachOParserError.invalidMachO
        }
        
        let swap = (magic == Self.MH_CIGAM || magic == Self.MH_CIGAM_64)
        let is64 = (magic == Self.MH_MAGIC_64 || magic == Self.MH_CIGAM_64)
        
        let ncmds = swap ? thinData.readUInt32(at: 16).byteSwapped : thinData.readUInt32(at: 16)
        let headerSize = is64 ? 32 : 28
        
        var offset = headerSize
        for _ in 0..<Int(ncmds) {
            guard offset + 8 <= thinData.count else { throw MachOParserError.invalidMachO }
            let cmd = swap ? thinData.readUInt32(at: offset).byteSwapped : thinData.readUInt32(at: offset)
            let cmdsize = swap ? thinData.readUInt32(at: offset + 4).byteSwapped : thinData.readUInt32(at: offset + 4)
            
            if cmd == Self.LC_CODE_SIGNATURE {
                guard offset + 16 <= thinData.count else { throw MachOParserError.invalidMachO }
                let dataoff = swap ? thinData.readUInt32(at: offset + 8).byteSwapped : thinData.readUInt32(at: offset + 8)
                let datasize = swap ? thinData.readUInt32(at: offset + 12).byteSwapped : thinData.readUInt32(at: offset + 12)
                
                guard Int(dataoff) + Int(datasize) <= thinData.count else { throw MachOParserError.invalidMachO }
                let sigData = thinData.subdata(in: Int(dataoff)..<Int(dataoff + datasize))
                return try parseRawSignatureBlob(sigData, slotType: slotType)
            }
            offset += Int(cmdsize)
        }
        throw MachOParserError.missingSignature
    }

    private func parseRawSignatureBlob(_ data: Data, slotType: UInt32) throws -> Data {
        guard data.count >= 12 else { throw MachOParserError.invalidMachO }
        let magic = data.readUInt32BigEndian(at: 0)
        guard magic == Self.SUPERBLOB_MAGIC else { throw MachOParserError.invalidMachO }
        
        let count = data.readUInt32BigEndian(at: 8)
        for i in 0..<Int(count) {
            let offset = 12 + i * 8
            guard offset + 8 <= data.count else { throw MachOParserError.invalidMachO }
            let type = data.readUInt32BigEndian(at: offset)
            let blobOffset = data.readUInt32BigEndian(at: offset + 4)
            
            if type == slotType {
                let absOffset = Int(blobOffset)
                guard absOffset + 8 <= data.count else { throw MachOParserError.invalidMachO }
                let length = data.readUInt32BigEndian(at: absOffset + 4)
                
                guard absOffset + Int(length) <= data.count else { throw MachOParserError.invalidMachO }
                return data.subdata(in: absOffset..<absOffset + Int(length))
            }
        }
        throw MachOParserError.missingSignature
    }
}

fileprivate struct ASN1Decoder {
    static func findCertificates(in data: Data) -> [Data] {
        var results = [Data]()
        var offset = 0
        
        while offset < data.count - 4 {
            guard data[offset] == 0x30 else {
                offset += 1
                continue
            }
            
            let tagOffset = offset
            var cursor = offset + 1
            
            let lengthByte = data[cursor]
            cursor += 1
            
            var length = Int(lengthByte)
            if lengthByte & 0x80 != 0 {
                let numBytes = Int(lengthByte & 0x7F)
                guard numBytes > 0 && numBytes <= 4 && cursor + numBytes <= data.count else {
                    offset += 1
                    continue
                }
                var val = 0
                for i in 0..<numBytes {
                    val = (val << 8) | Int(data[cursor + i])
                }
                cursor += numBytes
                length = val
            }
            
            let totalCertLength = (cursor - tagOffset) + length
            guard length >= 200 && length <= 8192 && tagOffset + totalCertLength <= data.count else {
                offset += 1
                continue
            }
            
            let candidateData = data.subdata(in: tagOffset..<tagOffset + totalCertLength)
            let headerLen = cursor - tagOffset
            if headerLen < candidateData.count && candidateData[headerLen] == 0x30 {
                results.append(candidateData)
                offset += totalCertLength
            } else {
                offset += 1
            }
        }
        
        return results
    }
}
