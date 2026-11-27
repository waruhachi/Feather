//
//  CSRBuilder.swift
//  CodeSignKit
//
//  Created by Magesh K on 28/08/26.
//  Copyright © 2026 CodeSignKit. All rights reserved.
//

import Foundation
import Crypto
import _CryptoExtras

public struct CSRSubject: Sendable {
    public let country: String
    public let state: String
    public let locality: String
    public let organization: String
    public let commonName: String

    public init(
        country: String = "US",
        state: String = "CA",
        locality: String = "Los Angeles",
        organization: String = "CodeSignKit",
        commonName: String = "CodeSignKit"
    ) {
        self.country = country
        self.state = state
        self.locality = locality
        self.organization = organization
        self.commonName = commonName
    }
}

public enum CSRBuilder {

    public static func generate(
        subject: CSRSubject
    ) throws -> (csrPEM: String, privateKeyPEM: String, csrDER: Data, privateKeyDER: Data) {
        let privateKey = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let pkcs1PrivKeyDER = privateKey.derRepresentation
        let pubKeyDER = privateKey.publicKey.derRepresentation

        // Subject DN
        let cSeq = ASN1Helper.sequence(ASN1Helper.encodeOID("2.5.4.6") + ASN1Helper.encodeTLV(tag: 0x13, value: Data(subject.country.utf8)))
        let cSet = ASN1Helper.set(cSeq)

        let stSeq = ASN1Helper.sequence(ASN1Helper.encodeOID("2.5.4.8") + ASN1Helper.encodeTLV(tag: 0x0C, value: Data(subject.state.utf8)))
        let stSet = ASN1Helper.set(stSeq)

        let lSeq = ASN1Helper.sequence(ASN1Helper.encodeOID("2.5.4.7") + ASN1Helper.encodeTLV(tag: 0x0C, value: Data(subject.locality.utf8)))
        let lSet = ASN1Helper.set(lSeq)

        let oSeq = ASN1Helper.sequence(ASN1Helper.encodeOID("2.5.4.10") + ASN1Helper.encodeTLV(tag: 0x0C, value: Data(subject.organization.utf8)))
        let oSet = ASN1Helper.set(oSeq)

        let cnSeq = ASN1Helper.sequence(ASN1Helper.encodeOID("2.5.4.3") + ASN1Helper.encodeTLV(tag: 0x0C, value: Data(subject.commonName.utf8)))
        let cnSet = ASN1Helper.set(cnSeq)

        let subjectDER = ASN1Helper.sequence(cSet + stSet + lSet + oSet + cnSet)
        let attributes = ASN1Helper.contextual(0, content: Data(), constructed: true)

        let cri = ASN1Helper.sequence(
            ASN1Helper.integer(0) +
            subjectDER +
            pubKeyDER +
            attributes
        )

        let digest = SHA256.hash(data: cri)
        let signature = try privateKey.signature(for: digest, padding: .insecurePKCS1v1_5)
        let sigBits = ASN1Helper.bitString(signature.rawRepresentation)
        let sigAlg = ASN1Helper.algorithmIdentifier(oidData: ASN1Helper.oidSha256WithRSAEncryption, hasNullParam: true)

        let csrDER = ASN1Helper.sequence(cri + sigAlg + sigBits)

        let csrPEM = "-----BEGIN CERTIFICATE REQUEST-----\n" +
            csrDER.base64EncodedString(options: .lineLength64Characters) +
            "\n-----END CERTIFICATE REQUEST-----\n"

        let privKeyPEM = "-----BEGIN RSA PRIVATE KEY-----\n" +
            pkcs1PrivKeyDER.base64EncodedString(options: .lineLength64Characters) +
            "\n-----END RSA PRIVATE KEY-----\n"

        return (csrPEM, privKeyPEM, csrDER, pkcs1PrivKeyDER)
    }
}
