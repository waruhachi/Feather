//
//  SRPClient.swift
//  GSACryptoKit
//
//  Created by Magesh K on 28/08/26.
//  Copyright © 2026 GSACryptoKit. All rights reserved.
//

import Foundation
import Crypto

public final class SRPClient {

    // RFC 5054 2048-bit MODP Group Prime (N)
    private static let N_Hex = """
    AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050\
    A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50\
    E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A9962F0B93B8\
    55F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E446B14773B\
    CA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D32E688F87748\
    544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6\
    AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB6\
    94B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73
    """

    private static let N_Bytes: Data = Data(hexString: N_Hex)!
    private static let g_Val: UInt32 = 2
    public static let GroupSize: Int = 256

    private let bnN: BigUInt
    private let bng: BigUInt
    private let bnk: BigUInt
    private var bna: BigUInt? // client private ephemeral
    private var bnA: BigUInt? // client public ephemeral
    private var bnK: Data?    // session key (32 bytes)
    private var expectedM2: Data?

    private static func sha256(_ data: Data) -> Data {
        let digest = SHA256.hash(data: data)
        return Data(digest)
    }

    public init?() {
        let n = BigUInt(data: Self.N_Bytes)
        let g = BigUInt(UInt64(Self.g_Val))
        self.bnN = n
        self.bng = g

        // Compute k = SHA256(N || pad(g))
        var gPadded = Data(repeating: 0, count: Self.GroupSize - 1)
        gPadded.append(UInt8(Self.g_Val))
        let kBytes = Self.sha256(Self.N_Bytes + gPadded)
        self.bnk = BigUInt(data: kBytes)
    }

    public func exchangeSize() -> Int {
        return Self.GroupSize
    }

    public func startAuthentication() -> Data? {
        // Generate random private ephemeral a (256 bits = 32 bytes)
        let a = BigUInt.random(bitWidth: 256)
        // A = g^a mod N
        let A = bng.power(a, modulus: bnN)

        self.bna = a
        self.bnA = A

        return A.serialize(paddedTo: Self.GroupSize)
    }

    public func processChallenge(
        username: String,
        password passwordBytes: Data,
        salt: Data,
        serverPublicKey bData: Data
    ) -> Data? {
        guard let bna = bna, let bnA = bnA else { return nil }

        // 1. Load B from server
        let bnB = BigUInt(data: bData)

        // Check B % N != 0
        guard !(bnB % bnN).isZero else { return nil }

        // 2. Export A as 256-byte padded Data
        let aData = bnA.serialize(paddedTo: Self.GroupSize)

        // 3. Compute u = SHA256(A || B)
        let uData = Self.sha256(aData + bData)
        let bnu = BigUInt(data: uData)
        guard !bnu.isZero else { return nil }

        // 4. corecrypto srp (ccsrp) derives x as:
        // h1 = SHA256(":" || password)
        // x  = SHA256(salt || h1)
        let h1 = Self.sha256(Data(":".utf8) + passwordBytes)
        let xHash = Self.sha256(salt + h1)
        let bnx = BigUInt(data: xHash)

        // 5. v = g^x mod N
        let bnv = bng.power(bnx, modulus: bnN)

        // 6. Base = (B - k*v) mod N
        let bnkv = (bnk * bnv) % bnN
        let bnBase = bnB.modSub(bnkv, modulus: bnN)

        // 7. Exp = (a + u*x)
        let bnux = bnu * bnx
        let bnExp = bna + bnux

        // 8. S = Base^Exp mod N
        let bnS = bnBase.power(bnExp, modulus: bnN)
        let sBytes = bnS.serialize(paddedTo: Self.GroupSize)

        // 9. Session key K = SHA256(S)
        let kSessionData = Self.sha256(sBytes)
        self.bnK = kSessionData

        // 10. Compute M1 = SHA256(H(N) ^ H(g) || H(U) || salt || A || B || K)
        let hn = Self.sha256(Self.N_Bytes)
        var gPadded = Data(repeating: 0, count: Self.GroupSize - 1)
        gPadded.append(UInt8(Self.g_Val))
        let hg = Self.sha256(gPadded)

        var hXor = Data(count: 32)
        for i in 0..<32 {
            hXor[i] = hn[i] ^ hg[i]
        }

        let hu = Self.sha256(Data(username.utf8))
        let m1Payload = hXor + hu + salt + aData + bData + kSessionData
        let m1Data = Self.sha256(m1Payload)

        // 11. Precompute expected M2 = SHA256(A || M1 || K)
        let m2Payload = aData + m1Data + kSessionData
        self.expectedM2 = Self.sha256(m2Payload)

        return m1Data
    }

    public func verifyServerProof(_ proof: Data) -> Bool {
        guard let expected = expectedM2 else { return false }
        return proof == expected
    }

    public func sessionKey() -> Data? {
        return bnK
    }
}

fileprivate extension Data {
    init?(hexString: String) {
        let cleaned = hexString.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\t", with: "")
        guard cleaned.count % 2 == 0 else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            let byteStr = String(cleaned[index..<nextIndex])
            guard let byte = UInt8(byteStr, radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
