// XenonCPUTests.swift
// Xenon360 — CPU Interpreter Unit Tests

import XCTest
@testable import Xenon360Core

final class XenonCPUTests: XCTestCase {

    var memory: XenonMemory!
    var cpu: XenonCPU!
    var t: XenonThread { cpu.threads[0][0] }

    override func setUp() {
        super.setUp()
        memory = XenonMemory()
        cpu    = XenonCPU(memory: memory)
        t.pc   = 0x0001_0000
    }

    // MARK: - Helpers

    func writeInstr(_ addr: UInt64, _ raw: UInt32) {
        memory.write32(addr, value: raw)
    }

    func step() throws {
        try cpu.step()
    }

    // MARK: - Arithmetic

    func testADDI() throws {
        // addi r3, r0, 42   (0x38600000 | 42)
        // opcode=14, rD=3, rA=0, SIMM=42
        // 14<<26 | 3<<21 | 0<<16 | 42
        writeInstr(t.pc, (14 << 26) | (3 << 21) | 42)
        try step()
        XCTAssertEqual(t.gpr[3], 42)
    }

    func testADDI_WithBase() throws {
        t.gpr[4] = 100
        // addi r3, r4, 50
        writeInstr(t.pc, (14 << 26) | (3 << 21) | (4 << 16) | 50)
        try step()
        XCTAssertEqual(t.gpr[3], 150)
    }

    func testADDI_NegativeImm() throws {
        t.gpr[4] = 200
        // addi r3, r4, -50 (SIMM = 0xFFCE)
        let simm: UInt32 = UInt32(bitPattern: -50) & 0xFFFF
        writeInstr(t.pc, (14 << 26) | (3 << 21) | (4 << 16) | simm)
        try step()
        XCTAssertEqual(t.gpr[3], 150)
    }

    func testADD() throws {
        t.gpr[4] = 300
        t.gpr[5] = 700
        // add r3, r4, r5 → opcode=31, xo=266, rD=3, rA=4, rB=5
        let raw: UInt32 = (31 << 26) | (3 << 21) | (4 << 16) | (5 << 11) | (266 << 1)
        writeInstr(t.pc, raw)
        try step()
        XCTAssertEqual(t.gpr[3], 1000)
    }

    func testSUBF() throws {
        t.gpr[4] = 300   // rA
        t.gpr[5] = 1000  // rB
        // subf r3, r4, r5 → r3 = r5 - r4 = 700
        let raw: UInt32 = (31 << 26) | (3 << 21) | (4 << 16) | (5 << 11) | (40 << 1)
        writeInstr(t.pc, raw)
        try step()
        XCTAssertEqual(t.gpr[3], 700)
    }

    func testNEG() throws {
        t.gpr[4] = 42
        // neg r3, r4
        let raw: UInt32 = (31 << 26) | (3 << 21) | (4 << 16) | (104 << 1)
        writeInstr(t.pc, raw)
        try step()
        XCTAssertEqual(Int64(bitPattern: t.gpr[3]), -42)
    }

    func testMULLW() throws {
        t.gpr[4] = 7
        t.gpr[5] = 6
        // mullw r3, r4, r5
        let raw: UInt32 = (31 << 26) | (3 << 21) | (4 << 16) | (5 << 11) | (235 << 1)
        writeInstr(t.pc, raw)
        try step()
        XCTAssertEqual(t.gpr[3], 42)
    }

    func testDIVW() throws {
        t.gpr[4] = UInt64(bitPattern: Int64(100))
        t.gpr[5] = UInt64(bitPattern: Int64(7))
        // divw r3, r4, r5 → 100/7 = 14
        let raw: UInt32 = (31 << 26) | (3 << 21) | (4 << 16) | (5 << 11) | (491 << 1)
        writeInstr(t.pc, raw)
        try step()
        XCTAssertEqual(Int32(bitPattern: UInt32(t.gpr[3])), 14)
    }

    // MARK: - Logical

    func testOR() throws {
        t.gpr[4] = 0xF0F0
        t.gpr[5] = 0x0F0F
        // or r3, r4, r5 → opcode=31, xo=444, note: rA=r3 is dest, rS=r4
        let raw: UInt32 = (31 << 26) | (4 << 21) | (3 << 16) | (5 << 11) | (444 << 1)
        writeInstr(t.pc, raw)
        try step()
        XCTAssertEqual(t.gpr[3], 0xFFFF)
    }

    func testAND() throws {
        t.gpr[4] = 0xFF00
        t.gpr[5] = 0xF0F0
        let raw: UInt32 = (31 << 26) | (4 << 21) | (3 << 16) | (5 << 11) | (28 << 1)
        writeInstr(t.pc, raw)
        try step()
        XCTAssertEqual(t.gpr[3], 0xF000)
    }

    func testXOR() throws {
        t.gpr[4] = 0xAAAA
        t.gpr[5] = 0x5555
        let raw: UInt32 = (31 << 26) | (4 << 21) | (3 << 16) | (5 << 11) | (316 << 1)
        writeInstr(t.pc, raw)
        try step()
        XCTAssertEqual(t.gpr[3], 0xFFFF)
    }

    func testMR() throws {
        t.gpr[5] = 0xDEAD_BEEF
        // mr r3, r5  (or r3, r5, r5 with rA=r3, rS=rB=r5)
        let raw: UInt32 = (31 << 26) | (5 << 21) | (3 << 16) | (5 << 11) | (444 << 1)
        writeInstr(t.pc, raw)
        try step()
        XCTAssertEqual(t.gpr[3], 0xDEAD_BEEF)
    }

    // MARK: - Shifts

    func testSLW() throws {
        t.gpr[4] = 1
        t.gpr[5] = 4
        // slw r3, r4, r5
        let raw: UInt32 = (31 << 26) | (4 << 21) | (3 << 16) | (5 << 11) | (24 << 1)
        writeInstr(t.pc, raw)
        try step()
        XCTAssertEqual(t.gpr[3], 16)
    }

    func testSRW() throws {
        t.gpr[4] = 256
        t.gpr[5] = 4
        // srw r3, r4, r5
        let raw: UInt32 = (31 << 26) | (4 << 21) | (3 << 16) | (5 << 11) | (536 << 1)
        writeInstr(t.pc, raw)
        try step()
        XCTAssertEqual(t.gpr[3], 16)
    }

    // MARK: - Compare & CR

    func testCMPI_LT() throws {
        t.gpr[4] = UInt64(bitPattern: -5)
        // cmpi cr0, 1, r4, 0
        let raw: UInt32 = (11 << 26) | (0 << 21) | (4 << 16) | 0
        writeInstr(t.pc, raw)
        try step()
        XCTAssertTrue(t.cr.lt)
        XCTAssertFalse(t.cr.gt)
        XCTAssertFalse(t.cr.eq)
    }

    func testCMPI_GT() throws {
        t.gpr[4] = UInt64(bitPattern: Int64(10))
        let raw: UInt32 = (11 << 26) | (0 << 21) | (4 << 16) | 0
        writeInstr(t.pc, raw)
        try step()
        XCTAssertFalse(t.cr.lt)
        XCTAssertTrue(t.cr.gt)
        XCTAssertFalse(t.cr.eq)
    }

    func testCMPI_EQ() throws {
        t.gpr[4] = 0
        let raw: UInt32 = (11 << 26) | (0 << 21) | (4 << 16) | 0
        writeInstr(t.pc, raw)
        try step()
        XCTAssertFalse(t.cr.lt)
        XCTAssertFalse(t.cr.gt)
        XCTAssertTrue(t.cr.eq)
    }

    // MARK: - Load / Store

    func testLWZ_STW() throws {
        let addr: UInt64 = 0x0001_1000
        memory.write32(addr, value: 0xCAFE_BABE)

        t.gpr[4] = addr
        // lwz r3, 0(r4)
        let lwz: UInt32 = (32 << 26) | (3 << 21) | (4 << 16) | 0
        writeInstr(t.pc, lwz)
        try step()
        XCTAssertEqual(t.gpr[3], 0xCAFE_BABE)
    }

    func testSTW_LWZ() throws {
        let addr: UInt64 = 0x0001_2000
        t.gpr[3] = 0x1234_5678
        t.gpr[4] = addr
        // stw r3, 0(r4)
        let stw: UInt32 = (36 << 26) | (3 << 21) | (4 << 16) | 0
        writeInstr(t.pc, stw)
        try step()
        XCTAssertEqual(memory.read32(addr), 0x1234_5678)
    }

    func testLBZ_STB() throws {
        let addr: UInt64 = 0x0001_3000
        memory.write8(addr, value: 0xAB)
        t.gpr[4] = addr
        // lbz r3, 0(r4)
        let lbz: UInt32 = (34 << 26) | (3 << 21) | (4 << 16) | 0
        writeInstr(t.pc, lbz)
        try step()
        XCTAssertEqual(t.gpr[3], 0xAB)
    }

    // MARK: - Branch

    func testBranch_Unconditional() throws {
        let startPC = t.pc
        // b +8  (skip next instruction)
        let b: UInt32 = (18 << 26) | 8  // li=8, aa=0, lk=0
        writeInstr(t.pc, b)
        try step()
        XCTAssertEqual(t.pc, startPC + 8)
    }

    func testBL_SetsLR() throws {
        let startPC = t.pc
        // bl +8
        let bl: UInt32 = (18 << 26) | 8 | 1  // lk=1
        writeInstr(t.pc, bl)
        try step()
        XCTAssertEqual(t.lr, startPC + 4)
        XCTAssertEqual(t.pc, startPC + 8)
    }

    func testBLR() throws {
        t.lr = 0x0001_2000
        // blr: opcode=19, xo=16, bo=20 (always), bi=0, lk=0
        let blr: UInt32 = (19 << 26) | (20 << 21) | (16 << 1)
        writeInstr(t.pc, blr)
        try step()
        XCTAssertEqual(t.pc, 0x0001_2000)
    }

    // MARK: - Memory big-endian

    func testBigEndianWrite32() {
        memory.write32(0x1000, value: 0x12345678)
        XCTAssertEqual(memory.read8(0x1000), 0x12)
        XCTAssertEqual(memory.read8(0x1001), 0x34)
        XCTAssertEqual(memory.read8(0x1002), 0x56)
        XCTAssertEqual(memory.read8(0x1003), 0x78)
    }

    func testBigEndianRead64() {
        memory.write32(0x2000, value: 0xDEADBEEF)
        memory.write32(0x2004, value: 0xCAFEBABE)
        let val = memory.read64(0x2000)
        XCTAssertEqual(val, 0xDEAD_BEEF_CAFE_BABE)
    }

    // MARK: - Disassembler

    func testDisasmNOP() {
        // ori 0, 0, 0 = nop
        let s = PowerPCDisasm.disassemble(raw: 0x6000_0000, pc: 0)
        XCTAssertEqual(s, "nop")
    }

    func testDisasmADDI() {
        // addi r3, r0, 42
        let raw: UInt32 = (14 << 26) | (3 << 21) | 42
        let s = PowerPCDisasm.disassemble(raw: raw, pc: 0)
        XCTAssertTrue(s.contains("li") || s.contains("addi"))
        XCTAssertTrue(s.contains("r3"))
        XCTAssertTrue(s.contains("42"))
    }

    func testDisasmBLR() {
        let blr: UInt32 = (19 << 26) | (20 << 21) | (16 << 1)
        let s = PowerPCDisasm.disassemble(raw: blr, pc: 0)
        XCTAssertTrue(s.hasPrefix("bclr"))
    }
}
