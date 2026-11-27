//
//  RequirementsBuilder.swift
//  CodeSignKit
//
//  Created by Magesh K on 28/08/26.
//  Copyright © 2026 CodeSignKit. All rights reserved.
//

import Foundation
import Crypto

public struct RequirementsBuilder {
    private static let opIdent: UInt32 = 2

    public static func buildDesignatedRequirement(bundleIdentifier: String, certSHA1: Data? = nil) -> Data {
        var exprData = Data()

        var identBytes = bundleIdentifier.data(using: .utf8) ?? Data()
        let identLen = UInt32(identBytes.count)
        let pad = (4 - (identBytes.count % 4)) % 4
        if pad > 0 {
            identBytes.append(Data(repeating: 0, count: pad))
        }

        // designated => identifier "<bundleID>"
        exprData.writeUInt32BigEndian(opIdent)
        exprData.writeUInt32BigEndian(identLen)
        exprData.append(identBytes)

        // Single requirement expr blob: header (12 bytes) + exprData
        let exprBlobSize = 12 + exprData.count
        var exprBlob = Data(count: exprBlobSize)
        exprBlob.writeUInt32BigEndian(CodeSigningConstants.CSMAGIC_REQUIREMENT, at: 0)
        exprBlob.writeUInt32BigEndian(UInt32(exprBlobSize), at: 4)
        exprBlob.writeUInt32BigEndian(1 /* exprForm = 1 */, at: 8)
        exprBlob.replaceSubrange(12..<exprBlobSize, with: exprData)

        // Requirements superblob: header (12 bytes) + 1 entry (8 bytes) + exprBlob
        let totalSize = 12 + 8 + exprBlob.count
        var reqSuperBlob = Data(count: totalSize)
        reqSuperBlob.writeUInt32BigEndian(CodeSigningConstants.CSMAGIC_REQUIREMENTS, at: 0)
        reqSuperBlob.writeUInt32BigEndian(UInt32(totalSize), at: 4)
        reqSuperBlob.writeUInt32BigEndian(1 /* count = 1 */, at: 8)

        // Entry 0: type = 3 (kSecDesignatedRequirementType), offset = 20
        reqSuperBlob.writeUInt32BigEndian(3, at: 12)
        reqSuperBlob.writeUInt32BigEndian(20, at: 16)
        reqSuperBlob.replaceSubrange(20..<totalSize, with: exprBlob)

        return reqSuperBlob
    }

    public static func buildEmpty() -> Data {
        var reqBlob = Data(count: 12)
        reqBlob.writeUInt32BigEndian(CodeSigningConstants.CSMAGIC_REQUIREMENTS, at: 0)
        reqBlob.writeUInt32BigEndian(12, at: 4)
        reqBlob.writeUInt32BigEndian(0, at: 8)
        return reqBlob
    }
}
