//
//  RequirementsCompiler.swift
//  CodeSignKit
//
//  Created by Magesh K on 03/09/26.
//  Copyright © 2026 CodeSignKit. All rights reserved.
//

import Foundation

public enum RequirementOpcode: UInt32 {
    case opFalse              = 0
    case opTrue               = 1
    case opIdent              = 2
    case opAppleAnchor        = 3
    case opAnchorHash         = 4
    case opInfoKeyValue       = 5
    case opAnd                = 6
    case opOr                 = 7
    case opCDHash             = 8
    case opNot                = 9
    case opInfoKeyField       = 10
    case opCertField          = 11
    case opCertGeneric        = 14
    case opAppleGenericAnchor = 15
    case opEntitlementField   = 16
}

public final class RequirementsCompiler {

    // Compiles a standard Apple designated requirement with bundleID and optional teamID
    public static func compileDesignatedRequirement(bundleIdentifier: String, teamIdentifier: String?) -> Data {
        var exprData = Data()

        // 1. opIdent (match bundle ID)
        exprData += encodeStringOp(opcode: .opIdent, string: bundleIdentifier)

        // 2. opAppleGenericAnchor
        var anchorData = Data()
        anchorData.writeUInt32BigEndian(RequirementOpcode.opAppleGenericAnchor.rawValue, at: 0)

        // 3. opCertField for Subject OU / Team ID
        if let teamID = teamIdentifier, !teamID.isEmpty {
            var certFieldData = Data()
            certFieldData.writeUInt32BigEndian(RequirementOpcode.opCertField.rawValue, at: 0)
            // Cert slot 0 (leaf certificate)
            certFieldData.writeUInt32BigEndian(0, at: certFieldData.count)
            // Field name "subject.OU"
            certFieldData += encodeCountedString("subject.OU")
            // Match type 0 (matchEqual)
            certFieldData.writeUInt32BigEndian(0, at: certFieldData.count)
            // Value string
            certFieldData += encodeCountedString(teamID)

            // Combine (opAppleGenericAnchor AND opCertField)
            var anchorAndCert = Data()
            anchorAndCert.writeUInt32BigEndian(RequirementOpcode.opAnd.rawValue, at: 0)
            anchorAndCert += anchorData
            anchorAndCert += certFieldData

            // Combine (opIdent AND (opAppleGenericAnchor AND opCertField))
            var fullExpr = Data()
            fullExpr.writeUInt32BigEndian(RequirementOpcode.opAnd.rawValue, at: 0)
            fullExpr += exprData
            fullExpr += anchorAndCert
            exprData = fullExpr
        } else {
            // Combine (opIdent AND opAppleGenericAnchor)
            var fullExpr = Data()
            fullExpr.writeUInt32BigEndian(RequirementOpcode.opAnd.rawValue, at: 0)
            fullExpr += exprData
            fullExpr += anchorData
            exprData = fullExpr
        }

        // Wrap into CSMAGIC_REQUIREMENT blob
        let totalLen = 12 + exprData.count
        var reqBlob = Data()
        reqBlob.writeUInt32BigEndian(CodeSigningConstants.CSMAGIC_REQUIREMENT, at: 0)
        reqBlob.writeUInt32BigEndian(UInt32(totalLen), at: 4)
        reqBlob.writeUInt32BigEndian(1, at: 8) // kind = 1 (opExpr)
        reqBlob += exprData

        return wrapInRequirementsSet(singleRequirement: reqBlob)
    }

    // Wraps a single requirement into a CSMAGIC_REQUIREMENTS superblob
    public static func wrapInRequirementsSet(singleRequirement: Data) -> Data {
        let count: UInt32 = 1
        let headerSize = 12 + (Int(count) * 8)
        let totalSize = headerSize + singleRequirement.count

        var setBlob = Data()
        setBlob.writeUInt32BigEndian(CodeSigningConstants.CSMAGIC_REQUIREMENTS, at: 0)
        setBlob.writeUInt32BigEndian(UInt32(totalSize), at: 4)
        setBlob.writeUInt32BigEndian(count, at: 8)

        // Type 1 = kSecDesignatedRequirementType
        setBlob.writeUInt32BigEndian(1, at: 12)
        setBlob.writeUInt32BigEndian(UInt32(headerSize), at: 16)
        setBlob += singleRequirement

        return setBlob
    }

    private static func encodeStringOp(opcode: RequirementOpcode, string: String) -> Data {
        var data = Data()
        data.writeUInt32BigEndian(opcode.rawValue, at: 0)
        data += encodeCountedString(string)
        return data
    }

    private static func encodeCountedString(_ string: String) -> Data {
        let strData = string.data(using: .utf8)!
        var data = Data()
        data.writeUInt32BigEndian(UInt32(strData.count), at: 0)
        data += strData
        // 4-byte alignment padding
        let pad = (4 - (strData.count % 4)) % 4
        if pad > 0 {
            data += Data(repeating: 0, count: pad)
        }
        return data
    }
}
