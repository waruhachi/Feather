//
//  MachOSigner.swift
//  CodeSignKit
//
//  Created by Magesh K on 28/08/26.
//  Copyright © 2026 CodeSignKit. All rights reserved.
//


import Foundation

public final class MachOSigner {

    private let binaryData: Data
    private let bundleIdentifier: String
    private let teamIdentifier: String?
    private let entitlementsXML: String?
    private let infoPlistData: Data?
    private let codeResourcesData: Data?
    private let cmsSigner: CMSSigner?
    private let options: CodeSigningOptions

    public init(
        binaryData: Data,
        bundleIdentifier: String,
        teamIdentifier: String?,
        entitlementsXML: String?,
        infoPlistData: Data?,
        codeResourcesData: Data?,
        cmsSigner: CMSSigner?,
        options: CodeSigningOptions = []
    ) {
        self.binaryData = binaryData
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.entitlementsXML = entitlementsXML
        self.infoPlistData = infoPlistData
        self.codeResourcesData = codeResourcesData
        self.cmsSigner = cmsSigner
        self.options = options
    }


    public func sign() throws -> Data {
        guard binaryData.count >= 4 else {
            throw CodeSignerError.invalidMachO("Binary too short")
        }

        let magic = binaryData.readUInt32(at: 0)

        // Check if FAT binary
        if magic == CodeSigningConstants.FAT_MAGIC || magic == CodeSigningConstants.FAT_CIGAM ||
           magic == CodeSigningConstants.FAT_MAGIC_64 || magic == CodeSigningConstants.FAT_CIGAM_64 {
            return try signFatBinary()
        } else if magic == CodeSigningConstants.MH_MAGIC_64 || magic == CodeSigningConstants.MH_CIGAM_64 ||
                  magic == CodeSigningConstants.MH_MAGIC || magic == CodeSigningConstants.MH_CIGAM {
            return try signThinBinary(sliceData: binaryData)
        } else {
            throw CodeSignerError.invalidMachO("Unrecognized Mach-O magic: \(String(format: "0x%08X", magic))")
        }
    }

    private func signFatBinary() throws -> Data {
        let magic = binaryData.readUInt32(at: 0)
        let swap = (magic == CodeSigningConstants.FAT_CIGAM || magic == CodeSigningConstants.FAT_CIGAM_64)
        let is64 = (magic == CodeSigningConstants.FAT_MAGIC_64 || magic == CodeSigningConstants.FAT_CIGAM_64)

        guard binaryData.count >= 8 else { throw CodeSignerError.invalidMachO("FAT binary header too short") }
        let numArchs = swap ? binaryData.readUInt32(at: 4).byteSwapped : binaryData.readUInt32(at: 4)
        let archHeaderSize = is64 ? 32 : 20

        var signedSlices: [(headerData: Data, sliceData: Data, align: Int)] = []
        var runningOffset = 8 + (Int(numArchs) * archHeaderSize)

        for i in 0..<Int(numArchs) {
            let offset = 8 + (i * archHeaderSize)
            guard offset + archHeaderSize <= binaryData.count else {
                throw CodeSignerError.invalidMachO("FAT slice header out of bounds")
            }

            let sliceHeader = binaryData.subdata(in: offset..<offset + archHeaderSize)
            let sliceOffset = is64 ?
                (swap ? binaryData.readUInt64(at: offset + 8).byteSwapped : binaryData.readUInt64(at: offset + 8)) :
                UInt64(swap ? binaryData.readUInt32(at: offset + 8).byteSwapped : binaryData.readUInt32(at: offset + 8))
            let sliceSize = is64 ?
                (swap ? binaryData.readUInt64(at: offset + 16).byteSwapped : binaryData.readUInt64(at: offset + 16)) :
                UInt64(swap ? binaryData.readUInt32(at: offset + 12).byteSwapped : binaryData.readUInt32(at: offset + 12))
            let alignPower = is64 ?
                (swap ? binaryData.readUInt32(at: offset + 24).byteSwapped : binaryData.readUInt32(at: offset + 24)) :
                (swap ? binaryData.readUInt32(at: offset + 16).byteSwapped : binaryData.readUInt32(at: offset + 16))

            let alignment = 1 << Int(alignPower)

            guard Int(sliceOffset + sliceSize) <= binaryData.count else {
                throw CodeSignerError.invalidMachO("FAT slice bounds exceed file size")
            }

            let rawSlice = binaryData.subdata(in: Int(sliceOffset)..<Int(sliceOffset + sliceSize))
            let signedSlice = try signThinBinary(sliceData: rawSlice)

            // Align running offset
            let rem = runningOffset % alignment
            if rem != 0 {
                runningOffset += (alignment - rem)
            }

            var updatedHeader = sliceHeader
            if is64 {
                updatedHeader.writeUInt64(swap ? UInt64(runningOffset).byteSwapped : UInt64(runningOffset), at: 8)
                updatedHeader.writeUInt64(swap ? UInt64(signedSlice.count).byteSwapped : UInt64(signedSlice.count), at: 16)
            } else {
                updatedHeader.writeUInt32(swap ? UInt32(runningOffset).byteSwapped : UInt32(runningOffset), at: 8)
                updatedHeader.writeUInt32(swap ? UInt32(signedSlice.count).byteSwapped : UInt32(signedSlice.count), at: 12)
            }

            signedSlices.append((headerData: updatedHeader, sliceData: signedSlice, align: alignment))
            runningOffset += signedSlice.count
        }

        // Reconstruct FAT binary
        var result = Data(capacity: runningOffset)
        // Write FAT header
        result.append(binaryData.subdata(in: 0..<8))
        // Write slice headers
        for slice in signedSlices {
            result.append(slice.headerData)
        }

        for slice in signedSlices {
            let rem = result.count % slice.align
            if rem != 0 {
                result.append(Data(repeating: 0, count: slice.align - rem))
            }
            result.append(slice.sliceData)
        }

        return result
    }

    private func signThinBinary(sliceData: Data) throws -> Data {
        guard sliceData.count >= 28 else {
            throw CodeSignerError.invalidMachO("Thin binary too small")
        }

        let workingData = sliceData
        let magic = workingData.readUInt32(at: 0)
        let swap = (magic == CodeSigningConstants.MH_CIGAM || magic == CodeSigningConstants.MH_CIGAM_64)
        let is64 = (magic == CodeSigningConstants.MH_MAGIC_64 || magic == CodeSigningConstants.MH_CIGAM_64)

        let headerSize = is64 ? 32 : 28
        let ncmds = swap ? workingData.readUInt32(at: 16).byteSwapped : workingData.readUInt32(at: 16)
        let sizeofcmds = swap ? workingData.readUInt32(at: 20).byteSwapped : workingData.readUInt32(at: 20)

        let cputype = swap ? workingData.readUInt32(at: 4).byteSwapped : workingData.readUInt32(at: 4)
        let filetype = swap ? workingData.readUInt32(at: 12).byteSwapped : workingData.readUInt32(at: 12)
        let isExecutable = (filetype == CodeSigningConstants.MH_EXECUTE)
        let pageSizeShift: UInt8 = (cputype == 0x0100000c || cputype == 12) ? 14 : 12

        var linkeditCmdOffset: Int? = nil
        var linkeditFileOff: UInt64 = 0
        var linkeditFileSize: UInt64 = 0

        var textFileOff: UInt64 = 0
        var textFileSize: UInt64 = 0

        var codeSigCmdOffset: Int? = nil
        var codeSigDataOff: UInt32 = 0
        var codeSigDataSize: UInt32 = 0

        var cursor = headerSize
        for _ in 0..<Int(ncmds) {
            guard cursor + 8 <= workingData.count else { break }
            let cmd = swap ? workingData.readUInt32(at: cursor).byteSwapped : workingData.readUInt32(at: cursor)
            let cmdsize = swap ? workingData.readUInt32(at: cursor + 4).byteSwapped : workingData.readUInt32(at: cursor + 4)

            if cmd == CodeSigningConstants.LC_SEGMENT_64 {
                let segNameData = workingData.subdata(in: cursor + 8..<cursor + 24)
                let segName = String(data: segNameData.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""

                if segName == "__TEXT" {
                    textFileOff = swap ? workingData.readUInt64(at: cursor + 40).byteSwapped : workingData.readUInt64(at: cursor + 40)
                    textFileSize = swap ? workingData.readUInt64(at: cursor + 48).byteSwapped : workingData.readUInt64(at: cursor + 48)
                } else if segName == "__LINKEDIT" {
                    linkeditCmdOffset = cursor
                    linkeditFileOff = swap ? workingData.readUInt64(at: cursor + 40).byteSwapped : workingData.readUInt64(at: cursor + 40)
                    linkeditFileSize = swap ? workingData.readUInt64(at: cursor + 48).byteSwapped : workingData.readUInt64(at: cursor + 48)
                }
            } else if cmd == CodeSigningConstants.LC_SEGMENT {
                let segNameData = workingData.subdata(in: cursor + 8..<cursor + 24)
                let segName = String(data: segNameData.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""

                if segName == "__TEXT" {
                    textFileOff = UInt64(swap ? workingData.readUInt32(at: cursor + 32).byteSwapped : workingData.readUInt32(at: cursor + 32))
                    textFileSize = UInt64(swap ? workingData.readUInt32(at: cursor + 36).byteSwapped : workingData.readUInt32(at: cursor + 36))
                } else if segName == "__LINKEDIT" {
                    linkeditCmdOffset = cursor
                    linkeditFileOff = UInt64(swap ? workingData.readUInt32(at: cursor + 32).byteSwapped : workingData.readUInt32(at: cursor + 32))
                    linkeditFileSize = UInt64(swap ? workingData.readUInt32(at: cursor + 36).byteSwapped : workingData.readUInt32(at: cursor + 36))
                }
            } else if cmd == CodeSigningConstants.LC_CODE_SIGNATURE {
                codeSigCmdOffset = cursor
                codeSigDataOff = swap ? workingData.readUInt32(at: cursor + 8).byteSwapped : workingData.readUInt32(at: cursor + 8)
                codeSigDataSize = swap ? workingData.readUInt32(at: cursor + 12).byteSwapped : workingData.readUInt32(at: cursor + 12)
            }




            cursor += Int(cmdsize)
        }

        // Calculate Code Limit (where signature payload starts)
        var codeLimit = workingData.count
        if let _ = codeSigCmdOffset, codeSigDataOff > 0 {
            codeLimit = Int(codeSigDataOff)
        } else if let _ = linkeditCmdOffset {
            codeLimit = Int(linkeditFileOff + linkeditFileSize)
        }

        // 16-byte align codeLimit
        let alignRem = codeLimit % 16
        if alignRem != 0 {
            codeLimit += (16 - alignRem)
        }


        // Slot 2: Requirements
        // Compile Designated Requirements
        let reqBlob = RequirementsCompiler.compileDesignatedRequirement(
            bundleIdentifier: bundleIdentifier,
            teamIdentifier: teamIdentifier
        )


        // Slot 5: XML Entitlements
        var xmlBlob: Data? = nil
        if let entitlementsXML, let xmlData = entitlementsXML.data(using: .utf8), !xmlData.isEmpty {
            let totalEntSize = 8 + xmlData.count
            var blob = Data(count: totalEntSize)
            blob.writeUInt32BigEndian(CodeSigningConstants.CSMAGIC_ENTITLEMENTS, at: 0)
            blob.writeUInt32BigEndian(UInt32(totalEntSize), at: 4)
            blob.replaceSubrange(8..<totalEntSize, with: xmlData)
            xmlBlob = blob
        }

        // Slot 7: DER Entitlements
        var derBlob: Data? = nil
        if let entitlementsXML, let derData = DEREncoder.encodePlistXML(entitlementsXML), !derData.isEmpty {
            let totalDerSize = 8 + derData.count
            var blob = Data(count: totalDerSize)
            blob.writeUInt32BigEndian(CodeSigningConstants.CSMAGIC_DER_ENTITLEMENTS, at: 0)
            blob.writeUInt32BigEndian(UInt32(totalDerSize), at: 4)
            blob.replaceSubrange(8..<totalDerSize, with: derData)
            derBlob = blob
        }

        var cdFlags = options.rawValue
        if cmsSigner == nil {
            cdFlags |= CodeSigningConstants.CS_ADHOC
        }

        // Pass 1: Precalculate exact SuperBlob size & update Mach-O headers
        let dummyCD = CodeDirectoryBuilder(
            binaryData: Data(count: codeLimit),
            codeLimit: codeLimit,
            bundleIdentifier: bundleIdentifier,
            teamIdentifier: teamIdentifier,
            flags: cdFlags,
            hashType: CodeSigningConstants.CS_HASHTYPE_SHA256,
            pageSizeShift: pageSizeShift,
            execSegBase: textFileOff,
            execSegLimit: textFileSize,
            execSegFlags: isExecutable ? (CodeSigningConstants.CS_EXECSEG_MAIN_BINARY | CodeSigningConstants.CS_EXECSEG_ALLOW_UNSIGNED) : 0
        )

        if let infoPlistData { dummyCD.setSpecialSlot(CodeSigningConstants.CSSLOT_INFOSLOT, data: infoPlistData) }
        dummyCD.setSpecialSlot(CodeSigningConstants.CSSLOT_REQUIREMENTS, data: reqBlob)
        if let codeResourcesData { dummyCD.setSpecialSlot(CodeSigningConstants.CSSLOT_RESOURCEDIR, data: codeResourcesData) }
        if let xmlBlob { dummyCD.setSpecialSlot(CodeSigningConstants.CSSLOT_ENTITLEMENTS, data: xmlBlob) }
        if let derBlob { dummyCD.setSpecialSlot(CodeSigningConstants.CSSLOT_DER_ENTITLEMENTS, data: derBlob) }
        let dummyCDData = dummyCD.build()


        let dummySignature = try cmsSigner?.sign(codeDirectoryData: dummyCDData)

        let preSuperBlob = SuperBlobBuilder()
        preSuperBlob.addBlob(type: CodeSigningConstants.CSSLOT_CODEDIRECTORY, data: dummyCDData)
        preSuperBlob.addBlob(type: CodeSigningConstants.CSSLOT_REQUIREMENTS, data: reqBlob)
        if let xmlBlob { preSuperBlob.addBlob(type: CodeSigningConstants.CSSLOT_ENTITLEMENTS, data: xmlBlob) }
        if let derBlob { preSuperBlob.addBlob(type: CodeSigningConstants.CSSLOT_DER_ENTITLEMENTS, data: derBlob) }

        if let dummySignature {
            preSuperBlob.addBlob(type: CodeSigningConstants.CSSLOT_SIGNATURESLOT, data: dummySignature)
        }

        let preSuperBlobData = preSuperBlob.build()
        let superBlobPad = (16 - (preSuperBlobData.count % 16)) % 16
        let finalSuperBlobSize = UInt32(preSuperBlobData.count + superBlobPad)

        // Sliced binary
        var finalBinary = workingData.subdata(in: 0..<min(codeLimit, workingData.count))
        if finalBinary.count < codeLimit {
            finalBinary.append(Data(repeating: 0, count: codeLimit - finalBinary.count))
        }

        let newSignatureOff = UInt32(codeLimit)
        let newSignatureSize = finalSuperBlobSize

        // Update __LINKEDIT in finalBinary (Page 0)
        if let linkeditOff = linkeditCmdOffset {
            let newLinkeditFileSize = (UInt64(codeLimit) - linkeditFileOff) + UInt64(newSignatureSize)
            let newLinkeditVmSize = ((newLinkeditFileSize + 4095) / 4096) * 4096

            if is64 {
                finalBinary.writeUInt64(swap ? newLinkeditVmSize.byteSwapped : newLinkeditVmSize, at: linkeditOff + 32)
                finalBinary.writeUInt64(swap ? newLinkeditFileSize.byteSwapped : newLinkeditFileSize, at: linkeditOff + 48)
            } else {
                finalBinary.writeUInt32(swap ? UInt32(newLinkeditVmSize).byteSwapped : UInt32(newLinkeditVmSize), at: linkeditOff + 28)
                finalBinary.writeUInt32(swap ? UInt32(newLinkeditFileSize).byteSwapped : UInt32(newLinkeditFileSize), at: linkeditOff + 36)
            }
        }

        // Update or Insert LC_CODE_SIGNATURE command in finalBinary (Page 0)
        if let sigCmdOff = codeSigCmdOffset {
            finalBinary.writeUInt32(swap ? newSignatureOff.byteSwapped : newSignatureOff, at: sigCmdOff + 8)
            finalBinary.writeUInt32(swap ? newSignatureSize.byteSwapped : newSignatureSize, at: sigCmdOff + 12)
        } else {
            let newCmdSize: UInt32 = 16
            var newCmdData = Data(count: 16)
            newCmdData.writeUInt32(swap ? CodeSigningConstants.LC_CODE_SIGNATURE.byteSwapped : CodeSigningConstants.LC_CODE_SIGNATURE, at: 0)
            newCmdData.writeUInt32(swap ? newCmdSize.byteSwapped : newCmdSize, at: 4)
            newCmdData.writeUInt32(swap ? newSignatureOff.byteSwapped : newSignatureOff, at: 8)
            newCmdData.writeUInt32(swap ? newSignatureSize.byteSwapped : newSignatureSize, at: 12)

            let insertPos = headerSize + Int(sizeofcmds)
            if insertPos + 16 <= finalBinary.count {
                finalBinary.replaceSubrange(insertPos..<insertPos + 16, with: newCmdData)
                let newNcmds = ncmds + 1
                let newSizeofcmds = sizeofcmds + newCmdSize
                finalBinary.writeUInt32(swap ? newNcmds.byteSwapped : newNcmds, at: 16)
                finalBinary.writeUInt32(swap ? newSizeofcmds.byteSwapped : newSizeofcmds, at: 20)
            }
        }

        //Pass 2: Hash the updated finalBinary (with exact Page 0 load commands!)
        let realCD = CodeDirectoryBuilder(
            binaryData: finalBinary,
            codeLimit: codeLimit,
            bundleIdentifier: bundleIdentifier,
            teamIdentifier: teamIdentifier,
            flags: cdFlags,
            hashType: CodeSigningConstants.CS_HASHTYPE_SHA256,
            pageSizeShift: pageSizeShift,
            execSegBase: textFileOff,
            execSegLimit: textFileSize,
            execSegFlags: isExecutable ? (CodeSigningConstants.CS_EXECSEG_MAIN_BINARY | CodeSigningConstants.CS_EXECSEG_ALLOW_UNSIGNED) : 0
        )

        if let infoPlistData { realCD.setSpecialSlot(CodeSigningConstants.CSSLOT_INFOSLOT, data: infoPlistData) }
        realCD.setSpecialSlot(CodeSigningConstants.CSSLOT_REQUIREMENTS, data: reqBlob)
        if let codeResourcesData { realCD.setSpecialSlot(CodeSigningConstants.CSSLOT_RESOURCEDIR, data: codeResourcesData) }
        if let xmlBlob { realCD.setSpecialSlot(CodeSigningConstants.CSSLOT_ENTITLEMENTS, data: xmlBlob) }
        if let derBlob { realCD.setSpecialSlot(CodeSigningConstants.CSSLOT_DER_ENTITLEMENTS, data: derBlob) }
        let realCDData = realCD.build()


        let realSuperBlob = SuperBlobBuilder()
        realSuperBlob.addBlob(type: CodeSigningConstants.CSSLOT_CODEDIRECTORY, data: realCDData)
        realSuperBlob.addBlob(type: CodeSigningConstants.CSSLOT_REQUIREMENTS, data: reqBlob)
        if let xmlBlob { realSuperBlob.addBlob(type: CodeSigningConstants.CSSLOT_ENTITLEMENTS, data: xmlBlob) }
        if let derBlob { realSuperBlob.addBlob(type: CodeSigningConstants.CSSLOT_DER_ENTITLEMENTS, data: derBlob) }


        if let cmsSigner {
            let realSignature = try cmsSigner.sign(codeDirectoryData: realCDData)
            realSuperBlob.addBlob(type: CodeSigningConstants.CSSLOT_SIGNATURESLOT, data: realSignature)
        }

        var realSuperBlobData = realSuperBlob.build()
        let pad = (16 - (realSuperBlobData.count % 16)) % 16
        if pad > 0 {
            realSuperBlobData.append(Data(repeating: 0, count: pad))
        }

        finalBinary.append(realSuperBlobData)
        return finalBinary
    }

    public static func removeSignature(binaryData: Data) throws -> Data {
        guard binaryData.count >= 4 else {
            throw CodeSignerError.invalidMachO("Binary too short")
        }

        let magic = binaryData.readUInt32(at: 0)

        // Check if FAT binary
        if magic == CodeSigningConstants.FAT_MAGIC || magic == CodeSigningConstants.FAT_CIGAM ||
           magic == CodeSigningConstants.FAT_MAGIC_64 || magic == CodeSigningConstants.FAT_CIGAM_64 {
            return try removeSignatureFatBinary(binaryData: binaryData)
        } else if magic == CodeSigningConstants.MH_MAGIC_64 || magic == CodeSigningConstants.MH_CIGAM_64 ||
                  magic == CodeSigningConstants.MH_MAGIC || magic == CodeSigningConstants.MH_CIGAM {
            return try removeSignatureThinBinary(sliceData: binaryData)
        } else {
            throw CodeSignerError.invalidMachO("Unrecognized Mach-O magic: \(String(format: "0x%08X", magic))")
        }
    }

    private static func removeSignatureThinBinary(sliceData: Data) throws -> Data {
        guard sliceData.count >= 32 else {
            throw CodeSignerError.invalidMachO("Thin binary slice too short")
        }

        let magic = sliceData.readUInt32(at: 0)
        let swap = (magic == CodeSigningConstants.MH_CIGAM || magic == CodeSigningConstants.MH_CIGAM_64)
        let is64 = (magic == CodeSigningConstants.MH_MAGIC_64 || magic == CodeSigningConstants.MH_CIGAM_64)

        let headerSize = is64 ? 32 : 28
        guard sliceData.count >= headerSize else {
            throw CodeSignerError.invalidMachO("Header too small")
        }

        var ncmds = swap ? sliceData.readUInt32(at: 16).byteSwapped : sliceData.readUInt32(at: 16)
        var sizeofcmds = swap ? sliceData.readUInt32(at: 20).byteSwapped : sliceData.readUInt32(at: 20)

        var offset = headerSize
        var sigCmdOffset: Int? = nil
        var sigCmdSize: Int = 0
        var sigDataOffset: Int = sliceData.count

        for _ in 0..<Int(ncmds) {
            guard offset + 8 <= sliceData.count else { break }
            let cmd = swap ? sliceData.readUInt32(at: offset).byteSwapped : sliceData.readUInt32(at: offset)
            let cmdsize = Int(swap ? sliceData.readUInt32(at: offset + 4).byteSwapped : sliceData.readUInt32(at: offset + 4))

            guard cmdsize > 0 && offset + cmdsize <= sliceData.count else { break }

            if cmd == CodeSigningConstants.LC_CODE_SIGNATURE {
                sigCmdOffset = offset
                sigCmdSize = cmdsize
                if offset + 16 <= sliceData.count {
                    let dataoff = Int(swap ? sliceData.readUInt32(at: offset + 8).byteSwapped : sliceData.readUInt32(at: offset + 8))
                    sigDataOffset = dataoff
                }
                break
            }

            offset += cmdsize
        }

        guard let cmdOffset = sigCmdOffset else {
            // No signature found, return original slice
            return sliceData
        }

        var modifiedSlice = sliceData

        // 1. Truncate binary data to sigDataOffset if signature is at end of binary
        if sigDataOffset < modifiedSlice.count {
            modifiedSlice = modifiedSlice.prefix(sigDataOffset)
        }

        // 2. Remove the LC_CODE_SIGNATURE command from load commands
        let loadCommandsEnd = headerSize + Int(sizeofcmds)
        let subsequentCmdsOffset = cmdOffset + sigCmdSize
        if subsequentCmdsOffset < loadCommandsEnd {
            let trailingCmds = modifiedSlice.subdata(in: subsequentCmdsOffset..<loadCommandsEnd)
            modifiedSlice.replaceSubrange(cmdOffset..<cmdOffset + trailingCmds.count, with: trailingCmds)
        }
        // Zero out the removed cmd space at end of load commands table
        let zeroPadding = Data(repeating: 0, count: sigCmdSize)
        modifiedSlice.replaceSubrange((loadCommandsEnd - sigCmdSize)..<loadCommandsEnd, with: zeroPadding)

        // 3. Update header ncmds and sizeofcmds
        ncmds -= 1
        sizeofcmds -= UInt32(sigCmdSize)
        let finalNcmds = swap ? ncmds.byteSwapped : ncmds
        let finalSizeofcmds = swap ? sizeofcmds.byteSwapped : sizeofcmds
        modifiedSlice.writeUInt32(finalNcmds, at: 16)
        modifiedSlice.writeUInt32(finalSizeofcmds, at: 20)

        return modifiedSlice
    }

    private static func removeSignatureFatBinary(binaryData: Data) throws -> Data {
        let is64 = (binaryData.readUInt32(at: 0) == CodeSigningConstants.FAT_MAGIC_64 ||
                    binaryData.readUInt32(at: 0) == CodeSigningConstants.FAT_CIGAM_64)
        let swap = (binaryData.readUInt32(at: 0) == CodeSigningConstants.FAT_CIGAM ||
                    binaryData.readUInt32(at: 0) == CodeSigningConstants.FAT_CIGAM_64)

        let nfatArch = Int(swap ? binaryData.readUInt32(at: 4).byteSwapped : binaryData.readUInt32(at: 4))
        let archHeaderSize = is64 ? 32 : 20
        var headerOffset = 8

        struct ArchInfo {
            var cputype: UInt32
            var cpusubtype: UInt32
            var alignPower: UInt32
            var unsignedData: Data
        }

        var archs: [ArchInfo] = []

        for _ in 0..<nfatArch {
            guard headerOffset + archHeaderSize <= binaryData.count else {
                throw CodeSignerError.invalidMachO("Truncated FAT header")
            }

            let cputype = swap ? binaryData.readUInt32(at: headerOffset).byteSwapped : binaryData.readUInt32(at: headerOffset)
            let cpusubtype = swap ? binaryData.readUInt32(at: headerOffset + 4).byteSwapped : binaryData.readUInt32(at: headerOffset + 4)
            let offset = Int(swap ? binaryData.readUInt32(at: headerOffset + 8).byteSwapped : binaryData.readUInt32(at: headerOffset + 8))
            let size = Int(swap ? binaryData.readUInt32(at: headerOffset + 12).byteSwapped : binaryData.readUInt32(at: headerOffset + 12))
            let align = swap ? binaryData.readUInt32(at: headerOffset + 16).byteSwapped : binaryData.readUInt32(at: headerOffset + 16)

            guard offset + size <= binaryData.count else {
                throw CodeSignerError.invalidMachO("Invalid slice offset in FAT binary")
            }

            let sliceData = binaryData.subdata(in: offset..<offset + size)
            let unsignedSlice = try removeSignatureThinBinary(sliceData: sliceData)

            archs.append(ArchInfo(
                cputype: cputype,
                cpusubtype: cpusubtype,
                alignPower: align,
                unsignedData: unsignedSlice
            ))

            headerOffset += archHeaderSize
        }

        var finalBinary = Data(count: 8 + nfatArch * archHeaderSize)
        finalBinary.writeUInt32BigEndian(is64 ? CodeSigningConstants.FAT_MAGIC_64 : CodeSigningConstants.FAT_MAGIC, at: 0)
        finalBinary.writeUInt32BigEndian(UInt32(nfatArch), at: 4)

        var currentOffset = finalBinary.count
        var archHeaderWriteOffset = 8

        for arch in archs {
            let alignment = 1 << Int(arch.alignPower)
            let remainder = currentOffset % alignment
            if remainder != 0 {
                let pad = alignment - remainder
                finalBinary.append(Data(repeating: 0, count: pad))
                currentOffset += pad
            }

            let sliceOffset = currentOffset
            let sliceSize = arch.unsignedData.count

            finalBinary.writeUInt32BigEndian(arch.cputype, at: archHeaderWriteOffset)
            finalBinary.writeUInt32BigEndian(arch.cpusubtype, at: archHeaderWriteOffset + 4)
            finalBinary.writeUInt32BigEndian(UInt32(sliceOffset), at: archHeaderWriteOffset + 8)
            finalBinary.writeUInt32BigEndian(UInt32(sliceSize), at: archHeaderWriteOffset + 12)
            finalBinary.writeUInt32BigEndian(arch.alignPower, at: archHeaderWriteOffset + 16)

            archHeaderWriteOffset += archHeaderSize
            finalBinary.append(arch.unsignedData)
            currentOffset += sliceSize
        }

        return finalBinary
    }
}
