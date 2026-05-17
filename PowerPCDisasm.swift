// PowerPCDisasm.swift
// Xenon360 — PowerPC Disassembler
//
// Decodes 32-bit PowerPC instructions into human-readable mnemonics.
// Used by the debugger's disassembly panel.

import Foundation

enum PowerPCDisasm {

    // GPR names
    private static let gprNames = (0..<32).map { i -> String in
        switch i {
        case 0:  return "r0"
        case 1:  return "sp"
        case 2:  return "r2"   // TOC
        case 3...10: return "r\(i)"  // argument/return registers
        default: return "r\(i)"
        }
    }

    private static func r(_ n: Int) -> String { gprNames[n & 31] }
    private static func f(_ n: Int) -> String { "f\(n & 31)" }

    static func disassemble(raw: UInt32, pc: UInt64) -> String {
        let opcode = raw >> 26
        let rD = Int((raw >> 21) & 0x1F)
        let rA = Int((raw >> 16) & 0x1F)
        let rB = Int((raw >> 11) & 0x1F)
        let rC = Int((raw >> 6)  & 0x1F)
        let simm = Int32(bitPattern: raw & 0xFFFF)
        let uimm = raw & 0xFFFF
        let rc = (raw & 1) != 0
        let oe = (raw >> 10) & 1 == 1
        let lk = (raw & 1) != 0
        let aa = (raw >> 1) & 1 == 1
        let dot = rc ? "." : ""
        let xo31 = (raw >> 1) & 0x3FF
        let xo63 = (raw >> 1) & 0x1FF

        switch opcode {

        // ── Arithmetic Immediates ─────────────────────────────────

        case 14:
            if rA == 0 { return "li      \(r(rD)), \(simm)" }
            return "addi    \(r(rD)), \(r(rA)), \(simm)"

        case 15:
            if rA == 0 { return String(format: "lis     \(r(rD)), 0x%X", UInt16(bitPattern: Int16(simm))) }
            return String(format: "addis   \(r(rD)), \(r(rA)), 0x%X", UInt16(bitPattern: Int16(simm)))

        case 12: return "addic   \(r(rD)), \(r(rA)), \(simm)"
        case 13: return "addic.  \(r(rD)), \(r(rA)), \(simm)"
        case 8:  return "subfic  \(r(rD)), \(r(rA)), \(simm)"

        // ── Logical Immediates ────────────────────────────────────

        case 24:
            if rD == 0 && rA == 0 && uimm == 0 { return "nop" }
            return String(format: "ori     \(r(rA)), \(r(rD)), 0x%X", uimm)
        case 25: return String(format: "oris    \(r(rA)), \(r(rD)), 0x%X", uimm)
        case 26: return String(format: "xori    \(r(rA)), \(r(rD)), 0x%X", uimm)
        case 27: return String(format: "xoris   \(r(rA)), \(r(rD)), 0x%X", uimm)
        case 28: return String(format: "andi.   \(r(rA)), \(r(rD)), 0x%X", uimm)
        case 29: return String(format: "andis.  \(r(rA)), \(r(rD)), 0x%X", uimm)

        // ── Compare Immediates ────────────────────────────────────

        case 11: return "cmpi    cr\(rD >> 2), 1, \(r(rA)), \(simm)"
        case 10: return String(format: "cmpli   cr\(rD >> 2), 1, \(r(rA)), 0x%X", uimm)

        // ── Loads ─────────────────────────────────────────────────

        case 34: return "lbz     \(r(rD)), \(simm)(\(r(rA)))"
        case 35: return "lbzu    \(r(rD)), \(simm)(\(r(rA)))"
        case 40: return "lhz     \(r(rD)), \(simm)(\(r(rA)))"
        case 42: return "lha     \(r(rD)), \(simm)(\(r(rA)))"
        case 44: return "lhzu    \(r(rD)), \(simm)(\(r(rA)))"
        case 32: return "lwz     \(r(rD)), \(simm)(\(r(rA)))"
        case 33: return "lwzu    \(r(rD)), \(simm)(\(r(rA)))"
        case 48: return "lfs     \(f(rD)), \(simm)(\(r(rA)))"
        case 49: return "lfsu    \(f(rD)), \(simm)(\(r(rA)))"
        case 50: return "lfd     \(f(rD)), \(simm)(\(r(rA)))"
        case 58:
            let ds = Int32(bitPattern: raw & 0xFFFC)
            switch raw & 3 {
            case 0: return "ld      \(r(rD)), \(ds)(\(r(rA)))"
            case 1: return "ldu     \(r(rD)), \(ds)(\(r(rA)))"
            case 2: return "lwa     \(r(rD)), \(ds)(\(r(rA)))"
            default: return "ld??    \(r(rD)), \(ds)(\(r(rA)))"
            }

        // ── Stores ────────────────────────────────────────────────

        case 38: return "stb     \(r(rD)), \(simm)(\(r(rA)))"
        case 39: return "stbu    \(r(rD)), \(simm)(\(r(rA)))"
        case 44: return "sth     \(r(rD)), \(simm)(\(r(rA)))"
        case 45: return "sthu    \(r(rD)), \(simm)(\(r(rA)))"
        case 36: return "stw     \(r(rD)), \(simm)(\(r(rA)))"
        case 37: return "stwu    \(r(rD)), \(simm)(\(r(rA)))"
        case 52: return "stfs    \(f(rD)), \(simm)(\(r(rA)))"
        case 54: return "stfd    \(f(rD)), \(simm)(\(r(rA)))"
        case 62:
            let ds = Int32(bitPattern: raw & 0xFFFC)
            return (raw & 3) == 1
                ? "stdu    \(r(rD)), \(ds)(\(r(rA)))"
                : "std     \(r(rD)), \(ds)(\(r(rA)))"

        // ── Branches ──────────────────────────────────────────────

        case 18:
            let li26 = Int32(bitPattern: raw & 0x03FF_FFFC)
            let liSign = li26 < 0x200_0000 ? li26 : li26 | Int32(bitPattern: 0xFC00_0000)
            let target = aa
                ? UInt64(bitPattern: Int64(liSign))
                : UInt64(bitPattern: Int64(bitPattern: pc) + Int64(liSign))
            let suffix = aa ? (lk ? "bla" : "ba") : (lk ? "bl" : "b")
            return String(format: "\(suffix.padding(toLength: 8, withPad: " ", startingAt: 0))0x%016X", target)

        case 16:
            let bd14 = Int32(bitPattern: raw & 0xFFFC)
            let bdSign = bd14 < 32768 ? bd14 : bd14 | Int32(bitPattern: 0xFFFF0000)
            let target = aa
                ? UInt64(bitPattern: Int64(bdSign))
                : UInt64(bitPattern: Int64(bitPattern: pc) + Int64(bdSign))
            let bo = (raw >> 21) & 0x1F
            let bi = (raw >> 16) & 0x1F
            return String(format: "bc      \(bo), \(bi), 0x%016X", target)

        case 19:
            switch xo31 {
            case 16:  return lk ? "bclrl" : "bclr"
            case 528: return lk ? "bcctrl" : "bcctr"
            case 0:   return "mcrf    cr\(rD >> 2), cr\(rA >> 2)"
            case 193: return "crxor   \(rD), \(rA), \(rB)"
            case 257: return "crand   \(rD), \(rA), \(rB)"
            case 449: return "cror    \(rD), \(rA), \(rB)"
            case 150: return "isync"
            default:  return String(format: "?op19   xo=%d", xo31)
            }

        // ── Rotate/Shift ──────────────────────────────────────────

        case 20:
            let sh = (raw >> 11) & 0x1F
            let mb = (raw >> 6) & 0x1F
            let me = (raw >> 1) & 0x1F
            return "rlwimi\(dot)  \(r(rA)), \(r(rD)), \(sh), \(mb), \(me)"

        case 21:
            let sh = (raw >> 11) & 0x1F
            let mb = (raw >> 6) & 0x1F
            let me = (raw >> 1) & 0x1F
            if mb == 0 && me == 31 { return "rotlwi  \(r(rA)), \(r(rD)), \(sh)" }
            if sh == 0 { return "clrlwi  \(r(rA)), \(r(rD)), \(mb)" }
            return "rlwinm\(dot)  \(r(rA)), \(r(rD)), \(sh), \(mb), \(me)"

        case 23:
            let mb = (raw >> 6) & 0x1F
            let me = (raw >> 1) & 0x1F
            return "rlwnm\(dot)   \(r(rA)), \(r(rD)), \(r(rB)), \(mb), \(me)"

        case 30:
            let sh = Int(((raw >> 11) & 0x1F) | (((raw >> 1) & 1) << 5))
            let mb = Int(((raw >> 6) & 0x1F) | ((raw & 0x20)))
            let xo30 = (raw >> 2) & 0x7
            switch xo30 {
            case 0: return "rldicl\(dot)  \(r(rA)), \(r(rD)), \(sh), \(mb)"
            case 1: return "rldicr\(dot)  \(r(rA)), \(r(rD)), \(sh), \(mb)"
            case 2: return "rldic\(dot)   \(r(rA)), \(r(rD)), \(sh), \(mb)"
            case 3: return "rldimi\(dot)  \(r(rA)), \(r(rD)), \(sh), \(mb)"
            default: return "rld??   \(r(rA)), \(r(rD)), \(sh), \(mb)"
            }

        // ── System Call ───────────────────────────────────────────

        case 17: return "sc"

        // ── Opcode 31 (register-register) ────────────────────────

        case 31:
            return disasm31(raw: raw, rD: rD, rA: rA, rB: rB, xo: xo31, dot: dot)

        // ── Floating Point 63 ─────────────────────────────────────

        case 63:
            return disasm63(raw: raw, rD: rD, rA: rA, rB: rB, rC: rC, xo: xo63, dot: dot)

        case 59:
            return disasm59(raw: raw, rD: rD, rA: rA, rB: rB, rC: rC, xo: xo63, dot: dot)

        default:
            return String(format: ".word   0x%08X", raw)
        }
    }

    // MARK: - Opcode 31

    private static func disasm31(raw: UInt32, rD: Int, rA: Int, rB: Int,
                                  xo: UInt32, dot: String) -> String {
        switch xo {
        case 266:  return "add\(dot)     \(r(rD)), \(r(rA)), \(r(rB))"
        case 40:   return "subf\(dot)    \(r(rD)), \(r(rA)), \(r(rB))"
        case 8:    return "subfc\(dot)   \(r(rD)), \(r(rA)), \(r(rB))"
        case 104:  return "neg\(dot)     \(r(rD)), \(r(rA))"
        case 138:  return "adde\(dot)    \(r(rD)), \(r(rA)), \(r(rB))"
        case 234:  return "addme\(dot)   \(r(rD)), \(r(rA))"
        case 232:  return "addze\(dot)   \(r(rD)), \(r(rA))"
        case 235:  return "mullw\(dot)   \(r(rD)), \(r(rA)), \(r(rB))"
        case 233:  return "mulld\(dot)   \(r(rD)), \(r(rA)), \(r(rB))"
        case 75:   return "mulhw\(dot)   \(r(rD)), \(r(rA)), \(r(rB))"
        case 73:   return "mulhd\(dot)   \(r(rD)), \(r(rA)), \(r(rB))"
        case 491:  return "divw\(dot)    \(r(rD)), \(r(rA)), \(r(rB))"
        case 489:  return "divd\(dot)    \(r(rD)), \(r(rA)), \(r(rB))"
        case 459:  return "divwu\(dot)   \(r(rD)), \(r(rA)), \(r(rB))"
        case 457:  return "divdu\(dot)   \(r(rD)), \(r(rA)), \(r(rB))"
        case 28:   return "and\(dot)     \(r(rA)), \(r(rD)), \(r(rB))"
        case 60:   return "andc\(dot)    \(r(rA)), \(r(rD)), \(r(rB))"
        case 444:
            if rD == rB { return "mr\(dot)      \(r(rA)), \(r(rD))" }
            return "or\(dot)      \(r(rA)), \(r(rD)), \(r(rB))"
        case 412:  return "orc\(dot)     \(r(rA)), \(r(rD)), \(r(rB))"
        case 316:  return "xor\(dot)     \(r(rA)), \(r(rD)), \(r(rB))"
        case 476:  return "nand\(dot)    \(r(rA)), \(r(rD)), \(r(rB))"
        case 124:
            if rD == rB { return "not\(dot)     \(r(rA)), \(r(rD))" }
            return "nor\(dot)     \(r(rA)), \(r(rD)), \(r(rB))"
        case 954:  return "extsb\(dot)   \(r(rA)), \(r(rD))"
        case 922:  return "extsh\(dot)   \(r(rA)), \(r(rD))"
        case 986:  return "extsw\(dot)   \(r(rA)), \(r(rD))"
        case 24:   return "slw\(dot)     \(r(rA)), \(r(rD)), \(r(rB))"
        case 536:  return "srw\(dot)     \(r(rA)), \(r(rD)), \(r(rB))"
        case 792:  return "sraw\(dot)    \(r(rA)), \(r(rD)), \(r(rB))"
        case 27:   return "sld\(dot)     \(r(rA)), \(r(rD)), \(r(rB))"
        case 539:  return "srd\(dot)     \(r(rA)), \(r(rD)), \(r(rB))"
        case 794:  return "srad\(dot)    \(r(rA)), \(r(rD)), \(r(rB))"
        case 26:   return "cntlzw\(dot)  \(r(rA)), \(r(rD))"
        case 58:   return "cntlzd\(dot)  \(r(rA)), \(r(rD))"
        case 0:    return "cmp     cr\(rD >> 2), 1, \(r(rA)), \(r(rB))"
        case 32:   return "cmpl    cr\(rD >> 2), 1, \(r(rA)), \(r(rB))"
        case 339:
            let spr = ((raw >> 16) & 0x1F) | (((raw >> 11) & 0x1F) << 5)
            return "mfspr   \(r(rD)), \(sprName(spr))"
        case 467:
            let spr = ((raw >> 16) & 0x1F) | (((raw >> 11) & 0x1F) << 5)
            return "mtspr   \(sprName(spr)), \(r(rD))"
        case 19:   return "mfcr    \(r(rD))"
        case 144:  return String(format: "mtcrf   0x%02X, \(r(rD))", (raw >> 12) & 0xFF)
        case 87:   return "lbzx    \(r(rD)), \(r(rA)), \(r(rB))"
        case 279:  return "lhzx    \(r(rD)), \(r(rA)), \(r(rB))"
        case 343:  return "lhax    \(r(rD)), \(r(rA)), \(r(rB))"
        case 23:   return "lwzx    \(r(rD)), \(r(rA)), \(r(rB))"
        case 21:   return "ldx     \(r(rD)), \(r(rA)), \(r(rB))"
        case 215:  return "stbx    \(r(rD)), \(r(rA)), \(r(rB))"
        case 407:  return "sthx    \(r(rD)), \(r(rA)), \(r(rB))"
        case 151:  return "stwx    \(r(rD)), \(r(rA)), \(r(rB))"
        case 149:  return "stdx    \(r(rD)), \(r(rA)), \(r(rB))"
        case 598:  return "sync"
        case 854:  return "eieio"
        case 246:  return "dcbtst  \(r(rA)), \(r(rB))"
        case 278:  return "dcbt    \(r(rA)), \(r(rB))"
        case 1014: return "dcbz    \(r(rA)), \(r(rB))"
        default:   return String(format: ".op31   xo=%d", xo)
        }
    }

    // MARK: - Opcode 63 / 59

    private static func disasm63(raw: UInt32, rD: Int, rA: Int, rB: Int, rC: Int,
                                  xo: UInt32, dot: String) -> String {
        switch xo {
        case 0:    return "fcmpu   cr\(rD >> 2), \(f(rA)), \(f(rB))"
        case 12:   return "frsp\(dot)    \(f(rD)), \(f(rB))"
        case 14:   return "fctiwz\(dot)  \(f(rD)), \(f(rB))"
        case 18:   return "fdiv\(dot)    \(f(rD)), \(f(rA)), \(f(rB))"
        case 20:   return "fsub\(dot)    \(f(rD)), \(f(rA)), \(f(rB))"
        case 21:   return "fadd\(dot)    \(f(rD)), \(f(rA)), \(f(rB))"
        case 22:   return "fsqrt\(dot)   \(f(rD)), \(f(rB))"
        case 25:   return "fmul\(dot)    \(f(rD)), \(f(rA)), \(f(rC))"
        case 28:   return "fmsub\(dot)   \(f(rD)), \(f(rA)), \(f(rC)), \(f(rB))"
        case 29:   return "fmadd\(dot)   \(f(rD)), \(f(rA)), \(f(rC)), \(f(rB))"
        case 30:   return "fnmsub\(dot)  \(f(rD)), \(f(rA)), \(f(rC)), \(f(rB))"
        case 31:   return "fnmadd\(dot)  \(f(rD)), \(f(rA)), \(f(rC)), \(f(rB))"
        case 40:   return "fneg\(dot)    \(f(rD)), \(f(rB))"
        case 72:   return "fmr\(dot)     \(f(rD)), \(f(rB))"
        case 136:  return "fnabs\(dot)   \(f(rD)), \(f(rB))"
        case 264:  return "fabs\(dot)    \(f(rD)), \(f(rB))"
        case 583:  return "mffs\(dot)    \(f(rD))"
        case 814:  return "fctid\(dot)   \(f(rD)), \(f(rB))"
        case 815:  return "fctidz\(dot)  \(f(rD)), \(f(rB))"
        case 846:  return "fcfid\(dot)   \(f(rD)), \(f(rB))"
        default:   return String(format: ".op63   xo=%d", xo)
        }
    }

    private static func disasm59(raw: UInt32, rD: Int, rA: Int, rB: Int, rC: Int,
                                  xo: UInt32, dot: String) -> String {
        switch xo {
        case 18:   return "fdivs\(dot)   \(f(rD)), \(f(rA)), \(f(rB))"
        case 20:   return "fsubs\(dot)   \(f(rD)), \(f(rA)), \(f(rB))"
        case 21:   return "fadds\(dot)   \(f(rD)), \(f(rA)), \(f(rB))"
        case 22:   return "fsqrts\(dot)  \(f(rD)), \(f(rB))"
        case 25:   return "fmuls\(dot)   \(f(rD)), \(f(rA)), \(f(rC))"
        case 28:   return "fmsubs\(dot)  \(f(rD)), \(f(rA)), \(f(rC)), \(f(rB))"
        case 29:   return "fmadds\(dot)  \(f(rD)), \(f(rA)), \(f(rC)), \(f(rB))"
        default:   return String(format: ".op59   xo=%d", xo)
        }
    }

    // MARK: - SPR Names

    private static func sprName(_ spr: UInt32) -> String {
        switch spr {
        case 1:   return "XER"
        case 8:   return "LR"
        case 9:   return "CTR"
        case 287: return "PVR"
        case 256: return "VRSAVE"
        case 268: return "TBL"
        case 269: return "TBU"
        default:  return "SPR(\(spr))"
        }
    }
}
