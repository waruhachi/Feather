//
//  Data+Binary.swift
//  CodeSignKit
//
//  Created by Magesh K on 03/09/26.
//  Copyright © 2026 CodeSignKit. All rights reserved.
//

import Foundation

extension Data {
    // Appends a 32-bit UInt in Big-Endian format
    public mutating func writeUInt32BigEndian(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { bytes in
            self.append(contentsOf: bytes)
        }
    }

    // Appends a 32-bit UInt in Big-Endian format
    public mutating func appendUInt32BigEndian(_ value: UInt32) {
        writeUInt32BigEndian(value)
    }

    // Writes a 32-bit UInt in Big-Endian format at the specified offset
    public mutating func writeUInt32BigEndian(_ value: UInt32, at offset: Int) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { bytes in
            if offset + 4 <= self.count {
                self.replaceSubrange(offset..<offset + 4, with: bytes)
            } else {
                if offset > self.count {
                    self.append(Data(repeating: 0, count: offset - self.count))
                }
                self.append(contentsOf: bytes)
            }
        }
    }

    // Writes a 64-bit UInt in Big-Endian format at the specified offset
    public mutating func writeUInt64BigEndian(_ value: UInt64, at offset: Int) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { bytes in
            if offset + 8 <= self.count {
                self.replaceSubrange(offset..<offset + 8, with: bytes)
            } else {
                if offset > self.count {
                    self.append(Data(repeating: 0, count: offset - self.count))
                }
                self.append(contentsOf: bytes)
            }
        }
    }

    // Reads a 32-bit UInt at offset and converts from Big-Endian to host order
    public func readUInt32BigEndian(at offset: Int) -> UInt32 {
        guard offset + 4 <= self.count else { return 0 }
        return self.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian }
    }

    // Reads a 32-bit UInt in host byte order at the specified offset
    public func readUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= self.count else { return 0 }
        return self.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    // Writes a 32-bit UInt in host byte order at the specified offset
    public mutating func writeUInt32(_ value: UInt32, at offset: Int) {
        var val = value
        Swift.withUnsafeBytes(of: &val) { bytes in
            if offset + 4 <= self.count {
                self.replaceSubrange(offset..<offset + 4, with: bytes)
            } else {
                if offset > self.count {
                    self.append(Data(repeating: 0, count: offset - self.count))
                }
                self.append(contentsOf: bytes)
            }
        }
    }

    // Writes a 64-bit UInt in host byte order at the specified offset
    public mutating func writeUInt64(_ value: UInt64, at offset: Int) {
        var val = value
        Swift.withUnsafeBytes(of: &val) { bytes in
            if offset + 8 <= self.count {
                self.replaceSubrange(offset..<offset + 8, with: bytes)
            } else {
                if offset > self.count {
                    self.append(Data(repeating: 0, count: offset - self.count))
                }
                self.append(contentsOf: bytes)
            }
        }
    }

    // Reads a 64-bit UInt in host byte order at the specified offset
    public func readUInt64(at offset: Int) -> UInt64 {
        guard offset + 8 <= self.count else { return 0 }
        return self.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
    }

    // Reads a 64-bit UInt at offset and converts from Big-Endian to host order
    public func readUInt64BigEndian(at offset: Int) -> UInt64 {
        guard offset + 8 <= self.count else { return 0 }
        return self.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self).bigEndian }
    }
}
