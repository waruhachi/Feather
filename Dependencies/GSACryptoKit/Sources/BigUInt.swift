//
//  BigUInt.swift
//  GSACryptoKit
//
//  Created by Magesh K on 28/08/26.
//  Copyright © 2026 GSACryptoKit. All rights reserved.
//

import Foundation
import Crypto

struct BigUInt: Equatable, Comparable, CustomStringConvertible {
    var words: [UInt64]

    static let zero = BigUInt()

    init() {
        self.words = []
    }

    init(_ value: UInt64) {
        if value == 0 {
            self.words = []
        } else {
            self.words = [value]
        }
    }

    init(words: [UInt64]) {
        var trimmed = words
        while let last = trimmed.last, last == 0 {
            trimmed.removeLast()
        }
        self.words = trimmed
    }

    init(data: Data) {
        guard !data.isEmpty else {
            self.init()
            return
        }
        var parsedWords: [UInt64] = []
        let byteCount = data.count
        let fullWords = byteCount / 8
        let remainder = byteCount % 8

        var endIndex = data.endIndex
        for _ in 0..<fullWords {
            let startIndex = data.index(endIndex, offsetBy: -8)
            var word: UInt64 = 0
            for byte in data[startIndex..<endIndex] {
                word = (word << 8) | UInt64(byte)
            }
            parsedWords.append(word)
            endIndex = startIndex
        }
        if remainder > 0 {
            let startIndex = data.startIndex
            var word: UInt64 = 0
            for byte in data[startIndex..<endIndex] {
                word = (word << 8) | UInt64(byte)
            }
            parsedWords.append(word)
        }
        self.init(words: parsedWords)
    }

    init?(hexString: String) {
        let cleaned = hexString.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\t", with: "")
        guard let data = Data(hexString: cleaned) else { return nil }
        self.init(data: data)
    }

    var isZero: Bool {
        return words.isEmpty
    }

    var bitWidth: Int {
        guard let last = words.last else { return 0 }
        return (words.count - 1) * 64 + (64 - last.leadingZeroBitCount)
    }

    func testBit(_ index: Int) -> Bool {
        let wordIndex = index / 64
        let bitIndex = index % 64
        guard wordIndex < words.count else { return false }
        return (words[wordIndex] & (1 << bitIndex)) != 0
    }

    var description: String {
        if isZero { return "0" }
        return serialize().map { String(format: "%02x", $0) }.joined()
    }

    static func == (lhs: BigUInt, rhs: BigUInt) -> Bool {
        return lhs.words == rhs.words
    }

    static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        if lhs.words.count != rhs.words.count {
            return lhs.words.count < rhs.words.count
        }
        for i in (0..<lhs.words.count).reversed() {
            if lhs.words[i] != rhs.words[i] {
                return lhs.words[i] < rhs.words[i]
            }
        }
        return false
    }

    static func <= (lhs: BigUInt, rhs: BigUInt) -> Bool {
        return (lhs < rhs) || (lhs == rhs)
    }

    static func > (lhs: BigUInt, rhs: BigUInt) -> Bool {
        return rhs < lhs
    }

    static func >= (lhs: BigUInt, rhs: BigUInt) -> Bool {
        return rhs <= lhs
    }

    static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var result: [UInt64] = []
        let maxCount = max(lhs.words.count, rhs.words.count)
        result.reserveCapacity(maxCount + 1)
        var carry: UInt64 = 0
        for i in 0..<maxCount {
            let w1 = i < lhs.words.count ? lhs.words[i] : 0
            let w2 = i < rhs.words.count ? rhs.words[i] : 0
            let (s1, o1) = w1.addingReportingOverflow(w2)
            let (s2, o2) = s1.addingReportingOverflow(carry)
            result.append(s2)
            carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        if carry > 0 {
            result.append(carry)
        }
        return BigUInt(words: result)
    }

    static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        guard lhs >= rhs else {
            fatalError("Underflow in BigUInt subtraction")
        }
        var result: [UInt64] = []
        result.reserveCapacity(lhs.words.count)
        var borrow: UInt64 = 0
        for i in 0..<lhs.words.count {
            let w1 = lhs.words[i]
            let w2 = i < rhs.words.count ? rhs.words[i] : 0
            let (d1, o1) = w1.subtractingReportingOverflow(w2)
            let (d2, o2) = d1.subtractingReportingOverflow(borrow)
            result.append(d2)
            borrow = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return BigUInt(words: result)
    }

    static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        if lhs.isZero || rhs.isZero { return BigUInt.zero }
        let n = lhs.words.count
        let m = rhs.words.count
        var result = [UInt64](repeating: 0, count: n + m)
        for i in 0..<n {
            var carry: UInt64 = 0
            for j in 0..<m {
                let (high, low) = lhs.words[i].multipliedFullWidth(by: rhs.words[j])
                let (s1, o1) = result[i + j].addingReportingOverflow(low)
                let (s2, o2) = s1.addingReportingOverflow(carry)
                result[i + j] = s2
                carry = high + (o1 ? 1 : 0) + (o2 ? 1 : 0)
            }
            result[i + m] = carry
        }
        return BigUInt(words: result)
    }

    static func << (lhs: BigUInt, shift: Int) -> BigUInt {
        if lhs.isZero || shift == 0 { return lhs }
        if shift < 0 { return lhs >> (-shift) }
        let wordShift = shift / 64
        let bitShift = shift % 64
        var result = [UInt64](repeating: 0, count: lhs.words.count + wordShift + (bitShift > 0 ? 1 : 0))
        var carry: UInt64 = 0
        for i in 0..<lhs.words.count {
            let w = lhs.words[i]
            if bitShift == 0 {
                result[i + wordShift] = w
            } else {
                result[i + wordShift] = (w << bitShift) | carry
                carry = w >> (64 - bitShift)
            }
        }
        if bitShift > 0 && carry > 0 {
            result[lhs.words.count + wordShift] = carry
        }
        return BigUInt(words: result)
    }

    static func >> (lhs: BigUInt, shift: Int) -> BigUInt {
        if lhs.isZero || shift == 0 { return lhs }
        if shift < 0 { return lhs << (-shift) }
        let wordShift = shift / 64
        let bitShift = shift % 64
        if wordShift >= lhs.words.count { return BigUInt.zero }
        var result = [UInt64]()
        result.reserveCapacity(lhs.words.count - wordShift)
        var carry: UInt64 = 0
        for i in (wordShift..<lhs.words.count).reversed() {
            let w = lhs.words[i]
            if bitShift == 0 {
                result.append(w)
            } else {
                let high = carry
                carry = w << (64 - bitShift)
                if i < lhs.words.count - 1 || (w >> bitShift) != 0 {
                    result.append((w >> bitShift) | high)
                }
            }
        }
        result.reverse()
        return BigUInt(words: result)
    }

    func quotientAndRemainder(dividingBy rhs: BigUInt) -> (quotient: BigUInt, remainder: BigUInt) {
        guard !rhs.isZero else { fatalError("Division by zero in BigUInt") }
        if self < rhs {
            return (BigUInt.zero, self)
        }
        if rhs.words.count == 1 {
            let divisor = rhs.words[0]
            var quotientWords = [UInt64](repeating: 0, count: self.words.count)
            var remainder: UInt64 = 0
            for i in (0..<self.words.count).reversed() {
                let (q, r) = divisor.dividingFullWidth((high: remainder, low: self.words[i]))
                quotientWords[i] = q
                remainder = r
            }
            return (BigUInt(words: quotientWords), BigUInt(remainder))
        }
        return BigUInt.knuthDivMod(self, rhs)
    }

    static func / (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        return lhs.quotientAndRemainder(dividingBy: rhs).quotient
    }

    static func % (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        return lhs.quotientAndRemainder(dividingBy: rhs).remainder
    }

    private static func knuthDivMod(_ u: BigUInt, _ v: BigUInt) -> (quotient: BigUInt, remainder: BigUInt) {
        let n = v.words.count
        let m = u.words.count - n

        let shift = v.words[n - 1].leadingZeroBitCount
        let uNorm = u << shift
        let vNorm = v << shift

        var uWords = uNorm.words
        while uWords.count < u.words.count + (shift > 0 ? 1 : 0) + 1 {
            uWords.append(0)
        }
        if uWords.count <= m + n {
            uWords.append(0)
        }
        let vn1 = vNorm.words[n - 1]
        let vn2 = n > 1 ? vNorm.words[n - 2] : 0

        var qWords = [UInt64](repeating: 0, count: m + 1)

        for j in (0...m).reversed() {
            let ujn = uWords[j + n]
            let ujn1 = uWords[j + n - 1]
            let ujn2 = j + n >= 2 ? uWords[j + n - 2] : 0

            var qHat: UInt64
            var rHat: UInt64
            if ujn == vn1 {
                qHat = UInt64.max
                let (r, overflow) = ujn1.addingReportingOverflow(vn1)
                rHat = r
                if !overflow && vn2 > 0 {
                    let (pHigh, pLow) = qHat.multipliedFullWidth(by: vn2)
                    if pHigh > rHat || (pHigh == rHat && pLow > ujn2) {
                        qHat -= 1
                        let (r2, o2) = rHat.addingReportingOverflow(vn1)
                        rHat = r2
                        if !o2 {
                            let (pHigh2, pLow2) = qHat.multipliedFullWidth(by: vn2)
                            if pHigh2 > rHat || (pHigh2 == rHat && pLow2 > ujn2) {
                                qHat -= 1
                            }
                        }
                    }
                }
            } else {
                let (q, r) = vn1.dividingFullWidth((high: ujn, low: ujn1))
                qHat = q
                rHat = r
                if vn2 > 0 {
                    let (pHigh, pLow) = qHat.multipliedFullWidth(by: vn2)
                    if pHigh > rHat || (pHigh == rHat && pLow > ujn2) {
                        qHat -= 1
                        let (r2, o2) = rHat.addingReportingOverflow(vn1)
                        rHat = r2
                        if !o2 {
                            let (pHigh2, pLow2) = qHat.multipliedFullWidth(by: vn2)
                            if pHigh2 > rHat || (pHigh2 == rHat && pLow2 > ujn2) {
                                qHat -= 1
                            }
                        }
                    }
                }
            }

            let qv = vNorm * BigUInt(qHat)
            let sliceWords = Array(uWords[j...(j + n)])
            let uSlice = BigUInt(words: sliceWords)

            let rem: BigUInt
            if uSlice >= qv {
                rem = uSlice - qv
            } else {
                qHat -= 1
                rem = (uSlice + vNorm) - qv
            }

            for k in 0...n {
                uWords[j + k] = k < rem.words.count ? rem.words[k] : 0
            }

            qWords[j] = qHat
        }

        let remRaw = BigUInt(words: Array(uWords.prefix(n)))
        let remainder = remRaw >> shift
        return (BigUInt(words: qWords), remainder)
    }

    func modAdd(_ other: BigUInt, modulus: BigUInt) -> BigUInt {
        return (self + other) % modulus
    }

    func modSub(_ other: BigUInt, modulus: BigUInt) -> BigUInt {
        let s = self % modulus
        let o = other % modulus
        if s >= o {
            return s - o
        } else {
            return modulus - (o - s)
        }
    }

    func modMul(_ other: BigUInt, modulus: BigUInt) -> BigUInt {
        return (self * other) % modulus
    }

    func power(_ exp: BigUInt, modulus: BigUInt) -> BigUInt {
        guard !modulus.isZero else { fatalError("Modulus cannot be zero") }
        if modulus == BigUInt(1) { return BigUInt.zero }
        if exp.isZero { return BigUInt(1) }

        var result = BigUInt(1)
        var base = self % modulus
        let totalBits = exp.bitWidth

        for i in 0..<totalBits {
            if exp.testBit(i) {
                result = (result * base) % modulus
            }
            if i + 1 < totalBits {
                base = (base * base) % modulus
            }
        }
        return result
    }

    func serialize(paddedTo byteCount: Int = 0) -> Data {
        if isZero {
            return Data(repeating: 0, count: byteCount)
        }
        var bytes = [UInt8]()
        for (i, word) in words.enumerated() {
            var w = word
            let isLastWord = (i == words.count - 1)
            var wordBytes = [UInt8]()
            for _ in 0..<8 {
                wordBytes.append(UInt8(w & 0xFF))
                w >>= 8
            }
            if isLastWord {
                while let last = wordBytes.last, last == 0 {
                    wordBytes.removeLast()
                }
            }
            bytes.append(contentsOf: wordBytes)
        }
        bytes.reverse()

        if byteCount > bytes.count {
            let padding = [UInt8](repeating: 0, count: byteCount - bytes.count)
            return Data(padding + bytes)
        } else if byteCount > 0 && bytes.count > byteCount {
            return Data(bytes.suffix(byteCount))
        }
        return Data(bytes)
    }

    static func random(bitWidth: Int) -> BigUInt {
        let byteCount = (bitWidth + 7) / 8
        var keyData = Data(count: byteCount)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<byteCount {
            keyData[i] = UInt8.random(in: 0...255, using: &rng)
        }
        let extraBits = byteCount * 8 - bitWidth
        if extraBits > 0 {
            keyData[0] &= UInt8((1 << (8 - extraBits)) - 1)
        }
        return BigUInt(data: keyData)
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
