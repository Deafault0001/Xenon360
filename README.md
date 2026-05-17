# Xenon360
### JIT-less Xbox 360 Emulator for iOS/iPadOS 26

A pure Swift interpreter-based Xbox 360 emulator.  
No JIT — fully compatible with Apple's iOS sandbox.

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  SwiftUI (iPadOS 26)                │
│   LibraryView · EmulatorView · DebuggerView         │
└──────────────────────┬──────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────┐
│                   Emulator.swift                     │
│         (orchestrates 6 hardware threads)            │
└──────┬──────────────┬─────────────┬─────────────────┘
       │              │             │
┌──────▼──────┐ ┌─────▼─────┐ ┌────▼──────────┐
│  XenonCPU   │ │XenonMemory│ │  XEXLoader    │
│  interpreter│ │ 512MB RAM │ │  XEX2 parser  │
│  PowerPC PPC│ │ big-endian│ │  PE importer  │
└──────┬──────┘ └───────────┘ └───────────────┘
       │
┌──────▼──────────────────┐  ┌────────────────────────┐
│     XenosGPU            │  │     XenonAudio          │
│  Xenos → Metal stub     │  │  XMA2 + AVAudioEngine   │
│  D3D9 → Metal (WIP)     │  │  HLE XAudio2 API        │
└─────────────────────────┘  └────────────────────────┘
```

---

## CPU Implementation Status

| Category | Instructions | Status |
|----------|-------------|--------|
| Integer Arithmetic | add, sub, mul, div, neg, adde, addme... | ✅ Done |
| Integer Logic | and, or, xor, nor, nand, orc, andc... | ✅ Done |
| Comparisons | cmp, cmpi, cmpl, cmpli | ✅ Done |
| Loads | lbz, lhz, lha, lwz, ld, lwa, lfs, lfd + indexed | ✅ Done |
| Stores | stb, sth, stw, std, stfs, stfd + indexed | ✅ Done |
| Branches | b, bl, bc, bclr, bcctr + all variants | ✅ Done |
| Rotate/Shift | rlwinm, rlwimi, rlwnm, sld, srd, srad... | ✅ Done |
| 64-bit Rotate | rldicl, rldicr, rldic, rldimi, rldcl | ✅ Done |
| FP Double | fadd, fsub, fmul, fdiv, fmadd, fmsub... | ✅ Done |
| FP Single | fadds, fsubs, fmuls, fdivs, fmadds... | ✅ Done |
| CR Logic | crand, cror, crxor, crnand, crnor... | ✅ Done |
| SPR | mfspr, mtspr (LR, CTR, XER, PVR) | ✅ Done |
| VMX/AltiVec | Basic register ops | 🔄 Partial |
| GPU (Xenos) | D3D9 → Metal translation | 🚧 WIP |
| Audio (XMA2) | XMA2 → PCM decoder | 🚧 WIP |
| Kernel HLE | NtCreateFile, ExAllocatePool... | 🔄 Partial |

---

## Files

```
Xenon360/
├── Package.swift
├── README.md
├── Xenon360/
│   └── Info.plist
├── Sources/Xenon360/
│   ├── Core/
│   │   ├── XenonCPU.swift          PowerPC interpreter (~1000 lines)
│   │   ├── XenonMemory.swift       512MB big-endian address space
│   │   ├── PowerPCDisasm.swift     Full PPC disassembler
│   │   └── Emulator.swift          Session coordinator + HLE
│   ├── Loader/
│   │   └── XEXLoader.swift         XEX2 executable parser
│   ├── GPU/
│   │   └── XenosGPU.swift          Metal renderer + Xenos stub
│   ├── Audio/
│   │   └── XenonAudio.swift        AVAudioEngine + XMA2 stub
│   └── UI/
│       ├── Xenon360App.swift        SwiftUI @main
│       ├── ContentView.swift        Tab navigation
│       ├── LibraryView.swift        Game browser + XEX importer
│       ├── EmulatorView.swift       Game display + controls
│       ├── DebuggerView.swift       CPU registers + disasm + memory
│       └── SettingsView.swift       All emulator settings
└── Tests/Xenon360Tests/
    └── XenonCPUTests.swift          Unit tests for interpreter
```

---

## Building

### Requirements
- macOS 15+ (Sequoia)
- Xcode 26 beta
- Apple Developer account (free for sideloading)

### Steps
```bash
# Clone / download the project
open Xenon360.xcodeproj   # or create new project and add files

# In Xcode:
# 1. Set Team in Signing & Capabilities
# 2. Set target to iOS 26
# 3. Connect iPad
# 4. Product → Run  (⌘R)
```

### Sideloading (no paid account)
Use **AltStore** or **Sideloadly** to sign and install the IPA.

---

## Legal

This emulator does not include any Xbox 360 BIOS, firmware, or game files.  
You must dump these from hardware you own.  
Xenon360 is not affiliated with Microsoft Corporation.

---

## Contributing

Priority areas:
1. **Xenos GPU** — D3D9 PM4 packet decoder → Metal draw calls
2. **XMA2 Audio** — Implement WMA Pro decoder
3. **Kernel HLE** — More syscall implementations
4. **VMX/AltiVec** — Full vector instruction set

PRs welcome.
