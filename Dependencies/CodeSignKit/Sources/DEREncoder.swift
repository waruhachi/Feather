//
//  DEREncoder.swift
//  CodeSignKit
//
//  Created by Magesh K on 28/08/26.
//  Copyright © 2026 CodeSignKit. All rights reserved.
//

import Foundation

public enum DEREncoder {

    public static func encodeLength(_ length: Int) -> Data {
        if length < 128 {
            return Data([UInt8(length)])
        }
        var len = length
        var bytes: [UInt8] = []
        while len > 0 {
            bytes.insert(UInt8(len & 0xFF), at: 0)
            len >>= 8
        }
        return Data([UInt8(0x80 | bytes.count)] + bytes)
    }

    public static func encodeTLV(tag: UInt8, value: Data) -> Data {
        return Data([tag]) + encodeLength(value.count) + value
    }

    public static func encodeValue(_ value: any Sendable) -> Data? {
        if type(of: value) == Bool.self, let b = value as? Bool {
            return encodeTLV(tag: 0x01, value: Data([b ? 0x01 : 0x00]))
        } else if let num = value as? NSNumber {
            #if canImport(Darwin)
            if num.objCType.pointee == 0x63 /* 'c' for char/bool */ {
                return encodeTLV(tag: 0x01, value: Data([num.boolValue ? 0x01 : 0x00]))
            }
            #endif
            let intVal = num.int64Value
            var bigEndian = intVal.bigEndian
            var rawBytes = Array(Swift.withUnsafeBytes(of: &bigEndian) { $0 })
            while rawBytes.count > 1 && rawBytes[0] == 0 && (rawBytes[1] & 0x80) == 0 {
                rawBytes.removeFirst()
            }
            while rawBytes.count > 1 && rawBytes[0] == 0xFF && (rawBytes[1] & 0x80) != 0 {
                rawBytes.removeFirst()
            }
            return encodeTLV(tag: 0x02, value: Data(rawBytes))
        } else if let b = value as? Bool {
            return encodeTLV(tag: 0x01, value: Data([b ? 0x01 : 0x00]))
        } else if let str = value as? String {
            let utf8 = str.data(using: .utf8) ?? Data()
            return encodeTLV(tag: 0x0C, value: utf8)
        } else if let dataVal = value as? Data {
            return encodeTLV(tag: 0x04, value: dataVal)
        } else if let arr = value as? [any Sendable] {
            var payload = Data()
            for item in arr {
                guard let encoded = encodeValue(item) else { return nil }
                payload.append(encoded)
            }
            return encodeTLV(tag: 0x30, value: payload)
        } else if let dict = value as? [String: any Sendable] {
            var elements: [Data] = []
            for (k, v) in dict {
                let kData = encodeTLV(tag: 0x0C, value: k.data(using: .utf8) ?? Data())
                guard let vData = encodeValue(v) else { return nil }
                let pairData = encodeTLV(tag: 0x30, value: kData + vData)
                elements.append(pairData)
            }
            // Sort by DER byte representation (lexicographical)
            elements.sort { $0.lexicographicallyPrecedes($1) }
            var dictPayload = Data()
            for el in elements {
                dictPayload.append(el)
            }
            return encodeTLV(tag: 0x31, value: dictPayload)
        }

        return nil
    }

    public static func encodePlistXML(_ xml: String) -> Data? {
        guard let data = xml.data(using: .utf8) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: any Sendable] else {
            return nil
        }
        return encodeValue(plist)
    }
}
