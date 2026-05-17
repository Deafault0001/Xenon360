// DebuggerView.swift
// Xenon360 — CPU Debugger

import SwiftUI

struct DebuggerView: View {
    @EnvironmentObject var emulator: Emulator
    @State private var selectedPanel: Panel = .registers
    @State private var memAddress: String = "00010000"
    @State private var disasmAddress: String = ""
    @State private var gprExpanded = true
    @State private var fprExpanded = false

    enum Panel: String, CaseIterable {
        case registers = "Registers"
        case memory    = "Memory"
        case disasm    = "Disasm"
        case threads   = "Threads"
    }

    var cpu: XenonCPU { emulator.cpu }
    var thread0: XenonThread { cpu.threads[0][0] }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Panel picker
                Picker("Panel", selection: $selectedPanel) {
                    ForEach(Panel.allCases, id: \.self) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .padding(12)
                .background(Color(white: 0.08))

                // Content
                Group {
                    switch selectedPanel {
                    case .registers: registersPanel
                    case .memory:    memoryPanel
                    case .disasm:    disasmPanel
                    case .threads:   threadsPanel
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.05, green: 0.05, blue: 0.07))
            }
            .navigationTitle("Debugger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Step button
                    Button(action: {
                        try? emulator.stepOne()
                    }) {
                        Image(systemName: "arrow.right.square.fill")
                            .foregroundStyle(emulator.state == .paused ? .green : .gray)
                    }
                    .disabled(emulator.state != .paused)

                    // Pause/resume
                    Button(action: {
                        if emulator.state == .running { emulator.pause() }
                        else if emulator.state == .paused { emulator.run() }
                    }) {
                        Image(systemName: emulator.state == .running ? "pause.fill" : "play.fill")
                    }
                }
            }
        }
    }

    // MARK: - Registers Panel

    var registersPanel: some View {
        ScrollView {
            VStack(spacing: 0) {
                // PC / LR / CTR / CR / XER
                specialRegsSection

                Divider().background(.white.opacity(0.1))

                // GPRs
                DisclosureGroup(isExpanded: $gprExpanded) {
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 0) {
                        ForEach(0..<32, id: \.self) { i in
                            RegCell(
                                name: "r\(i)",
                                value: thread0.gpr[i],
                                highlight: i == 1   // sp
                            )
                        }
                    }
                } label: {
                    SectionHeader(title: "General Purpose Registers (GPR)")
                }
                .padding(.horizontal, 12)

                Divider().background(.white.opacity(0.1))

                // FPRs
                DisclosureGroup(isExpanded: $fprExpanded) {
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 0) {
                        ForEach(0..<32, id: \.self) { i in
                            FPRegCell(name: "f\(i)", value: thread0.fpr[i])
                        }
                    }
                } label: {
                    SectionHeader(title: "Floating-Point Registers (FPR)")
                }
                .padding(.horizontal, 12)
            }
        }
    }

    var specialRegsSection: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Special Purpose Registers")
                .padding(.horizontal, 12)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                RegCell(name: "PC",  value: thread0.pc,  highlight: true)
                RegCell(name: "LR",  value: thread0.lr,  highlight: false)
                RegCell(name: "CTR", value: thread0.ctr, highlight: false)
                RegCell(name: "CR",  value: UInt64(thread0.cr.value), highlight: false)
                RegCell(name: "MSR", value: thread0.msr, highlight: false)
                RegCell(name: "XER", value: thread0.xer.raw, highlight: false)
            }
            .padding(.horizontal, 12)

            // CR flags breakdown
            HStack(spacing: 4) {
                Text("CR0:")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                CRFlag(name: "LT", active: thread0.cr.lt)
                CRFlag(name: "GT", active: thread0.cr.gt)
                CRFlag(name: "EQ", active: thread0.cr.eq)
                CRFlag(name: "SO", active: thread0.cr.so)
                Spacer()
                Text("XER:")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                CRFlag(name: "SO", active: thread0.xer.so)
                CRFlag(name: "OV", active: thread0.xer.ov)
                CRFlag(name: "CA", active: thread0.xer.ca)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Memory Panel

    var memoryPanel: some View {
        VStack(spacing: 0) {
            // Address bar
            HStack {
                Text("0x")
                    .foregroundStyle(.green)
                    .font(.system(.body, design: .monospaced))
                TextField("Address", text: $memAddress)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.white)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { }
                Spacer()
                Button("Go") { }
                    .foregroundStyle(.green)
            }
            .padding(12)
            .background(Color(white: 0.1))

            Divider().background(.white.opacity(0.1))

            // Hex dump
            ScrollView {
                if let addr = UInt64(memAddress, radix: 16) {
                    Text(emulator.memory.hexDump(from: addr, length: 256))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.green.opacity(0.9))
                        .padding(12)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Disassembler Panel

    var disasmPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("0x")
                    .foregroundStyle(.cyan)
                    .font(.system(.body, design: .monospaced))
                TextField("PC", text: $disasmAddress)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.white)
                    .placeholder(when: disasmAddress.isEmpty) {
                        Text(String(format: "%016X", thread0.pc))
                            .foregroundStyle(.white.opacity(0.3))
                            .font(.system(.body, design: .monospaced))
                    }
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Spacer()
            }
            .padding(12)
            .background(Color(white: 0.1))

            Divider().background(.white.opacity(0.1))

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let startAddr = UInt64(disasmAddress, radix: 16) ?? thread0.pc
                    ForEach(0..<32, id: \.self) { i in
                        let addr = startAddr + UInt64(i * 4)
                        let raw  = emulator.memory.read32(addr)
                        let isCurrent = addr == thread0.pc
                        DisasmRow(address: addr, raw: raw, isCurrent: isCurrent)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Threads Panel

    var threadsPanel: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { core in
                    VStack(spacing: 0) {
                        HStack {
                            Text("Core \(core)")
                                .font(.headline.bold())
                                .foregroundStyle(.white)
                            Spacer()
                        }
                        .padding(12)
                        .background(Color(white: 0.12))

                        ForEach(0..<2, id: \.self) { t in
                            let thread = cpu.threads[core][t]
                            ThreadRow(thread: thread)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.white.opacity(0.08))
                    )
                }
            }
            .padding(12)
        }
    }
}

// MARK: - Component Views

struct SectionHeader: View {
    let title: String
    var body: some View {
        HStack {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.white.opacity(0.4))
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

struct RegCell: View {
    let name: String
    let value: UInt64
    let highlight: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
            Text(String(format: "%016X", value))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(highlight ? .green : .white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlight ? Color.green.opacity(0.08) : Color.clear)
    }
}

struct FPRegCell: View {
    let name: String
    let value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
            Text(String(format: "%.6g", value))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.cyan.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CRFlag: View {
    let name: String
    let active: Bool

    var body: some View {
        Text(name)
            .font(.system(size: 9, design: .monospaced).bold())
            .foregroundStyle(active ? .black : .white.opacity(0.3))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(active ? Color.green : Color(white: 0.15))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

struct DisasmRow: View {
    let address: UInt64
    let raw: UInt32
    let isCurrent: Bool

    var mnemonic: String { PowerPCDisasm.disassemble(raw: raw, pc: address) }

    var body: some View {
        HStack(spacing: 0) {
            // Arrow for PC
            Text(isCurrent ? "▶" : " ")
                .font(.system(size: 10))
                .foregroundStyle(.green)
                .frame(width: 16)

            // Address
            Text(String(format: "%08X", UInt32(address & 0xFFFF_FFFF)))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: 72, alignment: .leading)

            // Raw bytes
            Text(String(format: "%08X", raw))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.orange.opacity(0.6))
                .frame(width: 76, alignment: .leading)

            // Mnemonic
            Text(mnemonic)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isCurrent ? .green : .white.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isCurrent ? Color.green.opacity(0.1) : Color.clear)
    }
}

struct ThreadRow: View {
    let thread: XenonThread

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Thread \(thread.threadIndex)")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Text(String(format: "PC: 0x%016X", thread.pc))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(thread.instructionsExecuted)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.green)
                Text("instrs")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(white: 0.09))
    }
}

// MARK: - SwiftUI Placeholder Extension

extension View {
    func placeholder<Content: View>(
        when condition: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack(alignment: .leading) {
            if condition { content() }
            self
        }
    }
}
