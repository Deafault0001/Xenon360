// XenonCPU.swift
// Xenon360 — JIT-less Xbox 360 Emulator
//
// Emulates the IBM Xenon CPU: 3 cores × 2 hardware threads (VMX/AltiVec)
// Pure interpreter — no JIT, fully compatible with iOS/iPadOS sandbox.
// All instructions are decoded and executed in Swift.

import Foundation

// MARK: - Condition Register

struct ConditionRegister {
    var value: UInt32 = 0

    /// CR field n (each field is 4 bits: LT GT EQ SO)
    subscript(field: Int) -> UInt8 {
        get { UInt8((value >> (28 - field * 4)) & 0xF) }
        set {
            let shift = 28 - field * 4
            value = (value & ~(0xF << shift)) | (UInt32(newValue & 0xF) << shift)
        }
    }

    var lt: Bool { (self[0] & 0b1000) != 0 }
    var gt: Bool { (self[0] & 0b0100) != 0 }
    var eq: Bool { (self[0] & 0b0010) != 0 }
    var so: Bool { (self[0] & 0b0001) != 0 }

    mutating func set(field: Int, lt: Bool, gt: Bool, eq: Bool, so: Bool) {
        let bits: UInt8 = (lt ? 0b1000 : 0)
                        | (gt ? 0b0100 : 0)
                        | (eq ? 0b0010 : 0)
                        | (so ? 0b0001 : 0)
        self[field] = bits
    }
}

// MARK: - XER (Fixed-Point Exception Register)

struct XERRegister {
    var raw: UInt64 = 0
    var so: Bool {
        get { (raw >> 63) & 1 == 1 }
        set { raw = newValue ? (raw | (1 << 63)) : (raw & ~(1 << 63)) }
    }
    var ov: Bool {
        get { (raw >> 62) & 1 == 1 }
        set { raw = newValue ? (raw | (1 << 62)) : (raw & ~(1 << 62)) }
    }
    var ca: Bool {
        get { (raw >> 61) & 1 == 1 }
        set { raw = newValue ? (raw | (1 << 61)) : (raw & ~(1 << 61)) }
    }
    var byteCount: UInt8 { UInt8(raw & 0x7F) }
}

// MARK: - VMX (AltiVec) 128-bit Register

struct VMXRegister {
    var lo: UInt64 = 0
    var hi: UInt64 = 0

    var asUInt8s: [UInt8] {
        get {
            var result = [UInt8](repeating: 0, count: 16)
            for i in 0..<8 {
                result[i]     = UInt8((hi >> (56 - i * 8)) & 0xFF)
                result[i + 8] = UInt8((lo >> (56 - i * 8)) & 0xFF)
            }
            return result
        }
    }

    static func zero() -> VMXRegister { VMXRegister(lo: 0, hi: 0) }
}

// MARK: - CPU Thread State

public class XenonThread {
    // General Purpose Registers (64-bit)
    var gpr: [UInt64] = Array(repeating: 0, count: 32)
    // Floating Point Registers
    var fpr: [Double]  = Array(repeating: 0.0, count: 32)
    // VMX / AltiVec Registers (128-bit, emulated as pair of UInt64)
    var vr:  [VMXRegister] = Array(repeating: VMXRegister.zero(), count: 128)

    // Special Purpose Registers
    var pc:   UInt64 = 0x00010000  // Program Counter
    var lr:   UInt64 = 0           // Link Register
    var ctr:  UInt64 = 0           // Count Register
    var cr:   ConditionRegister = ConditionRegister()
    var xer:  XERRegister = XERRegister()
    var fpscr: UInt32 = 0          // Floating-Point Status & Control

    var msr:  UInt64 = 0x9000_0000_0000_0000  // Machine State Register
    var pvr:  UInt32 = 0x0070_0200             // Processor Version Register (Xenon)

    // Thread metadata
    let coreIndex: Int
    let threadIndex: Int
    var isRunning: Bool = false
    var cycleCount: UInt64 = 0
    var instructionsExecuted: UInt64 = 0

    // Stack pointer convenience
    var sp: UInt64 {
        get { gpr[1] }
        set { gpr[1] = newValue }
    }

    init(core: Int, thread: Int) {
        self.coreIndex   = core
        self.threadIndex = thread
    }
}

// MARK: - Instruction Decode Helpers

private struct Instr {
    let raw: UInt32

    var opcode: UInt32 { raw >> 26 }                        // bits[0:5]
    var rD: Int     { Int((raw >> 21) & 0x1F) }            // bits[6:10]
    var rA: Int     { Int((raw >> 16) & 0x1F) }            // bits[11:15]
    var rB: Int     { Int((raw >> 11) & 0x1F) }            // bits[16:20]
    var rC: Int     { Int((raw >> 6)  & 0x1F) }            // bits[21:25]
    var xo31: UInt32 { (raw >> 1) & 0x3FF }                // bits[21:30] extended opcode
    var xo63: UInt32 { (raw >> 1) & 0x1FF }
    var rc: Bool    { (raw & 1) != 0 }                     // Record bit
    var oe: Bool    { (raw >> 10) & 1 == 1 }               // Overflow Enable
    var lk: Bool    { (raw & 1) != 0 }                     // Link bit (branches)
    var aa: Bool    { (raw >> 1) & 1 == 1 }                // Absolute Address

    // Sign-extended immediates
    var simm16: Int64 { Int64(Int16(bitPattern: UInt16(raw & 0xFFFF))) }
    var uimm16: UInt64 { UInt64(raw & 0xFFFF) }

    // Branch targets
    var bd: Int64 {                                         // 14-bit branch displacement
        let disp = Int32(bitPattern: (raw & 0xFFFC))
        return Int64(disp < 32768 ? disp : disp | Int32(bitPattern: 0xFFFF0000))
    }
    var li: Int64 {                                         // 24-bit branch target
        let raw26 = Int32(bitPattern: raw & 0x03FF_FFFC)
        return Int64(raw26 < 0x200_0000 ? raw26 : raw26 | Int32(bitPattern: 0xFC00_0000))
    }

    var bi: Int { Int((raw >> 16) & 0x1F) }                // Branch condition bit
    var bo: UInt32 { (raw >> 21) & 0x1F }                  // Branch options

    // Load/store
    var ds: Int64 { Int64(Int16(bitPattern: UInt16(raw & 0xFFFC))) }
}

// MARK: - Exception Types

enum XenonException: Error {
    case illegalInstruction(pc: UInt64, raw: UInt32)
    case memoryFault(addr: UInt64, write: Bool)
    case systemCall(index: UInt64)
    case haltRequested
    case unimplementedOpcode(opcode: UInt32, xo: UInt32)
}

// MARK: - CPU Core Interpreter

public class XenonCPU {
    public let memory: XenonMemory
    var threads: [[XenonThread]]    // [core][thread]
    var activeThread: XenonThread

    // Execution stats
    public private(set) var totalInstructions: UInt64 = 0
    public private(set) var totalCycles: UInt64 = 0

    // Syscall handler
    var syscallHandler: ((XenonThread, UInt64) -> Void)?

    public init(memory: XenonMemory) {
        self.memory = memory
        // 3 cores × 2 threads
        self.threads = (0..<3).map { core in
            (0..<2).map { thread in XenonThread(core: core, thread: thread) }
        }
        self.activeThread = threads[0][0]
    }

    // MARK: - Step (single instruction)

    @discardableResult
    public func step() throws -> Int {
        let t = activeThread
        let rawPC = t.pc

        // Fetch — Xbox 360 is big-endian
        guard rawPC < UInt64(memory.ram.count) - 3 else {
            throw XenonException.memoryFault(addr: rawPC, write: false)
        }
        let raw = memory.read32(rawPC)
        let instr = Instr(raw: raw)

        t.pc &+= 4
        t.cycleCount &+= 1
        t.instructionsExecuted &+= 1
        totalInstructions &+= 1

        try decode(instr, thread: t)

        return 1
    }

    // MARK: - Run burst (n instructions)

    public func runBurst(_ count: Int, thread: XenonThread) throws {
        let saved = activeThread
        activeThread = thread
        defer { activeThread = saved }
        for _ in 0..<count {
            try step()
        }
    }

    // MARK: - Top-level decoder

    private func decode(_ i: Instr, thread t: XenonThread) throws {
        switch i.opcode {

        // ── Integer Arithmetic ─────────────────────────────────────

        case 14:  // addi  rD, rA, SIMM  (if rA==0, rD = SIMM)
            t.gpr[i.rD] = i.rA == 0
                ? UInt64(bitPattern: i.simm16)
                : t.gpr[i.rA] &+ UInt64(bitPattern: i.simm16)

        case 15:  // addis rD, rA, SIMM
            let imm = i.simm16 << 16
            t.gpr[i.rD] = i.rA == 0
                ? UInt64(bitPattern: imm)
                : t.gpr[i.rA] &+ UInt64(bitPattern: imm)

        case 12:  // addic rD, rA, SIMM  (sets carry)
            let (result, carry) = t.gpr[i.rA].addingReportingOverflow(UInt64(bitPattern: i.simm16))
            t.gpr[i.rD] = result
            t.xer.ca = carry

        case 13:  // addic. (addic + CR0 update)
            let (result, carry) = t.gpr[i.rA].addingReportingOverflow(UInt64(bitPattern: i.simm16))
            t.gpr[i.rD] = result
            t.xer.ca = carry
            updateCR0(t, value: result)

        case 8:   // subfic rD, rA, SIMM
            let (result, carry) = (~t.gpr[i.rA]).addingReportingOverflow(UInt64(bitPattern: i.simm16) &+ 1)
            t.gpr[i.rD] = result
            t.xer.ca = carry

        // ── Logical Immediates ────────────────────────────────────

        case 24:  // ori   rA, rS, UIMM
            t.gpr[i.rA] = t.gpr[i.rD] | i.uimm16

        case 25:  // oris  rA, rS, UIMM
            t.gpr[i.rA] = t.gpr[i.rD] | (i.uimm16 << 16)

        case 26:  // xori  rA, rS, UIMM
            t.gpr[i.rA] = t.gpr[i.rD] ^ i.uimm16

        case 27:  // xoris rA, rS, UIMM
            t.gpr[i.rA] = t.gpr[i.rD] ^ (i.uimm16 << 16)

        case 28:  // andi. rA, rS, UIMM  (always sets CR0)
            let result = t.gpr[i.rD] & i.uimm16
            t.gpr[i.rA] = result
            updateCR0(t, value: result)

        case 29:  // andis. rA, rS, UIMM
            let result = t.gpr[i.rD] & (i.uimm16 << 16)
            t.gpr[i.rA] = result
            updateCR0(t, value: result)

        // ── Comparisons ───────────────────────────────────────────

        case 11:  // cmpi  crf, L, rA, SIMM
            let crfNum = i.rD >> 2
            let a = Int64(bitPattern: t.gpr[i.rA])
            let b = i.simm16
            t.cr.set(field: crfNum,
                     lt: a < b, gt: a > b, eq: a == b, so: t.xer.so)

        case 10:  // cmpli crf, L, rA, UIMM
            let crfNum = i.rD >> 2
            let a = t.gpr[i.rA]
            let b = i.uimm16
            t.cr.set(field: crfNum,
                     lt: a < b, gt: a > b, eq: a == b, so: t.xer.so)

        // ── Branches ──────────────────────────────────────────────

        case 18:  // b / ba / bl / bla
            let target: UInt64 = i.aa
                ? UInt64(bitPattern: i.li)
                : UInt64(bitPattern: Int64(bitPattern: t.pc) - 4 + i.li)
            if i.lk { t.lr = t.pc }
            t.pc = target

        case 16:  // bc / bca / bcl / bcla
            let target: UInt64 = i.aa
                ? UInt64(bitPattern: i.bd)
                : UInt64(bitPattern: Int64(bitPattern: t.pc) - 4 + i.bd)
            if i.lk { t.lr = t.pc }
            if evaluateBranchCondition(i, thread: t) {
                t.pc = target
            }

        case 19:  // bclr, bcctr, etc.
            try decodeOpcode19(i, thread: t)

        // ── Loads ─────────────────────────────────────────────────

        case 34:  // lbz  rD, d(rA)
            let ea = effectiveAddress(i, thread: t)
            t.gpr[i.rD] = UInt64(memory.read8(ea))

        case 35:  // lbzu rD, d(rA)  (update)
            let ea = effectiveAddress(i, thread: t)
            t.gpr[i.rD] = UInt64(memory.read8(ea))
            t.gpr[i.rA] = ea

        case 40:  // lhz  rD, d(rA)
            let ea = effectiveAddress(i, thread: t)
            t.gpr[i.rD] = UInt64(memory.read16(ea))

        case 42:  // lha  rD, d(rA)  (sign-extend)
            let ea = effectiveAddress(i, thread: t)
            t.gpr[i.rD] = UInt64(bitPattern: Int64(Int16(bitPattern: memory.read16(ea))))

        case 32:  // lwz  rD, d(rA)
            let ea = effectiveAddress(i, thread: t)
            t.gpr[i.rD] = UInt64(memory.read32(ea))

        case 33:  // lwzu rD, d(rA)
            let ea = effectiveAddress(i, thread: t)
            t.gpr[i.rD] = UInt64(memory.read32(ea))
            t.gpr[i.rA] = ea

        case 58:  // ld / ldu / lwa
            let ds = i.ds
            let ea = i.rA == 0 ? UInt64(bitPattern: ds) : t.gpr[i.rA] &+ UInt64(bitPattern: ds)
            switch i.raw & 0x3 {
            case 0: t.gpr[i.rD] = memory.read64(ea)          // ld
            case 1:                                            // ldu
                t.gpr[i.rD] = memory.read64(ea)
                t.gpr[i.rA] = ea
            case 2:                                            // lwa
                t.gpr[i.rD] = UInt64(bitPattern: Int64(Int32(bitPattern: memory.read32(ea))))
            default: throw XenonException.illegalInstruction(pc: t.pc - 4, raw: i.raw)
            }

        case 48:  // lfs  (load float single)
            let ea = effectiveAddress(i, thread: t)
            let bits = memory.read32(ea)
            t.fpr[i.rD] = Double(Float(bitPattern: bits))

        case 50:  // lfd  (load float double)
            let ea = effectiveAddress(i, thread: t)
            let bits = memory.read64(ea)
            t.fpr[i.rD] = Double(bitPattern: bits)

        // ── Stores ────────────────────────────────────────────────

        case 38:  // stb  rS, d(rA)
            let ea = effectiveAddress(i, thread: t)
            memory.write8(ea, value: UInt8(t.gpr[i.rD] & 0xFF))

        case 39:  // stbu
            let ea = effectiveAddress(i, thread: t)
            memory.write8(ea, value: UInt8(t.gpr[i.rD] & 0xFF))
            t.gpr[i.rA] = ea

        case 44:  // sth  rS, d(rA)
            let ea = effectiveAddress(i, thread: t)
            memory.write16(ea, value: UInt16(t.gpr[i.rD] & 0xFFFF))

        case 36:  // stw  rS, d(rA)
            let ea = effectiveAddress(i, thread: t)
            memory.write32(ea, value: UInt32(t.gpr[i.rD] & 0xFFFF_FFFF))

        case 37:  // stwu
            let ea = effectiveAddress(i, thread: t)
            memory.write32(ea, value: UInt32(t.gpr[i.rD] & 0xFFFF_FFFF))
            t.gpr[i.rA] = ea

        case 62:  // std / stdu
            let ds = i.ds
            let ea = i.rA == 0 ? UInt64(bitPattern: ds) : t.gpr[i.rA] &+ UInt64(bitPattern: ds)
            memory.write64(ea, value: t.gpr[i.rD])
            if (i.raw & 0x3) == 1 { t.gpr[i.rA] = ea }       // stdu

        case 52:  // stfs
            let ea = effectiveAddress(i, thread: t)
            let f32 = Float(t.fpr[i.rD])
            memory.write32(ea, value: f32.bitPattern)

        case 54:  // stfd
            let ea = effectiveAddress(i, thread: t)
            memory.write64(ea, value: t.fpr[i.rD].bitPattern)

        // ── Rotate / Shift ────────────────────────────────────────

        case 20:  // rlwimi rA, rS, SH, MB, ME
            let sh = Int((i.raw >> 11) & 0x1F)
            let mb = Int((i.raw >> 6)  & 0x1F)
            let me = Int((i.raw >> 1)  & 0x1F)
            let rotated = rotl32(UInt32(t.gpr[i.rD] & 0xFFFF_FFFF), by: sh)
            let mask = maskPPC(mb: mb, me: me)
            t.gpr[i.rA] = UInt64((rotated & mask) | (UInt32(t.gpr[i.rA]) & ~mask))
            if i.rc { updateCR0(t, value: t.gpr[i.rA]) }

        case 21:  // rlwinm rA, rS, SH, MB, ME
            let sh = Int((i.raw >> 11) & 0x1F)
            let mb = Int((i.raw >> 6)  & 0x1F)
            let me = Int((i.raw >> 1)  & 0x1F)
            let rotated = rotl32(UInt32(t.gpr[i.rD] & 0xFFFF_FFFF), by: sh)
            t.gpr[i.rA] = UInt64(rotated & maskPPC(mb: mb, me: me))
            if i.rc { updateCR0(t, value: t.gpr[i.rA]) }

        case 23:  // rlwnm rA, rS, rB, MB, ME
            let sh = Int(t.gpr[i.rB] & 0x1F)
            let mb = Int((i.raw >> 6) & 0x1F)
            let me = Int((i.raw >> 1) & 0x1F)
            let rotated = rotl32(UInt32(t.gpr[i.rD] & 0xFFFF_FFFF), by: sh)
            t.gpr[i.rA] = UInt64(rotated & maskPPC(mb: mb, me: me))
            if i.rc { updateCR0(t, value: t.gpr[i.rA]) }

        case 30:  // 64-bit rotate (rldic, rldicl, rldicr, rldcl, etc.)
            try decodeOpcode30(i, thread: t)

        // ── Integer Register-Register (opcode 31) ─────────────────

        case 31:
            try decodeOpcode31(i, thread: t)

        // ── Floating Point (opcode 63, 59) ────────────────────────

        case 63:
            try decodeOpcode63(i, thread: t)

        case 59:
            try decodeOpcode59(i, thread: t)

        // ── VMX (opcode 4) ────────────────────────────────────────

        case 4:
            try decodeVMX(i, thread: t)

        // ── System Call ───────────────────────────────────────────

        case 17:  // sc
            let idx = t.gpr[0]
            if let handler = syscallHandler {
                handler(t, idx)
            } else {
                throw XenonException.systemCall(index: idx)
            }

        // ── NOP (ori 0,0,0) ───────────────────────────────────────

        case 0:
            break // nop / trap area

        default:
            throw XenonException.unimplementedOpcode(opcode: i.opcode, xo: i.xo31)
        }
    }

    // MARK: - Opcode 19 (Branch variants)

    private func decodeOpcode19(_ i: Instr, thread t: XenonThread) throws {
        switch i.xo31 {
        case 16:  // bclr / bclrl
            if evaluateBranchCondition(i, thread: t) {
                let target = t.lr & ~1
                if i.lk { t.lr = t.pc }
                t.pc = target
            } else if i.lk {
                t.lr = t.pc
            }

        case 528: // bcctr / bcctrl
            if evaluateBranchCondition(i, thread: t) {
                let target = t.ctr & ~1
                if i.lk { t.lr = t.pc }
                t.pc = target
            }

        case 0:   // mcrf  crf, crfS
            let dst = (i.rD >> 2) & 0x7
            let src = (i.rA >> 2) & 0x7
            t.cr[dst] = t.cr[src]

        case 33:  // crnor
            let bit = crBitOp(i, t) { !($0 || $1) }
            setCRBit(t, bit: i.rD, value: bit)

        case 129: // crandc
            let bit = crBitOp(i, t) { $0 && !$1 }
            setCRBit(t, bit: i.rD, value: bit)

        case 193: // crxor
            let bit = crBitOp(i, t) { $0 != $1 }
            setCRBit(t, bit: i.rD, value: bit)

        case 225: // crnand
            let bit = crBitOp(i, t) { !($0 && $1) }
            setCRBit(t, bit: i.rD, value: bit)

        case 257: // crand
            let bit = crBitOp(i, t) { $0 && $1 }
            setCRBit(t, bit: i.rD, value: bit)

        case 289: // creqv
            let bit = crBitOp(i, t) { $0 == $1 }
            setCRBit(t, bit: i.rD, value: bit)

        case 417: // crorc
            let bit = crBitOp(i, t) { $0 || !$1 }
            setCRBit(t, bit: i.rD, value: bit)

        case 449: // cror
            let bit = crBitOp(i, t) { $0 || $1 }
            setCRBit(t, bit: i.rD, value: bit)

        case 150: // isync
            break // instruction synchronize (no-op in interpreter)

        default:
            throw XenonException.unimplementedOpcode(opcode: 19, xo: i.xo31)
        }
    }

    // MARK: - Opcode 30 (64-bit Rotate)

    private func decodeOpcode30(_ i: Instr, thread t: XenonThread) throws {
        let sh = Int(((i.raw >> 11) & 0x1F) | (((i.raw >> 1) & 1) << 5))
        let mb = Int(((i.raw >> 6)  & 0x1F) | ((i.raw & 0x20)))
        let xo = (i.raw >> 2) & 0x7

        switch xo {
        case 0: // rldicl rA, rS, sh, mb
            let rot = rotl64(t.gpr[i.rD], by: sh)
            t.gpr[i.rA] = rot & mask64(mb: mb, me: 63)
            if i.rc { updateCR0(t, value: t.gpr[i.rA]) }

        case 1: // rldicr rA, rS, sh, me
            let me = mb  // field repurposed as ME
            let rot = rotl64(t.gpr[i.rD], by: sh)
            t.gpr[i.rA] = rot & mask64(mb: 0, me: me)
            if i.rc { updateCR0(t, value: t.gpr[i.rA]) }

        case 2: // rldic rA, rS, sh, mb
            let rot = rotl64(t.gpr[i.rD], by: sh)
            t.gpr[i.rA] = rot & mask64(mb: mb, me: 63 - sh)
            if i.rc { updateCR0(t, value: t.gpr[i.rA]) }

        case 3: // rldimi rA, rS, sh, mb
            let rot = rotl64(t.gpr[i.rD], by: sh)
            let m   = mask64(mb: mb, me: 63 - sh)
            t.gpr[i.rA] = (rot & m) | (t.gpr[i.rA] & ~m)
            if i.rc { updateCR0(t, value: t.gpr[i.rA]) }

        case 4, 5: // rldcl / rldcr
            let shR = Int(t.gpr[i.rB] & 0x3F)
            let rot = rotl64(t.gpr[i.rD], by: shR)
            let m = xo == 4 ? mask64(mb: mb, me: 63) : mask64(mb: 0, me: mb)
            t.gpr[i.rA] = rot & m
            if i.rc { updateCR0(t, value: t.gpr[i.rA]) }

        default:
            throw XenonException.unimplementedOpcode(opcode: 30, xo: UInt32(xo))
        }
    }

    // MARK: - Opcode 31 (Integer register-register)

    private func decodeOpcode31(_ i: Instr, thread t: XenonThread) throws {
        switch i.xo31 {

        // Arithmetic
        case 266:  // add
            let (r, ov) = t.gpr[i.rA].addingReportingOverflow(t.gpr[i.rB])
            t.gpr[i.rD] = r
            if i.oe { updateOV(t, overflow: ov) }
            if i.rc { updateCR0(t, value: r) }

        case 8:    // subfc
            let (r, ca) = (~t.gpr[i.rA]).addingReportingOverflow(t.gpr[i.rB] &+ 1)
            t.gpr[i.rD] = r
            t.xer.ca = ca
            if i.oe { updateOV(t, overflow: ca) }
            if i.rc { updateCR0(t, value: r) }

        case 40:   // subf
            let r = t.gpr[i.rB] &- t.gpr[i.rA]
            t.gpr[i.rD] = r
            if i.rc { updateCR0(t, value: r) }

        case 104:  // neg
            let r = (~t.gpr[i.rA]) &+ 1
            t.gpr[i.rD] = r
            if i.rc { updateCR0(t, value: r) }

        case 138:  // adde
            let ca: UInt64 = t.xer.ca ? 1 : 0
            let (r1, ov1) = t.gpr[i.rA].addingReportingOverflow(t.gpr[i.rB])
            let (r2, ov2) = r1.addingReportingOverflow(ca)
            t.gpr[i.rD] = r2
            t.xer.ca = ov1 || ov2
            if i.rc { updateCR0(t, value: r2) }

        case 234:  // addme
            let ca: UInt64 = t.xer.ca ? 1 : 0
            let (r, ov) = t.gpr[i.rA].addingReportingOverflow(ca &- 1)
            t.gpr[i.rD] = r
            t.xer.ca = ov
            if i.rc { updateCR0(t, value: r) }

        case 200:  // subfme
            let ca: UInt64 = t.xer.ca ? 1 : 0
            let r = (~t.gpr[i.rA]) &+ ca &- 1
            t.gpr[i.rD] = r
            if i.rc { updateCR0(t, value: r) }

        case 232:  // addze
            let ca: UInt64 = t.xer.ca ? 1 : 0
            let (r, ov) = t.gpr[i.rA].addingReportingOverflow(ca)
            t.gpr[i.rD] = r
            t.xer.ca = ov
            if i.rc { updateCR0(t, value: r) }

        // Multiply / Divide
        case 235:  // mullw
            let a = Int64(Int32(bitPattern: UInt32(t.gpr[i.rA] & 0xFFFF_FFFF)))
            let b = Int64(Int32(bitPattern: UInt32(t.gpr[i.rB] & 0xFFFF_FFFF)))
            t.gpr[i.rD] = UInt64(bitPattern: a * b)
            if i.rc { updateCR0(t, value: t.gpr[i.rD]) }

        case 233:  // mulld
            let a = Int64(bitPattern: t.gpr[i.rA])
            let b = Int64(bitPattern: t.gpr[i.rB])
            t.gpr[i.rD] = UInt64(bitPattern: a &* b)
            if i.rc { updateCR0(t, value: t.gpr[i.rD]) }

        case 75:   // mulhw
            let a = Int64(Int32(bitPattern: UInt32(t.gpr[i.rA])))
            let b = Int64(Int32(bitPattern: UInt32(t.gpr[i.rB])))
            let hi = (a * b) >> 32
            t.gpr[i.rD] = UInt64(bitPattern: Int64(Int32(hi)))
            if i.rc { updateCR0(t, value: t.gpr[i.rD]) }

        case 73:   // mulhd
            // 128-bit multiply high — compute via 64-bit parts
            let (hi, _) = t.gpr[i.rA].multipliedFullWidth(by: t.gpr[i.rB])
            t.gpr[i.rD] = hi
            if i.rc { updateCR0(t, value: hi) }

        case 491:  // divw
            let a = Int32(bitPattern: UInt32(t.gpr[i.rA]))
            let b = Int32(bitPattern: UInt32(t.gpr[i.rB]))
            guard b != 0 else { t.gpr[i.rD] = 0; break }
            t.gpr[i.rD] = UInt64(bitPattern: Int64(a / b))
            if i.rc { updateCR0(t, value: t.gpr[i.rD]) }

        case 489:  // divd
            let a = Int64(bitPattern: t.gpr[i.rA])
            let b = Int64(bitPattern: t.gpr[i.rB])
            guard b != 0 else { t.gpr[i.rD] = 0; break }
            t.gpr[i.rD] = UInt64(bitPattern: a / b)
            if i.rc { updateCR0(t, value: t.gpr[i.rD]) }

        case 459:  // divwu
            let b = UInt32(t.gpr[i.rB] & 0xFFFF_FFFF)
            guard b != 0 else { t.gpr[i.rD] = 0; break }
            t.gpr[i.rD] = UInt64(UInt32(t.gpr[i.rA]) / b)
            if i.rc { updateCR0(t, value: t.gpr[i.rD]) }

        case 457:  // divdu
            guard t.gpr[i.rB] != 0 else { t.gpr[i.rD] = 0; break }
            t.gpr[i.rD] = t.gpr[i.rA] / t.gpr[i.rB]
            if i.rc { updateCR0(t, value: t.gpr[i.rD]) }

        // Logical
        case 28:   // and
            let r = t.gpr[i.rA] & t.gpr[i.rB]
            t.gpr[i.rD] = r
            if i.rc { updateCR0(t, value: r) }

        case 60:   // andc
            let r = t.gpr[i.rA] & ~t.gpr[i.rB]
            t.gpr[i.rD] = r
            if i.rc { updateCR0(t, value: r) }

        case 444:  // or
            let r = t.gpr[i.rA] | t.gpr[i.rB]
            t.gpr[i.rD] = r
            if i.rc { updateCR0(t, value: r) }

        case 412:  // orc
            let r = t.gpr[i.rA] | ~t.gpr[i.rB]
            t.gpr[i.rD] = r
            if i.rc { updateCR0(t, value: r) }

        case 316:  // xor
            let r = t.gpr[i.rA] ^ t.gpr[i.rB]
            t.gpr[i.rD] = r
            if i.rc { updateCR0(t, value: r) }

        case 476:  // nand
            let r = ~(t.gpr[i.rA] & t.gpr[i.rB])
            t.gpr[i.rD] = r
            if i.rc { updateCR0(t, value: r) }

        case 124:  // nor
            let r = ~(t.gpr[i.rA] | t.gpr[i.rB])
            t.gpr[i.rD] = r
            if i.rc { updateCR0(t, value: r) }

        case 954:  // extsb
            t.gpr[i.rA] = UInt64(bitPattern: Int64(Int8(bitPattern: UInt8(t.gpr[i.rD] & 0xFF))))
            if i.rc { updateCR0(t, value: t.gpr[i.rA]) }

        case 922:  // extsh
            t.gpr[i.rA] = UInt64(bitPattern: Int64(Int16(bitPattern: UInt16(t.gpr[i.rD] & 0xFFFF))))
            if i.rc { updateCR0(t, value: t.gpr[i.rA]) }

        case 986:  // extsw
            t.gpr[i.rA] = UInt64(bitPattern: Int64(Int32(bitPattern: UInt32(t.gpr[i.rD]))))
            if i.rc { updateCR0(t, value: t.gpr[i.rA]) }

        // Shifts
        case 24:   // slw
            let sh = t.gpr[i.rB] & 0x3F
            t.gpr[i.rA] = sh < 32 ? UInt64(UInt32(t.gpr[i.rD]) << sh) : 0
            if i.rc { updateCR0(t, value: t.gpr[i.rA]) }

        case 536:  // srw
            let sh = t.gpr[i.rB] & 0x3F
            t.gpr[i.rA] = sh < 32 ? UInt64(UInt32(t.gpr[i.rD]) >> sh) : 0
            if i.rc { updateCR0(t, value: t.gpr[i.rA]) }

        case 792:  // sraw
            let sh = Int(t.gpr[i.rB] & 0x3F)
            let src = Int32(bitPattern: UInt32(t.gpr[i.rD]))
            let result: Int32 = sh < 32 ? src >> sh : (src < 0 ? -1 : 0)
            t.gpr[i.rA] = UInt64(bitPattern: Int64(result))
            t.xer.ca = src < 0 && (sh < 32 ? (src << (32 - sh)) != 0 : src != 0)
            if i.rc { updateCR0(t, value: t.gpr[i.rA]) }

        case 27:   // sld
            let sh = t.gpr[i.rB] & 0x7F
            t.gpr[i.rA] = sh < 64 ? t.gpr[i.rD] << sh : 0
            if i.rc { updateCR0(t, value: t.gpr[i.rA]) }

        case 539:  // srd
            let sh = t.gpr[i.rB] & 0x7F
            t.gpr[i.rA] = sh < 64 ? t.gpr[i.rD] >> sh : 0
            if i.rc { updateCR0(t, value: t.gpr[i.rA]) }

        case 794:  // srad
            let sh = Int(t.gpr[i.rB] & 0x7F)
            let src = Int64(bitPattern: t.gpr[i.rD])
            let result = sh < 64 ? src >> sh : (src < 0 ? -1 : 0)
            t.gpr[i.rA] = UInt64(bitPattern: result)
            t.xer.ca = src < 0 && result != src
            if i.rc { updateCR0(t, value: t.gpr[i.rA]) }

        // Compare
        case 0:    // cmp crfD, L, rA, rB
            let crfNum = i.rD >> 2
            let a = Int64(bitPattern: t.gpr[i.rA])
            let b = Int64(bitPattern: t.gpr[i.rB])
            t.cr.set(field: crfNum, lt: a < b, gt: a > b, eq: a == b, so: t.xer.so)

        case 32:   // cmpl crfD, L, rA, rB
            let crfNum = i.rD >> 2
            let a = t.gpr[i.rA], b = t.gpr[i.rB]
            t.cr.set(field: crfNum, lt: a < b, gt: a > b, eq: a == b, so: t.xer.so)

        // Move SPR
        case 339:  // mfspr
            let spr = ((i.raw >> 16) & 0x1F) | (((i.raw >> 11) & 0x1F) << 5)
            t.gpr[i.rD] = readSPR(spr, thread: t)

        case 467:  // mtspr
            let spr = ((i.raw >> 16) & 0x1F) | (((i.raw >> 11) & 0x1F) << 5)
            writeSPR(spr, value: t.gpr[i.rD], thread: t)

        case 19:   // mfcr
            t.gpr[i.rD] = UInt64(t.cr.value)

        case 144:  // mtcrf
            let fxm = UInt32((i.raw >> 12) & 0xFF)
            var mask: UInt32 = 0
            for bit in 0..<8 {
                if (fxm >> (7 - bit)) & 1 == 1 {
                    mask |= 0xF << (28 - bit * 4)
                }
            }
            t.cr.value = (t.cr.value & ~mask) | (UInt32(t.gpr[i.rD]) & mask)

        // Load/Store indexed
        case 87:   // lbzx
            let ea = indexedEA(i, thread: t)
            t.gpr[i.rD] = UInt64(memory.read8(ea))

        case 279:  // lhzx
            let ea = indexedEA(i, thread: t)
            t.gpr[i.rD] = UInt64(memory.read16(ea))

        case 343:  // lhax
            let ea = indexedEA(i, thread: t)
            t.gpr[i.rD] = UInt64(bitPattern: Int64(Int16(bitPattern: memory.read16(ea))))

        case 23:   // lwzx
            let ea = indexedEA(i, thread: t)
            t.gpr[i.rD] = UInt64(memory.read32(ea))

        case 21:   // ldx
            let ea = indexedEA(i, thread: t)
            t.gpr[i.rD] = memory.read64(ea)

        case 215:  // stbx
            let ea = indexedEA(i, thread: t)
            memory.write8(ea, value: UInt8(t.gpr[i.rD] & 0xFF))

        case 407:  // sthx
            let ea = indexedEA(i, thread: t)
            memory.write16(ea, value: UInt16(t.gpr[i.rD] & 0xFFFF))

        case 151:  // stwx
            let ea = indexedEA(i, thread: t)
            memory.write32(ea, value: UInt32(t.gpr[i.rD]))

        case 149:  // stdx
            let ea = indexedEA(i, thread: t)
            memory.write64(ea, value: t.gpr[i.rD])

        // Count Leading Zeros
        case 26:   // cntlzw
            let v = UInt32(t.gpr[i.rD] & 0xFFFF_FFFF)
            t.gpr[i.rA] = v == 0 ? 32 : UInt64(v.leadingZeroBitCount)
            if i.rc { updateCR0(t, value: t.gpr[i.rA]) }

        case 58:   // cntlzd
            let v = t.gpr[i.rD]
            t.gpr[i.rA] = v == 0 ? 64 : UInt64(v.leadingZeroBitCount)
            if i.rc { updateCR0(t, value: t.gpr[i.rA]) }

        // Byte-reverse
        case 790:  // lhbrx
            let ea = indexedEA(i, thread: t)
            t.gpr[i.rD] = UInt64(memory.read16(ea).byteSwapped)

        case 534:  // lwbrx
            let ea = indexedEA(i, thread: t)
            t.gpr[i.rD] = UInt64(memory.read32(ea).byteSwapped)

        case 918:  // sthbrx
            let ea = indexedEA(i, thread: t)
            memory.write16(ea, value: UInt16(t.gpr[i.rD] & 0xFFFF).byteSwapped)

        case 662:  // stwbrx
            let ea = indexedEA(i, thread: t)
            memory.write32(ea, value: UInt32(t.gpr[i.rD]).byteSwapped)

        // Sync / barriers
        case 598:  break   // sync / msync
        case 854:  break   // eieio
        case 246:  break   // dcbtst
        case 278:  break   // dcbt
        case 1014: break   // dcbz (zero cache block – skip for now)

        // Trap
        case 68:   // td (trap doubleword)
            break  // Check TO field; for now ignore

        case 4:    // tw (trap word)
            break

        default:
            throw XenonException.unimplementedOpcode(opcode: 31, xo: i.xo31)
        }
    }

    // MARK: - Opcode 63 (Double FP)

    private func decodeOpcode63(_ i: Instr, thread t: XenonThread) throws {
        switch i.xo63 {
        case 0:    // fcmpu
            let crfNum = i.rD >> 2
            let a = t.fpr[i.rA], b = t.fpr[i.rB]
            t.cr.set(field: crfNum, lt: a < b, gt: a > b, eq: a == b, so: false)

        case 12:   // frsp (round to single)
            t.fpr[i.rD] = Double(Float(t.fpr[i.rB]))
            if i.rc { updateFPCR0(t) }

        case 14:   // fctiwz (convert to int word, round to zero)
            let v = Int32(t.fpr[i.rB])
            t.fpr[i.rD] = Double(bitPattern: UInt64(UInt32(bitPattern: v)))

        case 15:   // fctiwuz
            let v = UInt32(max(0.0, t.fpr[i.rB]))
            t.fpr[i.rD] = Double(bitPattern: UInt64(v))

        case 18:   // fdiv
            t.fpr[i.rD] = t.fpr[i.rA] / t.fpr[i.rB]
            if i.rc { updateFPCR0(t) }

        case 20:   // fsub
            t.fpr[i.rD] = t.fpr[i.rA] - t.fpr[i.rB]
            if i.rc { updateFPCR0(t) }

        case 21:   // fadd
            t.fpr[i.rD] = t.fpr[i.rA] + t.fpr[i.rB]
            if i.rc { updateFPCR0(t) }

        case 22:   // fsqrt
            t.fpr[i.rD] = t.fpr[i.rB].squareRoot()
            if i.rc { updateFPCR0(t) }

        case 25:   // fmul
            t.fpr[i.rD] = t.fpr[i.rA] * t.fpr[i.rC]
            if i.rc { updateFPCR0(t) }

        case 26:   // frsqrte
            t.fpr[i.rD] = 1.0 / t.fpr[i.rB].squareRoot()

        case 28:   // fmsub
            t.fpr[i.rD] = (t.fpr[i.rA] * t.fpr[i.rC]) - t.fpr[i.rB]
            if i.rc { updateFPCR0(t) }

        case 29:   // fmadd
            t.fpr[i.rD] = (t.fpr[i.rA] * t.fpr[i.rC]) + t.fpr[i.rB]
            if i.rc { updateFPCR0(t) }

        case 30:   // fnmsub
            t.fpr[i.rD] = -((t.fpr[i.rA] * t.fpr[i.rC]) - t.fpr[i.rB])
            if i.rc { updateFPCR0(t) }

        case 31:   // fnmadd
            t.fpr[i.rD] = -((t.fpr[i.rA] * t.fpr[i.rC]) + t.fpr[i.rB])
            if i.rc { updateFPCR0(t) }

        case 40:   // fneg
            t.fpr[i.rD] = -t.fpr[i.rB]
            if i.rc { updateFPCR0(t) }

        case 72:   // fmr
            t.fpr[i.rD] = t.fpr[i.rB]
            if i.rc { updateFPCR0(t) }

        case 136:  // fnabs
            t.fpr[i.rD] = -abs(t.fpr[i.rB])

        case 264:  // fabs
            t.fpr[i.rD] = abs(t.fpr[i.rB])

        case 583:  // mffs (move from FPSCR)
            t.fpr[i.rD] = Double(bitPattern: UInt64(t.fpscr))

        case 711:  // mtfsf
            t.fpscr = UInt32(t.fpr[i.rB].bitPattern & 0xFFFF_FFFF)

        case 814:  // fctid
            t.fpr[i.rD] = Double(bitPattern: UInt64(bitPattern: Int64(t.fpr[i.rB])))

        case 815:  // fctidz
            t.fpr[i.rD] = Double(bitPattern: UInt64(bitPattern: Int64(t.fpr[i.rB])))

        case 846:  // fcfid
            let i64 = Int64(bitPattern: t.fpr[i.rB].bitPattern)
            t.fpr[i.rD] = Double(i64)

        default:
            throw XenonException.unimplementedOpcode(opcode: 63, xo: i.xo63)
        }
    }

    // MARK: - Opcode 59 (Single FP)

    private func decodeOpcode59(_ i: Instr, thread t: XenonThread) throws {
        switch i.xo63 {
        case 18:   // fdivs
            t.fpr[i.rD] = Double(Float(t.fpr[i.rA]) / Float(t.fpr[i.rB]))
        case 20:   // fsubs
            t.fpr[i.rD] = Double(Float(t.fpr[i.rA]) - Float(t.fpr[i.rB]))
        case 21:   // fadds
            t.fpr[i.rD] = Double(Float(t.fpr[i.rA]) + Float(t.fpr[i.rB]))
        case 22:   // fsqrts
            t.fpr[i.rD] = Double(Float(t.fpr[i.rB]).squareRoot())
        case 25:   // fmuls
            t.fpr[i.rD] = Double(Float(t.fpr[i.rA]) * Float(t.fpr[i.rC]))
        case 28:   // fmsubs
            t.fpr[i.rD] = Double(Float(t.fpr[i.rA]) * Float(t.fpr[i.rC]) - Float(t.fpr[i.rB]))
        case 29:   // fmadds
            t.fpr[i.rD] = Double(Float(t.fpr[i.rA]) * Float(t.fpr[i.rC]) + Float(t.fpr[i.rB]))
        default:
            throw XenonException.unimplementedOpcode(opcode: 59, xo: i.xo63)
        }
    }

    // MARK: - VMX (opcode 4) — subset

    private func decodeVMX(_ i: Instr, thread t: XenonThread) throws {
        let xo = (i.raw >> 0) & 0x7FF
        switch xo {
        case 0x404: // mfvscr
            t.vr[i.rD] = VMXRegister.zero()
        case 0x644: // mtvscr
            break   // ignore
        default:
            // Treat unimplemented VMX as NOP (many are optional for interpreter)
            break
        }
    }

    // MARK: - Helpers

    private func effectiveAddress(_ i: Instr, thread t: XenonThread) -> UInt64 {
        i.rA == 0 ? UInt64(bitPattern: i.simm16) : t.gpr[i.rA] &+ UInt64(bitPattern: i.simm16)
    }

    private func indexedEA(_ i: Instr, thread t: XenonThread) -> UInt64 {
        i.rA == 0 ? t.gpr[i.rB] : t.gpr[i.rA] &+ t.gpr[i.rB]
    }

    private func evaluateBranchCondition(_ i: Instr, thread t: XenonThread) -> Bool {
        let bo = i.bo
        var ctrOK = true
        var condOK = true

        if (bo >> 2) & 1 == 0 {           // decrement CTR
            t.ctr -= 1
            ctrOK = t.ctr != 0 ? ((bo >> 1) & 1 == 0) : ((bo >> 1) & 1 == 1)
        }

        if (bo >> 4) & 1 == 0 {           // test CR bit
            let bit = (t.cr.value >> (31 - i.bi)) & 1
            condOK = (bo >> 3) & 1 == (bit == 1 ? 1 : 0)
        }

        return ctrOK && condOK
    }

    private func updateCR0(_ t: XenonThread, value: UInt64) {
        let signed = Int64(bitPattern: value)
        t.cr.set(field: 0, lt: signed < 0, gt: signed > 0, eq: signed == 0, so: t.xer.so)
    }

    private func updateFPCR0(_ t: XenonThread) {
        // simplified FPSCR update
    }

    private func updateOV(_ t: XenonThread, overflow: Bool) {
        t.xer.ov = overflow
        if overflow { t.xer.so = true }
    }

    private func crBitOp(_ i: Instr, _ t: XenonThread, op: (Bool, Bool) -> Bool) -> Bool {
        let a = (t.cr.value >> (31 - i.rA)) & 1 == 1
        let b = (t.cr.value >> (31 - i.rB)) & 1 == 1
        return op(a, b)
    }

    private func setCRBit(_ t: XenonThread, bit: Int, value: Bool) {
        let shift = 31 - bit
        t.cr.value = value
            ? (t.cr.value | (1 << shift))
            : (t.cr.value & ~(1 << shift))
    }

    private func readSPR(_ spr: Int, thread t: XenonThread) -> UInt64 {
        switch spr {
        case 1:   return t.xer.raw
        case 8:   return t.lr
        case 9:   return t.ctr
        case 287: return UInt64(t.pvr)
        default:  return 0
        }
    }

    private func writeSPR(_ spr: Int, value: UInt64, thread t: XenonThread) {
        switch spr {
        case 1:  t.xer.raw = value
        case 8:  t.lr  = value
        case 9:  t.ctr = value
        default: break
        }
    }

    // MARK: - Rotate / Mask helpers

    private func rotl32(_ v: UInt32, by: Int) -> UInt32 {
        let sh = by & 31
        return sh == 0 ? v : (v << sh) | (v >> (32 - sh))
    }

    private func rotl64(_ v: UInt64, by: Int) -> UInt64 {
        let sh = by & 63
        return sh == 0 ? v : (v << sh) | (v >> (64 - sh))
    }

    private func maskPPC(mb: Int, me: Int) -> UInt32 {
        if mb <= me {
            return mb == 0 && me == 31 ? 0xFFFF_FFFF : ((0xFFFF_FFFF >> mb) & (0xFFFF_FFFF << (31 - me)))
        } else {
            return ~maskPPC(mb: me + 1, me: mb - 1)
        }
    }

    private func mask64(mb: Int, me: Int) -> UInt64 {
        if mb <= me {
            return mb == 0 && me == 63 ? UInt64.max : ((UInt64.max >> mb) & (UInt64.max << (63 - me)))
        } else {
            return ~mask64(mb: me + 1, me: mb - 1)
        }
    }
}
