//
//  LegacyCiphers.swift
//  CodeSignKit
//
//  Created by Magesh K on 28/08/26.
//  Copyright © 2026 CodeSignKit. All rights reserved.
//

import Foundation

enum RC2Cipher {

    private static let keyTable: [UInt8] = [
        0xd9, 0x78, 0xf9, 0xc4, 0x19, 0xdd, 0xb5, 0xed, 0x28, 0xe9,
        0xfd, 0x79, 0x4a, 0xa0, 0xd8, 0x9d, 0xc6, 0x7e, 0x37, 0x83,
        0x2b, 0x76, 0x53, 0x8e, 0x62, 0x4c, 0x64, 0x88, 0x44, 0x8b,
        0xfb, 0xa2, 0x17, 0x9a, 0x59, 0xf5, 0x87, 0xb3, 0x4f, 0x13,
        0x61, 0x45, 0x6d, 0x8d, 0x09, 0x81, 0x7d, 0x32, 0xbd, 0x8f,
        0x40, 0xeb, 0x86, 0xb7, 0x7b, 0x0b, 0xf0, 0x95, 0x21, 0x22,
        0x5c, 0x6b, 0x4e, 0x82, 0x54, 0xd6, 0x65, 0x93, 0xce, 0x60,
        0xb2, 0x1c, 0x73, 0x56, 0xc0, 0x14, 0xa7, 0x8c, 0xf1, 0xdc,
        0x12, 0x75, 0xca, 0x1f, 0x3b, 0xbe, 0xe4, 0xd1, 0x42, 0x3d,
        0xd4, 0x30, 0xa3, 0x3c, 0xb6, 0x26, 0x6f, 0xbf, 0x0e, 0xda,
        0x46, 0x69, 0x07, 0x57, 0x27, 0xf2, 0x1d, 0x9b, 0xbc, 0x94,
        0x43, 0x03, 0xf8, 0x11, 0xc7, 0xf6, 0x90, 0xef, 0x3e, 0xe7,
        0x06, 0xc3, 0xd5, 0x2f, 0xc8, 0x66, 0x1e, 0xd7, 0x08, 0xe8,
        0xea, 0xde, 0x80, 0x52, 0xee, 0xf7, 0x84, 0xaa, 0x72, 0xac,
        0x35, 0x4d, 0x6a, 0x2a, 0x96, 0x1a, 0xd2, 0x71, 0x5a, 0x15,
        0x49, 0x74, 0x4b, 0x9f, 0xd0, 0x5e, 0x04, 0x18, 0xa4, 0xec,
        0xc2, 0xe0, 0x41, 0x6e, 0x0f, 0x51, 0xcb, 0xcc, 0x24, 0x91,
        0xaf, 0x50, 0xa1, 0xf4, 0x70, 0x39, 0x99, 0x7c, 0x3a, 0x85,
        0x23, 0xb8, 0xb4, 0x7a, 0xfc, 0x02, 0x36, 0x5b, 0x25, 0x55,
        0x97, 0x31, 0x2d, 0x5d, 0xfa, 0x98, 0xe3, 0x8a, 0x92, 0xae,
        0x05, 0xdf, 0x29, 0x10, 0x67, 0x6c, 0xba, 0xc9, 0xd3, 0x00,
        0xe6, 0xcf, 0xe1, 0x9e, 0xa8, 0x2c, 0x63, 0x16, 0x01, 0x3f,
        0x58, 0xe2, 0x89, 0xa9, 0x0d, 0x38, 0x34, 0x1b, 0xab, 0x33,
        0xff, 0xb0, 0xbb, 0x48, 0x0c, 0x5f, 0xb9, 0xb1, 0xcd, 0x2e,
        0xc5, 0xf3, 0xdb, 0x47, 0xe5, 0xa5, 0x9c, 0x77, 0x0a, 0xa6,
        0x20, 0x68, 0xfe, 0x7f, 0xc1, 0xad
    ]

    static func setKey(key: [UInt8], bits: Int = 40) -> [UInt16] {
        var len = key.count
        if len > 128 { len = 128 }
        var bits = bits
        if bits <= 0 { bits = 1024 }
        if bits > 1024 { bits = 1024 }

        var k = [UInt8](repeating: 0, count: 128)
        for i in 0..<len {
            k[i] = key[i]
        }

        var d: UInt8 = len > 0 ? k[len - 1] : 0
        var j = 0
        for i in len..<128 {
            d = keyTable[(Int(k[j]) + Int(d)) & 0xff]
            k[i] = d
            j += 1
        }

        let jBits = (bits + 7) >> 3
        var i = 128 - jBits
        let c = UInt8(0xff >> (-bits & 0x07))

        d = keyTable[Int(k[i] & c)]
        k[i] = d
        while i > 0 {
            i -= 1
            d = keyTable[Int(k[i + jBits] ^ d)]
            k[i] = d
        }

        var ki = [UInt16](repeating: 0, count: 64)
        for idx in 0..<64 {
            ki[idx] = UInt16(k[idx * 2]) | (UInt16(k[idx * 2 + 1]) << 8)
        }
        return ki
    }

    static func decryptBlock(block: [UInt8], subkeys: [UInt16]) -> [UInt8] {
        let l0 = UInt32(block[0]) | (UInt32(block[1]) << 8) | (UInt32(block[2]) << 16) | (UInt32(block[3]) << 24)
        let l1 = UInt32(block[4]) | (UInt32(block[5]) << 8) | (UInt32(block[6]) << 16) | (UInt32(block[7]) << 24)

        var x0 = UInt16(l0 & 0xffff)
        var x1 = UInt16((l0 >> 16) & 0xffff)
        var x2 = UInt16(l1 & 0xffff)
        var x3 = UInt16((l1 >> 16) & 0xffff)

        var n = 3
        var i = 5
        var p0Idx = 63
        let p1 = subkeys

        while true {
            var t = ((x3 << 11) | (x3 >> 5)) & 0xffff
            x3 = (t &- (x0 & ~x2) &- (x1 & x2) &- subkeys[p0Idx]) & 0xffff
            p0Idx -= 1

            t = ((x2 << 13) | (x2 >> 3)) & 0xffff
            x2 = (t &- (x3 & ~x1) &- (x0 & x1) &- subkeys[p0Idx]) & 0xffff
            p0Idx -= 1

            t = ((x1 << 14) | (x1 >> 2)) & 0xffff
            x1 = (t &- (x2 & ~x0) &- (x3 & x0) &- subkeys[p0Idx]) & 0xffff
            p0Idx -= 1

            t = ((x0 << 15) | (x0 >> 1)) & 0xffff
            x0 = (t &- (x1 & ~x3) &- (x2 & x3) &- subkeys[p0Idx]) & 0xffff
            p0Idx -= 1

            i -= 1
            if i == 0 {
                n -= 1
                if n == 0 {
                    break
                }
                i = (n == 2) ? 6 : 5

                x3 = (x3 &- p1[Int(x2 & 0x3f)]) & 0xffff
                x2 = (x2 &- p1[Int(x1 & 0x3f)]) & 0xffff
                x1 = (x1 &- p1[Int(x0 & 0x3f)]) & 0xffff
                x0 = (x0 &- p1[Int(x3 & 0x3f)]) & 0xffff
            }
        }

        var result = [UInt8](repeating: 0, count: 8)
        result[0] = UInt8(x0 & 0xff)
        result[1] = UInt8((x0 >> 8) & 0xff)
        result[2] = UInt8(x1 & 0xff)
        result[3] = UInt8((x1 >> 8) & 0xff)
        result[4] = UInt8(x2 & 0xff)
        result[5] = UInt8((x2 >> 8) & 0xff)
        result[6] = UInt8(x3 & 0xff)
        result[7] = UInt8((x3 >> 8) & 0xff)
        return result
    }

    static func decryptCBC(cipher: Data, key: Data, iv: Data, effectiveKeyBits: Int = 40) throws -> Data {
        let cipherBytes = [UInt8](cipher)
        let ivBytes = [UInt8](iv)
        let keyBytes = [UInt8](key)

        guard ivBytes.count == 8, cipherBytes.count % 8 == 0, !cipherBytes.isEmpty else {
            throw CodeSignerError.certificateError("Invalid RC2 ciphertext or IV length")
        }

        let subkeys = setKey(key: keyBytes, bits: effectiveKeyBits)
        var decrypted = [UInt8](repeating: 0, count: cipherBytes.count)
        var xorBlock = ivBytes

        for offset in stride(from: 0, to: cipherBytes.count, by: 8) {
            let block = Array(cipherBytes[offset..<offset + 8])
            let d = decryptBlock(block: block, subkeys: subkeys)

            for i in 0..<8 {
                decrypted[offset + i] = d[i] ^ xorBlock[i]
            }
            xorBlock = block
        }

        guard let padLen = decrypted.last, padLen > 0, padLen <= 8, Int(padLen) <= decrypted.count else {
            throw CodeSignerError.certificateError("Invalid PKCS#7 padding in RC2 ciphertext")
        }
        for i in (decrypted.count - Int(padLen))..<decrypted.count {
            guard decrypted[i] == padLen else {
                throw CodeSignerError.certificateError("Corrupted PKCS#7 padding in RC2 ciphertext")
            }
        }
        return Data(decrypted.dropLast(Int(padLen)))
    }
}

enum TripleDESCipher {

    private static let ip: [UInt8] = [
        58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4,
        62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8,
        57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3,
        61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7
    ]

    private static let fp: [UInt8] = [
        40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31,
        38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29,
        36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27,
        34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25
    ]

    private static let pc1: [UInt8] = [
        57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18,
        10, 2, 59, 51, 43, 35, 27, 19, 11, 3, 60, 52, 44, 36,
        63, 55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38, 30, 22,
        14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 28, 20, 12, 4
    ]

    private static let pc2: [UInt8] = [
        14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10,
        23, 19, 12, 4, 26, 8, 16, 7, 27, 20, 13, 2,
        41, 52, 31, 37, 47, 55, 30, 40, 51, 45, 33, 48,
        44, 49, 39, 56, 34, 53, 46, 42, 50, 36, 29, 32
    ]

    private static let shifts: [UInt8] = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]

    private static let sBoxes: [[[UInt8]]] = [
        [[14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7],
         [0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8],
         [4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0],
         [15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13]],
        [[15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10],
         [3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5],
         [0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15],
         [13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9]],
        [[10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8],
         [13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1],
         [13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7],
         [1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12]],
        [[7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15],
         [13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9],
         [10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4],
         [3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14]],
        [[2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9],
         [14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6],
         [4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14],
         [11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3]],
        [[12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11],
         [10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8],
         [9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6],
         [4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13]],
        [[4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1],
         [13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6],
         [1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2],
         [6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12]],
        [[13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7],
         [1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2],
         [7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8],
         [2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11]]
    ]

    private static let pPerm: [UInt8] = [
        16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10,
        2, 8, 24, 14, 32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4, 25
    ]

    private static func desKeySchedule(key: Data) -> [UInt64] {
        var keyBits: [UInt8] = []
        for byte in key {
            for b in (0..<8).reversed() {
                keyBits.append((byte >> b) & 1)
            }
        }
        var c = [UInt8](repeating: 0, count: 28)
        var d = [UInt8](repeating: 0, count: 28)
        for i in 0..<28 {
            c[i] = keyBits[Int(pc1[i]) - 1]
            d[i] = keyBits[Int(pc1[i + 28]) - 1]
        }
        var subkeys: [UInt64] = []
        for round in 0..<16 {
            let shift = Int(shifts[round])
            c = Array(c[shift..<28] + c[0..<shift])
            d = Array(d[shift..<28] + d[0..<shift])
            let cd = c + d
            var k: UInt64 = 0
            for i in 0..<48 {
                k = (k << 1) | UInt64(cd[Int(pc2[i]) - 1])
            }
            subkeys.append(k)
        }
        return subkeys
    }

    private static func desEncryptBlock(block: Data, key: Data) -> Data {
        let subkeys = desKeySchedule(key: key)
        return desProcessBlock(block: block, subkeys: subkeys)
    }

    private static func desDecryptBlock(block: Data, key: Data) -> Data {
        let subkeys = desKeySchedule(key: key).reversed()
        return desProcessBlock(block: block, subkeys: Array(subkeys))
    }

    private static func desProcessBlock(block: Data, subkeys: [UInt64]) -> Data {
        var bits: [UInt8] = []
        for byte in block {
            for b in (0..<8).reversed() {
                bits.append((byte >> b) & 1)
            }
        }
        var ipBits = [UInt8](repeating: 0, count: 64)
        for i in 0..<64 {
            ipBits[i] = bits[Int(ip[i]) - 1]
        }
        var l: UInt32 = 0
        var r: UInt32 = 0
        for i in 0..<32 { l = (l << 1) | UInt32(ipBits[i]) }
        for i in 32..<64 { r = (r << 1) | UInt32(ipBits[i]) }

        for round in 0..<16 {
            let k = subkeys[round]
            var er: UInt64 = 0
            let eTable: [UInt8] = [
                32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9,
                8, 9, 10, 11, 12, 13, 12, 13, 14, 15, 16, 17,
                16, 17, 18, 19, 20, 21, 20, 21, 22, 23, 24, 25,
                24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1
            ]
            for i in 0..<48 {
                let bit = (r >> (32 - UInt32(eTable[i]))) & 1
                er = (er << 1) | UInt64(bit)
            }
            let x = er ^ k
            var sOut: UInt32 = 0
            for s in 0..<8 {
                let chunk = UInt8((x >> (42 - s * 6)) & 0x3F)
                let row = ((chunk & 0x20) >> 4) | (chunk & 0x01)
                let col = (chunk >> 1) & 0x0F
                let val = sBoxes[s][Int(row)][Int(col)]
                sOut = (sOut << 4) | UInt32(val)
            }
            var f: UInt32 = 0
            for i in 0..<32 {
                let bit = (sOut >> (32 - UInt32(pPerm[i]))) & 1
                f = (f << 1) | bit
            }
            let newR = l ^ f
            l = r
            r = newR
        }

        let preFP = Array(Swift.withUnsafeBytes(of: r.bigEndian) { Data($0) }) + Array(Swift.withUnsafeBytes(of: l.bigEndian) { Data($0) })
        var preFPBits: [UInt8] = []
        for byte in preFP {
            for b in (0..<8).reversed() {
                preFPBits.append((byte >> b) & 1)
            }
        }
        var result = Data(count: 8)
        for i in 0..<64 {
            let bit = preFPBits[Int(fp[i]) - 1]
            let byteIdx = i / 8
            let bitIdx = 7 - (i % 8)
            result[byteIdx] |= (bit << bitIdx)
        }
        return result
    }

    static func decryptCBC(cipher: Data, key: Data, iv: Data) throws -> Data {
        let cipherBytes = [UInt8](cipher)
        let ivBytes = [UInt8](iv)
        let keyBytes = [UInt8](key)

        guard keyBytes.count == 24, ivBytes.count == 8, cipherBytes.count % 8 == 0, !cipherBytes.isEmpty else {
            throw CodeSignerError.certificateError("Invalid 3DES ciphertext or key/IV length")
        }

        var decrypted = [UInt8](repeating: 0, count: cipherBytes.count)
        var previousBlock = ivBytes

        let k1 = Data(keyBytes[0..<8])
        let k2 = Data(keyBytes[8..<16])
        let k3 = Data(keyBytes[16..<24])

        for offset in stride(from: 0, to: cipherBytes.count, by: 8) {
            let block = Data(cipherBytes[offset..<offset + 8])

            var d = desDecryptBlock(block: block, key: k3)
            d = desEncryptBlock(block: d, key: k2)
            d = desDecryptBlock(block: d, key: k1)

            let dBytes = [UInt8](d)
            for i in 0..<8 {
                decrypted[offset + i] = dBytes[i] ^ previousBlock[i]
            }
            previousBlock = [UInt8](cipherBytes[offset..<offset + 8])
        }

        guard let padLen = decrypted.last, padLen > 0, padLen <= 8, Int(padLen) <= decrypted.count else {
            throw CodeSignerError.certificateError("Invalid PKCS#7 padding in 3DES ciphertext")
        }
        for i in (decrypted.count - Int(padLen))..<decrypted.count {
            guard decrypted[i] == padLen else {
                throw CodeSignerError.certificateError("Corrupted PKCS#7 padding in 3DES ciphertext")
            }
        }
        return Data(decrypted.dropLast(Int(padLen)))
    }
}
