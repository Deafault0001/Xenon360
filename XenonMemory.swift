// XenonMemory.swift
// Xenon360 — Memory Subsystem
//
// Xbox 360 Physical Memory Map:
//   0x00000000 – 0x1FFFFFFF  512 MB GDDR3 RAM
//   0x20000000 – 0x3FFFFFFF  Mirror of RAM (for GPU access)
//   0x7FFF0000 – 0x7FFFFFFF  Kernel data page
//   0xA0000000 – 0xBFFFFFFF  Flash / ROM
//   0xC8000000 – 0xC83FFFFF  GPU registers
//   0xEC800000 – 0xEC9FFFFF  Internal SRAM
//
// All accesses are big-endian (Xenon is big-endian PowerPC).

import Foundation

public final class XenonMemory {

    // Physical RAM — 512 MB
    private let ramSize: Int = 512 * 1024 * 1024
    public  let ram: UnsafeMutableRawPointer
    private let ramView: UnsafeMutablePointer<UInt8>

    // GPU register block (stub)
    private var gpuRegs: [UInt32: UInt32] = [:]

    // MMIO callbacks
    public var mmioReadHandler:  ((UInt64, Int) -> UInt64)?   // (addr, width) -> value
    public var mmioWriteHandler: ((UInt64, Int, UInt64) -> Void)?

    public init() {
        // Allocate 512 MB — use mmap-style allocation for efficiency on iOS
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: 512 * 1024 * 1024,
                                                    alignment: 4096)
        ptr.initializeMemory(as: UInt8.self, repeating: 0, count: 512 * 1024 * 1024)
        self.ram = ptr
        self.ramView = ptr.assumingMemoryBound(to: UInt8.self)
    }

    deinit {
        ram.deallocate()
    }

    // MARK: - Address Translation

    private func physicalAddress(_ addr: UInt64) -> Int? {
        // Strip segment bits (Xbox 360 uses virtual addressing with HTAB)
        let phys = addr & 0x1FFF_FFFF  // lower 512 MB
        guard phys < UInt64(ramSize) else { return nil }
        return Int(phys)
    }

    // MARK: - Read (big-endian)

    public func read8(_ addr: UInt64) -> UInt8 {
        if let phys = physicalAddress(addr) {
            return ramView[phys]
        }
        return handleMMIORead(addr: addr, width: 1) as? UInt8 ?? 0xFF
    }

    public func read16(_ addr: UInt64) -> UInt16 {
        if let phys = physicalAddress(addr), phys + 1 < ramSize {
            let hi = UInt16(ramView[phys])
            let lo = UInt16(ramView[phys + 1])
            return (hi << 8) | lo  // big-endian
        }
        return UInt16(handleMMIORead(addr: addr, width: 2) & 0xFFFF)
    }

    public func read32(_ addr: UInt64) -> UInt32 {
        if let phys = physicalAddress(addr), phys + 3 < ramSize {
            return UInt32(ramView[phys])     << 24
                 | UInt32(ramView[phys + 1]) << 16
                 | UInt32(ramView[phys + 2]) << 8
                 | UInt32(ramView[phys + 3])
        }
        return UInt32(handleMMIORead(addr: addr, width: 4) & 0xFFFF_FFFF)
    }

    public func read64(_ addr: UInt64) -> UInt64 {
        let hi = UInt64(read32(addr))
        let lo = UInt64(read32(addr + 4))
        return (hi << 32) | lo
    }

    // MARK: - Write (big-endian)

    public func write8(_ addr: UInt64, value: UInt8) {
        if let phys = physicalAddress(addr) {
            ramView[phys] = value
        } else {
            mmioWriteHandler?(addr, 1, UInt64(value))
        }
    }

    public func write16(_ addr: UInt64, value: UInt16) {
        if let phys = physicalAddress(addr), phys + 1 < ramSize {
            ramView[phys]     = UInt8(value >> 8)
            ramView[phys + 1] = UInt8(value & 0xFF)
        } else {
            mmioWriteHandler?(addr, 2, UInt64(value))
        }
    }

    public func write32(_ addr: UInt64, value: UInt32) {
        if let phys = physicalAddress(addr), phys + 3 < ramSize {
            ramView[phys]     = UInt8((value >> 24) & 0xFF)
            ramView[phys + 1] = UInt8((value >> 16) & 0xFF)
            ramView[phys + 2] = UInt8((value >>  8) & 0xFF)
            ramView[phys + 3] = UInt8(value & 0xFF)
        } else {
            mmioWriteHandler?(addr, 4, UInt64(value))
        }
    }

    public func write64(_ addr: UInt64, value: UInt64) {
        write32(addr,     value: UInt32((value >> 32) & 0xFFFF_FFFF))
        write32(addr + 4, value: UInt32(value & 0xFFFF_FFFF))
    }

    // MARK: - Bulk copy (for loaders)

    public func loadBytes(_ data: Data, at address: UInt64) {
        guard let phys = physicalAddress(address),
              phys + data.count <= ramSize else { return }
        data.withUnsafeBytes { bytes in
            guard let src = bytes.baseAddress else { return }
            memcpy(ramView + phys, src, data.count)
        }
    }

    // MARK: - MMIO

    private func handleMMIORead(addr: UInt64, width: Int) -> UInt64 {
        if let handler = mmioReadHandler {
            return handler(addr, width)
        }
        // GPU stub — return known sentinel values
        if addr >= 0xC800_0000 && addr < 0xC840_0000 {
            return gpuRegs[UInt32(addr & 0xFFFF_FFFF)] ?? 0
        }
        return 0xDEAD_BEEF
    }

    // MARK: - Utilities

    public func hexDump(from addr: UInt64, length: Int) -> String {
        var output = ""
        let lineSize = 16
        let start = Int(addr & 0x1FFF_FFFF)
        for row in stride(from: 0, to: length, by: lineSize) {
            output += String(format: "%08X: ", UInt32(addr) + UInt32(row))
            var ascii = ""
            for col in 0..<lineSize {
                let offset = start + row + col
                if row + col < length && offset < ramSize {
                    let byte = ramView[offset]
                    output += String(format: "%02X ", byte)
                    ascii += (byte >= 32 && byte < 127) ? String(UnicodeScalar(byte)) : "."
                } else {
                    output += "   "
                    ascii += " "
                }
                if col == 7 { output += " " }
            }
            output += " |\(ascii)|\n"
        }
        return output
    }

    public var usedBytes: Int {
        // Simple count of non-zero bytes (approximation)
        var count = 0
        let limit = min(ramSize, 1024 * 1024) // check first 1MB only
        for i in 0..<limit { if ramView[i] != 0 { count += 1 } }
        return count
    }
}
