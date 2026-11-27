//
//  SuperBlobBuilder.swift
//  CodeSignKit
//
//  Created by Magesh K on 28/08/26.
//  Copyright © 2026 CodeSignKit. All rights reserved.
//


import Foundation

public final class SuperBlobBuilder {

    private var blobs: [(type: UInt32, data: Data)] = []

    public init() {}

    public func addBlob(type: UInt32, data: Data) {
        blobs.append((type: type, data: data))
    }

    public func addEntitlementsBlob(xml: String) {
        guard let xmlData = xml.data(using: .utf8), !xmlData.isEmpty else { return }
        let totalSize = 8 + xmlData.count
        var blob = Data(count: totalSize)
        blob.writeUInt32BigEndian(CodeSigningConstants.CSMAGIC_ENTITLEMENTS, at: 0)
        blob.writeUInt32BigEndian(UInt32(totalSize), at: 4)
        blob.replaceSubrange(8..<totalSize, with: xmlData)
        addBlob(type: CodeSigningConstants.CSSLOT_ENTITLEMENTS, data: blob)
    }

    public func addDEREntitlementsBlob(derData: Data) {
        guard !derData.isEmpty else { return }
        let totalSize = 8 + derData.count
        var blob = Data(count: totalSize)
        blob.writeUInt32BigEndian(CodeSigningConstants.CSMAGIC_DER_ENTITLEMENTS, at: 0)
        blob.writeUInt32BigEndian(UInt32(totalSize), at: 4)
        blob.replaceSubrange(8..<totalSize, with: derData)
        addBlob(type: CodeSigningConstants.CSSLOT_DER_ENTITLEMENTS, data: blob)
    }


    public func addEmptyRequirementsBlob() {
        var blob = Data(count: 12)
        blob.writeUInt32BigEndian(CodeSigningConstants.CSMAGIC_REQUIREMENTS, at: 0)
        blob.writeUInt32BigEndian(12, at: 4)
        blob.writeUInt32BigEndian(0, at: 8) // count = 0
        addBlob(type: CodeSigningConstants.CSSLOT_REQUIREMENTS, data: blob)
    }

    public func addRequirementsBlob(identifier: String, commonName: String) {

        // Standard Apple requirement blob
        var reqPayload = Data()
        reqPayload.appendUInt32BigEndian(1) // opExpr
        reqPayload.appendUInt32BigEndian(0) // opAnd
        reqPayload.appendUInt32BigEndian(2) // opIdent
        let identBytes = identifier.data(using: .utf8) ?? Data()
        reqPayload.appendUInt32BigEndian(UInt32(identBytes.count))
        reqPayload.append(identBytes)
        let pad = (4 - (identBytes.count % 4)) % 4
        reqPayload.append(Data(repeating: 0, count: pad))

        let totalReqSize = 8 + reqPayload.count
        var requirementBlob = Data(count: totalReqSize)
        requirementBlob.writeUInt32BigEndian(CodeSigningConstants.CSMAGIC_REQUIREMENT, at: 0)
        requirementBlob.writeUInt32BigEndian(UInt32(totalReqSize), at: 4)
        requirementBlob.replaceSubrange(8..<totalReqSize, with: reqPayload)

        // Wrap in Requirements blob (CSMAGIC_REQUIREMENTS = 0xfade7171)
        let totalGroupSize = 12 + requirementBlob.count + 8
        var requirementsBlob = Data(count: totalGroupSize)
        requirementsBlob.writeUInt32BigEndian(CodeSigningConstants.CSMAGIC_REQUIREMENTS, at: 0)
        requirementsBlob.writeUInt32BigEndian(UInt32(totalGroupSize), at: 4)
        requirementsBlob.writeUInt32BigEndian(1, at: 8) // count = 1
        // Index entry: type 3 (host/guest requirement), offset 20
        requirementsBlob.writeUInt32BigEndian(3, at: 12)
        requirementsBlob.writeUInt32BigEndian(20, at: 16)
        requirementsBlob.replaceSubrange(20..<20 + requirementBlob.count, with: requirementBlob)

        addBlob(type: CodeSigningConstants.CSSLOT_REQUIREMENTS, data: requirementsBlob)
    }

    public func build() -> Data {
        let count = blobs.count
        let headerSize = 12 + (count * 8)

        var totalSize = headerSize
        var offsets: [Int] = []

        for blob in blobs {
            offsets.append(totalSize)
            totalSize += blob.data.count
        }

        var superBlob = Data(count: totalSize)
        superBlob.writeUInt32BigEndian(CodeSigningConstants.CSMAGIC_EMBEDDED_SIGNATURE, at: 0)
        superBlob.writeUInt32BigEndian(UInt32(totalSize), at: 4)
        superBlob.writeUInt32BigEndian(UInt32(count), at: 8)

        for i in 0..<count {
            let indexOffset = 12 + (i * 8)
            superBlob.writeUInt32BigEndian(blobs[i].type, at: indexOffset)
            superBlob.writeUInt32BigEndian(UInt32(offsets[i]), at: indexOffset + 4)
            superBlob.replaceSubrange(offsets[i]..<offsets[i] + blobs[i].data.count, with: blobs[i].data)
        }

        return superBlob
    }
}

