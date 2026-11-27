//
//  TimestampAuthorityClient.swift
//  CodeSignKit
//
//  Created by Magesh K on 03/09/26.
//  Copyright © 2026 CodeSignKit. All rights reserved.
//

import Foundation
import Crypto
#if !canImport(Darwin)
import FoundationNetworking

extension URLSession {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = self.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data, let response = response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: URLError(.unknown))
                }
            }
            task.resume()
        }
    }
}
#endif

public final class TimestampAuthorityClient: @unchecked Sendable {

    public static let defaultAppleTSA = URL(string: "http://timestamp.apple.com/ts01")!
    public static let defaultDigiCertTSA = URL(string: "http://timestamp.digicert.com")!

    // RFC 3161 OID for SHA-256 (2.16.840.1.101.3.4.2.1)
    private static let oidSHA256 = ASN1Helper.encodeOID("2.16.840.1.101.3.4.2.1")

    // id-aa-timeStampToken OID: 1.2.840.113549.1.9.16.2.14
    public static let oidTimeStampToken = ASN1Helper.encodeOID("1.2.840.113549.1.9.16.2.14")

    public init() {}

    // Builds a DER-encoded TimeStampReq for the given digest
    public static func createRequestData(forDigest digest: Data) -> Data {
        // 1. Version 1 (INTEGER 1)
        let versionDER = ASN1Helper.integer(1)

        // 2. AlgorithmIdentifier (SHA-256 + NULL)
        let algoDER = ASN1Helper.algorithmIdentifier(oidData: oidSHA256, hasNullParam: true)

        // 3. HashedMessage (OCTET STRING)
        let hashOctetDER = ASN1Helper.octetString(digest)

        // 4. MessageImprint (SEQUENCE of AlgorithmIdentifier + OctetString)
        let messageImprintDER = ASN1Helper.sequence(algoDER + hashOctetDER)

        // 5. certReq (BOOLEAN true)
        let certReqDER = Data([0x01, 0x01, 0xff])

        // 6. TimeStampReq SEQUENCE
        return ASN1Helper.sequence(versionDER + messageImprintDER + certReqDER)
    }

    // Fetches timestamp token asynchronously from TSA URL
    public func fetchTimestampToken(
        forDigest digest: Data,
        serverURL: URL = defaultAppleTSA,
        timeout: TimeInterval = 10
    ) async throws -> Data {
        let reqData = Self.createRequestData(forDigest: digest)

        var request = URLRequest(url: serverURL, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/timestamp-query", forHTTPHeaderField: "Content-Type")
        request.setValue("application/timestamp-reply", forHTTPHeaderField: "Accept")
        request.httpBody = reqData

        let (responseData, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw CodeSignerError.signingFailed("TSA returned HTTP status \(httpResponse.statusCode)")
        }

        guard !responseData.isEmpty else {
            throw CodeSignerError.signingFailed("Empty timestamp response from \(serverURL)")
        }

        return try Self.extractTimeStampToken(from: responseData)
    }

    // Parses TimeStampResp ASN.1 sequence and returns the signed timeStampToken
    public static func extractTimeStampToken(from responseData: Data) throws -> Data {
        let children = ASN1Helper.parseSequenceChildren(from: responseData)
        guard children.count >= 2 else {
            throw CodeSignerError.signingFailed("Invalid TimeStampResp structure")
        }

        // Child 0 is PKIStatusInfo, Child 1 is ContentInfo (timeStampToken)
        let statusInfo = children[0]
        let statusChildren = ASN1Helper.parseSequenceChildren(from: statusInfo.value)
        if let statusInteger = statusChildren.first {
            let statusVal = statusInteger.value.first ?? 0
            guard statusVal == 0 || statusVal == 1 else {
                throw CodeSignerError.signingFailed("TSA returned non-zero PKIStatus: \(statusVal)")
            }
        }

        let timeStampToken = children[1]
        return timeStampToken.rawDER
    }
}
