//
//  CodeDirectoryBuilder.swift
//  CodeSignKit
//
//  Created by Magesh K on 28/08/26.
//  Copyright © 2026 CodeSignKit. All rights reserved.
//


import Foundation
import Crypto

public final class CodeDirectoryBuilder {


    private let binaryData: Data
    private let codeLimit: Int
    private let bundleIdentifier: String
    private let teamIdentifier: String?
    private let flags: UInt32
    private let hashType: UInt8
    private let hashSize: Int
    private let pageSizeShift: UInt8
    private let execSegBase: UInt64
    private let execSegLimit: UInt64
    private let execSegFlags: UInt64

    private var specialSlots: [UInt32: Data] = [:]

    public init(
        binaryData: Data,
        codeLimit: Int,
        bundleIdentifier: String,
        teamIdentifier: String?,
        flags: UInt32 = 0,
        hashType: UInt8 = CodeSigningConstants.CS_HASHTYPE_SHA256,
        pageSizeShift: UInt8 = 14,
        execSegBase: UInt64 = 0,
        execSegLimit: UInt64 = 0,
        execSegFlags: UInt64 = 0
    ) {
        self.binaryData = binaryData
        self.codeLimit = codeLimit
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.flags = flags
        self.hashType = hashType
        self.hashSize = (hashType == CodeSigningConstants.CS_HASHTYPE_SHA1) ? 20 : 32
        self.pageSizeShift = pageSizeShift
        self.execSegBase = execSegBase
        self.execSegLimit = execSegLimit
        self.execSegFlags = execSegFlags
    }

    public func setSpecialSlot(_ slot: UInt32, data: Data) {
        if hashType == CodeSigningConstants.CS_HASHTYPE_SHA256 {
            let digest = SHA256.hash(data: data)
            specialSlots[slot] = Data(digest)
        } else {
            let digest = Insecure.SHA1.hash(data: data)
            specialSlots[slot] = Data(digest)
        }
    }

    public func setSpecialSlotDigest(_ slot: UInt32, digest: Data) {
        specialSlots[slot] = digest
    }

    public func build() -> Data {
        let pageSize = 1 << Int(pageSizeShift)
        let numPages = (codeLimit + pageSize - 1) / pageSize

        // 1. Calculate max special slot index
        let maxSpecialSlot = specialSlots.keys.max() ?? 0
        let numSpecialSlots = Int(maxSpecialSlot)

        // 2. Prepare strings
        let identBytes = bundleIdentifier.data(using: .utf8)! + Data([0])
        let teamBytes = (teamIdentifier?.data(using: .utf8) ?? Data()) + ((teamIdentifier != nil) ? Data([0]) : Data())

        // 3. Header size calculation (Version 0x20400 header = 88 bytes)
        let headerSize = 88
        let identOffset = headerSize
        let teamOffset = teamIdentifier != nil ? (identOffset + identBytes.count) : 0
        let stringsSize = identBytes.count + (teamIdentifier != nil ? teamBytes.count : 0)

        // 4. hashOffset in CodeDirectory points to the hash of code slot 0!
        let hashOffset = headerSize + stringsSize
        let actualHashOffset = hashOffset + (numSpecialSlots * hashSize)
        let totalSize = actualHashOffset + (numPages * hashSize)

        var cdData = Data(count: totalSize)

        // 5. Write header fields (Big-Endian)
        cdData.writeUInt32BigEndian(CodeSigningConstants.CSMAGIC_CODEDIRECTORY, at: 0)
        cdData.writeUInt32BigEndian(UInt32(totalSize), at: 4)
        cdData.writeUInt32BigEndian(CodeSigningConstants.CS_SUPPORTED_CD_VERSION, at: 8)
        cdData.writeUInt32BigEndian(flags, at: 12) // flags
        cdData.writeUInt32BigEndian(UInt32(actualHashOffset), at: 16)
        cdData.writeUInt32BigEndian(UInt32(identOffset), at: 20)
        cdData.writeUInt32BigEndian(UInt32(numSpecialSlots), at: 24)
        cdData.writeUInt32BigEndian(UInt32(numPages), at: 28)
        cdData.writeUInt32BigEndian(UInt32(codeLimit), at: 32)
        cdData[36] = UInt8(hashSize)
        cdData[37] = hashType
        cdData[38] = 0 // platform
        cdData[39] = pageSizeShift
        cdData.writeUInt32BigEndian(0, at: 40) // spare2
        cdData.writeUInt32BigEndian(0, at: 44) // scatterOffset
        cdData.writeUInt32BigEndian(UInt32(teamOffset), at: 48)

        cdData.writeUInt32BigEndian(0, at: 52) // spare3
        cdData.writeUInt64BigEndian(0, at: 56) // codeLimit64
        cdData.writeUInt64BigEndian(execSegBase, at: 64)
        cdData.writeUInt64BigEndian(execSegLimit, at: 72)
        cdData.writeUInt64BigEndian(execSegFlags, at: 80)

        // 6. Write identifier & team ID strings
        cdData.replaceSubrange(identOffset..<identOffset + identBytes.count, with: identBytes)
        if teamIdentifier != nil && teamOffset > 0 {
            cdData.replaceSubrange(teamOffset..<teamOffset + teamBytes.count, with: teamBytes)
        }

        // 7. Write special slots (slots 1 to N placed backwards from actualHashOffset)
        let emptyHash = Data(repeating: 0, count: hashSize)
        for slot in 1...max(numSpecialSlots, 1) {
            guard slot <= numSpecialSlots else { break }
            let slotData = specialSlots[UInt32(slot)] ?? emptyHash
            let slotOffset = actualHashOffset - (slot * hashSize)
            cdData.replaceSubrange(slotOffset..<slotOffset + hashSize, with: slotData)
        }

        // 8. Hash binary code pages (0..<numPages)
        for i in 0..<numPages {
            let pageStart = i * pageSize
            let pageEnd = min(pageStart + pageSize, codeLimit)
            let pageData = binaryData.subdata(in: pageStart..<pageEnd)

            let pageHash: Data
            if hashType == CodeSigningConstants.CS_HASHTYPE_SHA256 {
                let digest = SHA256.hash(data: pageData)
                pageHash = Data(digest)
            } else {
                let digest = Insecure.SHA1.hash(data: pageData)
                pageHash = Data(digest)
            }


            let codeOffset = actualHashOffset + (i * hashSize)
            cdData.replaceSubrange(codeOffset..<codeOffset + hashSize, with: pageHash)
        }

        return cdData
    }
}

