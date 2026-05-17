// XEXLoader.swift
// Xenon360 — Xbox 360 Executable (XEX2) Loader
//
// XEX2 is the signed/encrypted executable format used by Xbox 360.
// Format overview:
//   XEX2 Header → Optional Headers → Loader Info → Security Info
//   → Section Table → PE Image (LZX compressed or raw)
//
// This loader handles:
//   • Magic validation (XEX2 / XEX1 / XEX0)
//   • Optional header parsing (title info, execution info, imports)
//   • Section mapping into XenonMemory
//   • Entry point extraction
//   • Basic import stub generation

import Foundation

// MARK: - XEX Constants

enum XEXMagic: UInt32 {
    case xex2 = 0x58455832  // "XEX2"
    case xex1 = 0x58455831  // "XEX1"
    case xex0 = 0x58455830  // "XEX0"
}

enum XEXOptionalHeader: UInt32 {
    case resourceInfo        = 0x000002FF
    case baseFileFormat      = 0x000003FF
    case baseReference       = 0x00000405
    case deltaPatchDescriptor = 0x000005FF
    case boundingPath        = 0x000080FF
    case deviceID            = 0x00008105
    case originalBaseAddr    = 0x00010001
    case entryPoint          = 0x00010100
    case imageBaseAddr       = 0x00010201
    case importLibraries     = 0x000103FF
    case checksumTimestamp   = 0x00018002
    case enabledForCallcap   = 0x00018102
    case enabledForFastcap   = 0x00018200
    case originalPEName      = 0x000183FF
    case staticLibraries     = 0x000200FF
    case tlsInfo             = 0x00020104
    case defaultStackSize    = 0x00020200
    case defaultFSCacheSize  = 0x00020301
    case defaultHeapSize     = 0x00020401
    case pageHeapSizeFlags   = 0x00028002
    case systemFlags         = 0x00030000
    case executionInfo       = 0x00040006
    case titleWorkspaceSize  = 0x00040201
    case gameRatings         = 0x00040310
    case lanKey              = 0x00040404
    case xboxHDVideoMode     = 0x00040604
    case multidiscMediaIDs   = 0x000406FF
    case alternateTitleIDs   = 0x000407FF
    case additionalTitleMemory = 0x00040801
    case exportsByName       = 0x00E10402
}

// MARK: - XEX Header Structures

struct XEX2Header {
    let magic: UInt32
    let moduleFlags: UInt32
    let headerSize: UInt32
    let reserved: UInt32
    let securityOffset: UInt32
    let optionalHeaderCount: UInt32
}

struct XEX2OptionalHeaderEntry {
    let key: UInt32
    let data: UInt32   // value or offset depending on key low byte
}

struct XEX2SecurityInfo {
    let headerSize: UInt32
    let imageSize: UInt32
    let rsaSignature: Data     // 256 bytes
    let unknown0C4: UInt32
    let imageFlags: UInt32
    let loadAddress: UInt32
    let sectionDigest: Data   // 20 bytes SHA1
    let importTableCount: UInt32
    let importDigest: Data    // 20 bytes
    let mediaID: Data         // 16 bytes
    let sessionKey: Data      // 16 bytes (AES)
    let exportTable: UInt32
    let unknown10C: Data      // 44 bytes
    let pageDescriptorCount: UInt32
}

struct XEX2Section {
    let info: UInt32           // page count | flags
    let digest: Data           // 20-byte SHA1

    var pageCount: UInt32 { (info & 0xFFFFFF00) >> 8 }
    var flags: UInt8  { UInt8(info & 0xFF) }
    var isReadable:   Bool { (flags & 0x01) != 0 }
    var isWritable:   Bool { (flags & 0x02) != 0 }
    var isExecutable: Bool { (flags & 0x04) != 0 }
    var size: UInt32  { pageCount * 0x1000 }  // 4KB pages
}

struct XEX2ExecutionInfo {
    let mediaID: UInt32
    let version: UInt32
    let baseVersion: UInt32
    let titleID: UInt32
    let platform: UInt8
    let executableTable: UInt8
    let discNumber: UInt8
    let discCount: UInt8
    let savegameID: UInt32
}

struct XEX2ImportLibrary {
    let name: String
    let id: Data        // 16 bytes
    let versionMin: UInt32
    let versionMax: UInt32
    let addresses: [UInt32]
}

// MARK: - Loaded XEX

public struct LoadedXEX {
    public let title: String
    public let titleID: UInt32
    public let entryPoint: UInt64
    public let baseAddress: UInt32
    public let imageSize: UInt32
    public let sections: [SectionInfo]
    public let imports: [ImportInfo]
    public let stackSize: UInt32

    public struct SectionInfo {
        public let virtualAddress: UInt32
        public let virtualSize: UInt32
        public let isExecutable: Bool
        public let isWritable: Bool
        public let name: String
    }

    public struct ImportInfo {
        public let library: String
        public let ordinal: UInt32
        public let address: UInt32
        public let resolvedName: String?
    }
}

// MARK: - XEX Loader Errors

public enum XEXError: Error, LocalizedError {
    case invalidMagic(UInt32)
    case truncatedHeader
    case unsupportedCompression
    case decryptionFailed
    case invalidSections
    case fileReadError(String)
    case notAnXEX

    public var errorDescription: String? {
        switch self {
        case .invalidMagic(let m):
            return String(format: "Not an Xbox 360 XEX file (magic: 0x%08X)", m)
        case .truncatedHeader:    return "File is too small / truncated"
        case .unsupportedCompression: return "Unsupported XEX compression method"
        case .decryptionFailed:   return "XEX decryption failed (wrong key?)"
        case .invalidSections:    return "Invalid section table"
        case .fileReadError(let s): return "File error: \(s)"
        case .notAnXEX:           return "This is not an Xbox 360 executable"
        }
    }
}

// MARK: - XEX2 Loader

public class XEXLoader {

    private let memory: XenonMemory

    // Known kernel import names (subset)
    private static let kernelExports: [UInt32: String] = [
        0x01: "NtCreateFile",
        0x02: "NtReadFile",
        0x03: "NtWriteFile",
        0x04: "NtQueryInformationFile",
        0x05: "NtSetInformationFile",
        0x06: "NtClose",
        0x10: "ExAllocatePoolWithTag",
        0x11: "ExFreePool",
        0x20: "KeGetCurrentProcessType",
        0x21: "KeSetAffinityThread",
        0x22: "KeQueryPerformanceCounter",
        0x30: "RtlInitializeCriticalSection",
        0x31: "RtlEnterCriticalSection",
        0x32: "RtlLeaveCriticalSection",
        0x40: "XAudioCreateSourceVoice",
        0x41: "XAudioCreateSubmixVoice",
        0x42: "XAudioGetSilentSamples",
        0x50: "D3DCreateDevice",
        0x51: "D3DPresent",
        0x52: "D3DDrawIndexedPrimitive",
        0x60: "XInputGetState",
        0x61: "XInputSetState",
    ]

    public init(memory: XenonMemory) {
        self.memory = memory
    }

    // MARK: - Main Load Entry Point

    public func load(url: URL) throws -> LoadedXEX {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw XEXError.fileReadError(error.localizedDescription)
        }
        return try load(data: data)
    }

    public func load(data: Data) throws -> LoadedXEX {
        guard data.count >= 24 else { throw XEXError.truncatedHeader }

        let reader = BinaryReader(data: data)

        // ── Validate magic ────────────────────────────────────────
        let magic = try reader.readUInt32BE()
        guard magic == XEXMagic.xex2.rawValue ||
              magic == XEXMagic.xex1.rawValue else {
            throw XEXError.invalidMagic(magic)
        }

        // ── Parse main header ─────────────────────────────────────
        let moduleFlags       = try reader.readUInt32BE()
        let peDataOffset      = try reader.readUInt32BE()
        let _                 = try reader.readUInt32BE()  // reserved
        let securityOffset    = try reader.readUInt32BE()
        let optHeaderCount    = try reader.readUInt32BE()

        // ── Parse optional headers ────────────────────────────────
        var entryPoint:  UInt64 = 0
        var baseAddress: UInt32 = 0x80000000
        var imageSize:   UInt32 = 0
        var stackSize:   UInt32 = 0x10000
        var titleID:     UInt32 = 0
        var titleName:   String = "Unknown Title"
        var imports: [LoadedXEX.ImportInfo] = []

        for _ in 0..<optHeaderCount {
            let key  = try reader.readUInt32BE()
            let data_or_offset = try reader.readUInt32BE()

            let lowByte = key & 0xFF
            if lowByte == 1 {
                // data_or_offset IS the value
                switch XEXOptionalHeader(rawValue: key) {
                case .originalBaseAddr:
                    baseAddress = data_or_offset
                case .entryPoint:
                    entryPoint = UInt64(data_or_offset)
                case .defaultStackSize:
                    stackSize = data_or_offset
                default: break
                }
            } else if lowByte == 0 {
                // data_or_offset is a value packed in the word
                if XEXOptionalHeader(rawValue: key) == .imageBaseAddr {
                    baseAddress = data_or_offset
                }
            } else {
                // data_or_offset is an offset to a struct in the header
                let savedPos = reader.position
                if data_or_offset < UInt32(reader.data.count) {
                    reader.seek(to: Int(data_or_offset))
                    switch XEXOptionalHeader(rawValue: key) {
                    case .executionInfo:
                        titleID    = try reader.readUInt32BE() // mediaID
                        _          = try reader.readUInt32BE() // version
                        _          = try reader.readUInt32BE() // baseVersion
                        titleID    = try reader.readUInt32BE() // titleID
                    case .originalPEName:
                        let strLen = Int(try reader.readUInt32BE())
                        if let name = reader.readString(length: strLen) {
                            titleName = name
                        }
                    case .importLibraries:
                        let libs = try parseImportLibraries(reader: reader,
                                                            baseAddress: baseAddress)
                        imports.append(contentsOf: libs)
                    default: break
                    }
                }
                reader.seek(to: savedPos)
            }
        }

        // ── Parse security info / sections ────────────────────────
        reader.seek(to: Int(securityOffset))
        let _secHeaderSize = try reader.readUInt32BE()
        imageSize = try reader.readUInt32BE()
        reader.skip(256)         // RSA signature
        reader.skip(4)           // unknown
        let imageFlags = try reader.readUInt32BE()
        let loadAddress = try reader.readUInt32BE()
        if baseAddress == 0 { baseAddress = loadAddress }
        reader.skip(20)          // section digest
        let _importTableCount = try reader.readUInt32BE()
        reader.skip(20)          // import digest
        reader.skip(16)          // media ID
        reader.skip(16)          // session key
        let exportTable = try reader.readUInt32BE()
        reader.skip(44)          // unknown
        let pageDescCount = try reader.readUInt32BE()

        // Section descriptors follow
        var sectionInfos: [LoadedXEX.SectionInfo] = []
        var currentAddr = baseAddress
        for _ in 0..<pageDescCount {
            let info   = try reader.readUInt32BE()
            reader.skip(20) // digest
            let xexSection = XEX2Section(info: info, digest: Data())
            sectionInfos.append(LoadedXEX.SectionInfo(
                virtualAddress: currentAddr,
                virtualSize:    xexSection.size,
                isExecutable:   xexSection.isExecutable,
                isWritable:     xexSection.isWritable,
                name:           xexSection.isExecutable ? ".text" : ".data"
            ))
            currentAddr += xexSection.size
        }

        // ── Load PE image into memory ─────────────────────────────
        guard Int(peDataOffset) < reader.data.count else {
            throw XEXError.truncatedHeader
        }

        // For unencrypted/undecrypted XEX, load raw PE data
        // (real emulators would AES-decrypt with the session key first)
        let peData = reader.data.subdata(in: Int(peDataOffset)..<reader.data.count)
        let loadAt = baseAddress != 0 ? UInt64(baseAddress) : 0x8000_1000
        memory.loadBytes(peData, at: loadAt)

        // Generate import stubs (blr instructions) for each imported symbol
        for imp in imports {
            let stubAddr = UInt64(imp.address) & 0x1FFF_FFFF
            if stubAddr + 4 < 512 * 1024 * 1024 {
                // Write: blr (0x4E800020) as stub — returns immediately
                memory.write32(UInt64(imp.address), value: 0x4E80_0020)
            }
        }

        if entryPoint == 0 {
            entryPoint = UInt64(baseAddress) + 0x1000
        }

        return LoadedXEX(
            title:        titleName,
            titleID:      titleID,
            entryPoint:   entryPoint,
            baseAddress:  baseAddress,
            imageSize:    imageSize,
            sections:     sectionInfos,
            imports:      imports,
            stackSize:    stackSize
        )
    }

    // MARK: - Import Libraries

    private func parseImportLibraries(reader: BinaryReader,
                                       baseAddress: UInt32) throws -> [LoadedXEX.ImportInfo] {
        var results: [LoadedXEX.ImportInfo] = []
        let headerSize = try reader.readUInt32BE()
        reader.skip(16)  // id
        reader.skip(4)   // version min
        reader.skip(4)   // version max
        let nameTableSize  = try reader.readUInt32BE()
        let numImports     = try reader.readUInt32BE()

        // Skip name table
        reader.skip(Int(nameTableSize))

        for _ in 0..<numImports {
            let addr    = try reader.readUInt32BE()
            let ordinal = addr & 0xFFFF
            let libName = "xboxkrnl.exe"
            let resolved = Self.kernelExports[ordinal]
            results.append(LoadedXEX.ImportInfo(
                library: libName,
                ordinal: ordinal,
                address: addr,
                resolvedName: resolved
            ))
        }
        return results
    }
}

// MARK: - Binary Reader (big-endian)

private class BinaryReader {
    let data: Data
    private(set) var position: Int = 0

    init(data: Data) { self.data = data }

    func seek(to pos: Int) { position = pos }

    func skip(_ n: Int) { position += n }

    @discardableResult
    func readUInt32BE() throws -> UInt32 {
        guard position + 4 <= data.count else { throw XEXError.truncatedHeader }
        let b0 = UInt32(data[position])
        let b1 = UInt32(data[position + 1])
        let b2 = UInt32(data[position + 2])
        let b3 = UInt32(data[position + 3])
        position += 4
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    func readUInt16BE() throws -> UInt16 {
        guard position + 2 <= data.count else { throw XEXError.truncatedHeader }
        let b0 = UInt16(data[position])
        let b1 = UInt16(data[position + 1])
        position += 2
        return (b0 << 8) | b1
    }

    func readUInt8() throws -> UInt8 {
        guard position < data.count else { throw XEXError.truncatedHeader }
        defer { position += 1 }
        return data[position]
    }

    func readString(length: Int) -> String? {
        guard position + length <= data.count else { return nil }
        let strData = data.subdata(in: position..<(position + length))
        position += length
        return String(data: strData, encoding: .ascii)?
            .trimmingCharacters(in: .controlCharacters)
    }

    func readBytes(_ n: Int) -> Data? {
        guard position + n <= data.count else { return nil }
        let result = data.subdata(in: position..<(position + n))
        position += n
        return result
    }
}
