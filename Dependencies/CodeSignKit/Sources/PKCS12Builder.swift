//
//  PKCS12Builder.swift
//  CodeSignKit
//
//  Created by Magesh K on 28/08/26.
//  Copyright © 2026 CodeSignKit. All rights reserved.
//

import Foundation
import Crypto
import _CryptoExtras

public enum PKCS12Builder {

    public static func build(
        certificateDER: Data,
        privateKeyDER: Data?,
        password: String? = nil
    ) throws -> Data {
        // 1. CertBag: SEQUENCE { certId (1.2.840.113549.1.9.22.1), certValue [0] EXPLICIT OCTET STRING(certDER) }
        let certBagValue = ASN1Helper.sequence(
            ASN1Helper.oidX509Certificate +
            ASN1Helper.contextual(0, content: ASN1Helper.octetString(certificateDER), constructed: true)
        )
        let certSafeBag = ASN1Helper.sequence(
            ASN1Helper.oidCertBag +
            ASN1Helper.contextual(0, content: certBagValue, constructed: true)
        )
        let certSafeBags = ASN1Helper.sequence(certSafeBag)
        let certContentInfo = ASN1Helper.sequence(
            ASN1Helper.oidData +
            ASN1Helper.contextual(0, content: ASN1Helper.octetString(certSafeBags), constructed: true)
        )

        // 2. KeyBag (if privateKeyDER is provided)
        var keyContentInfo = Data()
        if let keyDER = privateKeyDER {
            let pkcs8DER: Data
            if let tlv = ASN1Helper.parseTLV(from: keyDER), tlv.tag == 0x30 {
                let children = ASN1Helper.parseSequenceChildren(from: tlv.value)
                if children.count >= 3 && children[0].tag == 0x02 && children[1].tag == 0x30 {
                    pkcs8DER = keyDER
                } else {
                    pkcs8DER = ASN1Helper.sequence(
                        ASN1Helper.integer(0) +
                        ASN1Helper.algorithmIdentifier(oidData: ASN1Helper.oidRsaEncryption, hasNullParam: true) +
                        ASN1Helper.octetString(keyDER)
                    )
                }
            } else {
                pkcs8DER = ASN1Helper.sequence(
                    ASN1Helper.integer(0) +
                    ASN1Helper.algorithmIdentifier(oidData: ASN1Helper.oidRsaEncryption, hasNullParam: true) +
                    ASN1Helper.octetString(keyDER)
                )
            }

            let keySafeBag = ASN1Helper.sequence(
                ASN1Helper.oidKeyBag +
                ASN1Helper.contextual(0, content: pkcs8DER, constructed: true)
            )
            let keySafeBags = ASN1Helper.sequence(keySafeBag)
            keyContentInfo = ASN1Helper.sequence(
                ASN1Helper.oidData +
                ASN1Helper.contextual(0, content: ASN1Helper.octetString(keySafeBags), constructed: true)
            )
        }

        // 3. AuthenticatedSafe
        let authSafeContent = keyContentInfo + certContentInfo
        let authSafe = ASN1Helper.sequence(authSafeContent)
        let authSafeData = ASN1Helper.sequence(
            ASN1Helper.oidData +
            ASN1Helper.contextual(0, content: ASN1Helper.octetString(authSafe), constructed: true)
        )

        // 4. PFX
        let pfx = ASN1Helper.sequence(
            ASN1Helper.integer(3) +
            authSafeData
        )
        return pfx
    }
}
