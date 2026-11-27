//
//  CodeSignerTypes.swift
//  CodeSignKit
//
//  Created by Magesh K on 28/08/26.
//  Copyright © 2026 CodeSignKit. All rights reserved.
//


import Foundation

public enum CodeSignerError: Error, LocalizedError {
    case invalidPath(String)
    case invalidMachO(String)
    case signingFailed(String)
    case certificateError(String)
    case ioError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let msg): return "Invalid path: \(msg)"
        case .invalidMachO(let msg): return "Invalid Mach-O binary: \(msg)"
        case .signingFailed(let msg): return "Code signing failed: \(msg)"
        case .certificateError(let msg): return "Certificate error: \(msg)"
        case .ioError(let msg): return "I/O error: \(msg)"
        }
    }
}

public struct CodeSigningOptions: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let adHoc           = CodeSigningOptions(rawValue: CodeSigningConstants.CS_ADHOC)
    public static let hard            = CodeSigningOptions(rawValue: CodeSigningConstants.CS_HARD)
    public static let kill            = CodeSigningOptions(rawValue: CodeSigningConstants.CS_KILL)
    public static let checkExpiration = CodeSigningOptions(rawValue: CodeSigningConstants.CS_CHECK_EXPIRATION)
    public static let restrict        = CodeSigningOptions(rawValue: CodeSigningConstants.CS_RESTRICT)
    public static let enforcement     = CodeSigningOptions(rawValue: CodeSigningConstants.CS_ENFORCEMENT)
    public static let requireLV       = CodeSigningOptions(rawValue: CodeSigningConstants.CS_REQUIRE_LV)
    public static let hardenedRuntime = CodeSigningOptions(rawValue: CodeSigningConstants.CS_RUNTIME)
    public static let linkerSigned    = CodeSigningOptions(rawValue: CodeSigningConstants.CS_LINKER_SIGNED)
}

public enum CodeSigningConstants {
    // SuperBlob and Slot Magics
    public static let CSMAGIC_EMBEDDED_SIGNATURE: UInt32  = 0xfade0cc0
    public static let CSMAGIC_CODEDIRECTORY: UInt32       = 0xfade0c02
    public static let CSMAGIC_REQUIREMENTS: UInt32        = 0xfade0c01
    public static let CSMAGIC_REQUIREMENT: UInt32         = 0xfade0c00
    public static let CSMAGIC_ENTITLEMENTS: UInt32        = 0xfade7171
    public static let CSMAGIC_DER_ENTITLEMENTS: UInt32    = 0xfade7172
    public static let CSMAGIC_BLOBWRAPPER: UInt32         = 0xfade0b01


    // CodeDirectory Flags
    public static let CS_ADHOC: UInt32            = 0x00000002
    public static let CS_HARD: UInt32             = 0x00000100
    public static let CS_KILL: UInt32             = 0x00000200
    public static let CS_CHECK_EXPIRATION: UInt32 = 0x00000400
    public static let CS_RESTRICT: UInt32         = 0x00000800
    public static let CS_ENFORCEMENT: UInt32      = 0x00001000
    public static let CS_REQUIRE_LV: UInt32       = 0x00002000
    public static let CS_RUNTIME: UInt32          = 0x00010000
    public static let CS_LINKER_SIGNED: UInt32    = 0x00020000

    // Executable Segment Flags
    public static let CS_EXECSEG_MAIN_BINARY: UInt64      = 0x1
    public static let CS_EXECSEG_ALLOW_UNSIGNED: UInt64   = 0x10

    // Mach-O File Types
    public static let MH_EXECUTE: UInt32                  = 0x02
    public static let MH_DYLIB: UInt32                    = 0x06
    public static let MH_BUNDLE: UInt32                   = 0x08


    // Slot Numbers
    public static let CSSLOT_CODEDIRECTORY: UInt32               = 0
    public static let CSSLOT_INFOSLOT: UInt32                    = 1
    public static let CSSLOT_REQUIREMENTS: UInt32                = 2
    public static let CSSLOT_RESOURCEDIR: UInt32                 = 3
    public static let CSSLOT_APPLICATION: UInt32                 = 4
    public static let CSSLOT_ENTITLEMENTS: UInt32                = 5
    public static let CSSLOT_DER_ENTITLEMENTS: UInt32            = 7
    public static let CSSLOT_ALTERNATE_CODEDIRECTORIES: UInt32   = 0x1000
    public static let CSSLOT_SIGNATURESLOT: UInt32               = 0x10000

    // Hash Types
    public static let CS_HASHTYPE_SHA1: UInt8   = 1
    public static let CS_HASHTYPE_SHA256: UInt8 = 2

    public static let CS_HASH_SIZE_SHA1   = 20
    public static let CS_HASH_SIZE_SHA256 = 32

    // Page Size (4096 bytes = 2^12)
    public static let CS_PAGE_SIZE_SHIFT: UInt8 = 12
    public static let CS_PAGE_SIZE: Int = 1 << Int(CS_PAGE_SIZE_SHIFT) // 4096

    // CodeDirectory Versions
    public static let CS_SUPPORTED_CD_VERSION: UInt32 = 0x20400 // Supports execSegBase, execSegLimit, execSegFlags

    // Mach-O Load Commands
    public static let LC_SEGMENT: UInt32         = 0x01
    public static let LC_SEGMENT_64: UInt32      = 0x19
    public static let LC_CODE_SIGNATURE: UInt32  = 0x1d

    // Mach-O Magics
    public static let MH_MAGIC: UInt32     = 0xfeedface
    public static let MH_CIGAM: UInt32     = 0xcefaedfe
    public static let MH_MAGIC_64: UInt32  = 0xfeedfacf
    public static let MH_CIGAM_64: UInt32  = 0xcffaedfe
    public static let FAT_MAGIC: UInt32    = 0xcafebabe
    public static let FAT_CIGAM: UInt32    = 0xbebafeca
    public static let FAT_MAGIC_64: UInt32 = 0xcafebabf
    public static let FAT_CIGAM_64: UInt32 = 0xbfbafeca
}
