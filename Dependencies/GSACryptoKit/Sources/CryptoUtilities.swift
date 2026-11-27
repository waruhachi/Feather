//
//  CryptoUtilities.swift
//  GSACryptoKit
//
//  Created by Magesh K on 28/08/26.
//  Copyright © 2026 GSACryptoKit. All rights reserved.
//

import Foundation
import Crypto
import _CryptoExtras

public enum CryptoUtilities {

    public typealias SRP = SRPClient

    /// Computes HMAC-SHA256 over the concatenated UTF-8 encodings of `strings`
    public static func hmacSHA256(key: Data, strings: [String]) -> Data? {
        var concatenated = Data()
        for s in strings {
            concatenated.append(Data(s.utf8))
        }
        let symmetricKey = SymmetricKey(data: key)
        let authenticationCode = HMAC<SHA256>.authenticationCode(for: concatenated, using: symmetricKey)
        return Data(authenticationCode)
    }

    /// Returns the SHA-256 digest of `data`
    public static func sha256(_ data: Data) -> Data? {
        let digest = SHA256.hash(data: data)
        return Data(digest)
    }

    /// Derives a key from a password using PBKDF2-HMAC-SHA256
    public static func pbkdf2SHA256(
        password: Data,
        salt: Data,
        rounds: Int,
        outputLength: Int
    ) -> Data? {
        guard rounds > 0, outputLength > 0 else { return nil }
        let hLen = 32
        let l = Int(ceil(Double(outputLength) / Double(hLen)))
        let symmetricKey = SymmetricKey(data: password)
        var derivedKey = Data()
        derivedKey.reserveCapacity(l * hLen)

        for i in 1...l {
            var blockIndexBE = Data(count: 4)
            blockIndexBE[0] = UInt8((i >> 24) & 0xFF)
            blockIndexBE[1] = UInt8((i >> 16) & 0xFF)
            blockIndexBE[2] = UInt8((i >> 8) & 0xFF)
            blockIndexBE[3] = UInt8(i & 0xFF)

            var u = Data(HMAC<SHA256>.authenticationCode(for: salt + blockIndexBE, using: symmetricKey))
            var t = u

            for _ in 1..<rounds {
                u = Data(HMAC<SHA256>.authenticationCode(for: u, using: symmetricKey))
                for j in 0..<hLen {
                    t[j] ^= u[j]
                }
            }
            derivedKey.append(t)
        }

        return derivedKey.prefix(outputLength)
    }

    /// Decrypts AES-CBC encrypted `ciphertext` with PKCS#7 unpadding using `key` and `iv`
    public static func aesCBCDecrypt(key: Data, iv: Data, ciphertext: Data) -> Data? {
        guard iv.count >= 16 else { return nil }
        guard key.count == 16 || key.count == 24 || key.count == 32 else { return nil }
        guard !ciphertext.isEmpty, ciphertext.count % 16 == 0 else { return nil }

        do {
            let symmetricKey = SymmetricKey(data: key)
            let ivObj = try AES._CBC.IV(ivBytes: iv.prefix(16))
            return try AES._CBC.decrypt(ciphertext, using: symmetricKey, iv: ivObj, noPadding: false)
        } catch {
            return nil
        }
    }

    /// Decrypts `ciphertext` with AES-GCM using the given `key`, `nonce`, `aad`, and authentication `tag`
    public static func aesGCMDecrypt(
        key: Data,
        nonce: Data,
        aad: Data,
        ciphertext: Data,
        tag: Data
    ) -> Data? {
        guard key.count == 16 || key.count == 24 || key.count == 32 else { return nil }
        guard let gcmNonce = try? AES.GCM.Nonce(data: nonce) else { return nil }
        guard tag.count == 16 else { return nil }
        do {
            let sealedBox = try AES.GCM.SealedBox(nonce: gcmNonce, ciphertext: ciphertext, tag: tag)
            let symmetricKey = SymmetricKey(data: key)
            if aad.isEmpty {
                return try AES.GCM.open(sealedBox, using: symmetricKey)
            } else {
                return try AES.GCM.open(sealedBox, using: symmetricKey, authenticating: aad)
            }
        } catch {
            return nil
        }
    }
}
