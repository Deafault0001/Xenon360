// XenosGPU.swift
// Xenon360 — Xenos GPU Emulation Stub
//
// The Xbox 360 GPU ("Xenos") is a custom ATI R500-based GPU.
// It runs a modified D3D9 shader model with 48 shader pipes.
// Full Xenos → Metal translation is a major future milestone.
// This file sets up the Metal pipeline and framebuffer.

import Foundation
import Metal
import MetalKit
import simd

// MARK: - Xenos GPU Registers

struct XenosRegisters {
    // Render target
    var rb_modeControl:    UInt32 = 0
    var rb_surface_info:   UInt32 = 0
    var rb_color_info:     UInt32 = 0
    var rb_depth_info:     UInt32 = 0
    var rb_color_mask:     UInt32 = 0x0000000F

    // Viewport
    var pa_cl_vte_cntl:    UInt32 = 0
    var pa_sc_window_offset: UInt32 = 0

    // Shader
    var sq_program_cntl:   UInt32 = 0
    var sq_vs_const:       UInt32 = 0
    var sq_ps_const:       UInt32 = 0

    // Draw
    var vgt_draw_initiator: UInt32 = 0
    var vgt_num_indices:    UInt32 = 0
    var vgt_index_type:     UInt32 = 0

    // Framebuffer dimensions
    var surfaceWidth:  Int = 1280
    var surfaceHeight: Int = 720
}

// MARK: - Framebuffer

class XenosFramebuffer {
    let width:  Int
    let height: Int
    var pixels: [UInt32]  // BGRA8

    init(width: Int = 1280, height: Int = 720) {
        self.width  = width
        self.height = height
        self.pixels = Array(repeating: 0xFF000000, count: width * height)
    }

    // Fill with a color (used for clear)
    func clear(color: UInt32) {
        pixels = Array(repeating: color, count: width * height)
    }

    // Write a single pixel (BGRA)
    func writePixel(x: Int, y: Int, color: UInt32) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        pixels[y * width + x] = color
    }
}

// MARK: - Metal Renderer

class XenosRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    var pipelineState: MTLRenderPipelineState?
    var texture: MTLTexture?
    var framebuffer: XenosFramebuffer

    // Vertex buffer for fullscreen quad
    var vertexBuffer: MTLBuffer?

    private let vertices: [Float] = [
        // x,    y,    u,    v
        -1.0,  1.0,  0.0,  0.0,
         1.0,  1.0,  1.0,  0.0,
        -1.0, -1.0,  0.0,  1.0,
         1.0, -1.0,  1.0,  1.0,
    ]

    init?(device: MTLDevice) {
        self.device       = device
        self.commandQueue = device.makeCommandQueue()!
        self.framebuffer  = XenosFramebuffer()
        super.init()
        setupPipeline()
        setupTexture()
        setupVertexBuffer()
    }

    private func setupPipeline() {
        let shaderSrc = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexIn  { float2 pos [[attribute(0)]]; float2 uv [[attribute(1)]]; };
        struct VertexOut { float4 pos [[position]]; float2 uv; };

        vertex VertexOut vert(VertexIn in [[stage_in]]) {
            VertexOut out;
            out.pos = float4(in.pos, 0.0, 1.0);
            out.uv  = in.uv;
            return out;
        }

        fragment float4 frag(VertexOut in [[stage_in]],
                             texture2d<float> tex [[texture(0)]],
                             sampler samp         [[sampler(0)]]) {
            return tex.sample(samp, in.uv);
        }
        """

        guard let lib = try? device.makeLibrary(source: shaderSrc, options: nil),
              let vf = lib.makeFunction(name: "vert"),
              let ff = lib.makeFunction(name: "frag") else { return }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction   = vf
        desc.fragmentFunction = ff
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm

        let vdesc = MTLVertexDescriptor()
        vdesc.attributes[0].format = .float2
        vdesc.attributes[0].offset = 0
        vdesc.attributes[0].bufferIndex = 0
        vdesc.attributes[1].format = .float2
        vdesc.attributes[1].offset = 8
        vdesc.attributes[1].bufferIndex = 0
        vdesc.layouts[0].stride = 16
        desc.vertexDescriptor = vdesc

        pipelineState = try? device.makeRenderPipelineState(descriptor: desc)
    }

    private func setupTexture() {
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width:  framebuffer.width,
            height: framebuffer.height,
            mipmapped: false
        )
        td.usage   = [.shaderRead]
        td.storageMode = .shared
        texture = device.makeTexture(descriptor: td)
    }

    private func setupVertexBuffer() {
        vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<Float>.size,
            options: .storageModeShared
        )
    }

    // Upload framebuffer pixels to GPU texture
    func uploadFramebuffer() {
        guard let tex = texture else { return }
        framebuffer.pixels.withUnsafeBytes { ptr in
            tex.replace(
                region: MTLRegionMake2D(0, 0, framebuffer.width, framebuffer.height),
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: framebuffer.width * 4
            )
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        uploadFramebuffer()

        guard let drawable     = view.currentDrawable,
              let passDesc     = view.currentRenderPassDescriptor,
              let cmdBuf       = commandQueue.makeCommandBuffer(),
              let encoder      = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc),
              let pipeline     = pipelineState,
              let vbuf         = vertexBuffer,
              let tex          = texture else { return }

        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vbuf, offset: 0, index: 0)
        encoder.setFragmentTexture(tex, index: 0)

        let sampler = makeSampler()
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    private func makeSampler() -> MTLSamplerState {
        let desc = MTLSamplerDescriptor()
        desc.minFilter    = .nearest
        desc.magFilter    = .nearest
        desc.mipFilter    = .notMipmapped
        desc.sAddressMode = .clampToEdge
        desc.tAddressMode = .clampToEdge
        return device.makeSamplerState(descriptor: desc)!
    }
}

// MARK: - GPU MMIO Handler

class XenosGPU {
    var registers = XenosRegisters()
    let framebuffer: XenosFramebuffer
    weak var memory: XenonMemory?

    init(memory: XenonMemory) {
        self.memory     = memory
        self.framebuffer = XenosFramebuffer()
    }

    // Called from the memory MMIO handler for GPU register range
    // 0xC8000000 – 0xC83FFFFF
    func readRegister(_ offset: UInt32) -> UInt32 {
        switch offset {
        case 0x0000: return 0x0200_0000  // GPU_BASE / chip id
        case 0x6800: return 1            // RBBM_STATUS — GPU idle
        default:     return 0
        }
    }

    func writeRegister(_ offset: UInt32, value: UInt32) {
        switch offset {
        case 0x0003: handleCpPacket(value)  // CP_RB_WPTR
        default:     break
        }
    }

    // ── Command Processor (CP) ring buffer parser ──────────────
    // This is where real D3D9 draw calls come from.
    // Currently stubs everything — real implementation decodes
    // PM4 packets and translates to Metal draw calls.

    private func handleCpPacket(_ wptr: UInt32) {
        // TODO: walk ring buffer from rptr to wptr, decode PM4 packets
    }

    // ── Software rasterizer fallback (for simple 2D UI) ───────
    func clearColor(r: Float, g: Float, b: Float, a: Float) {
        let ri = UInt32(r * 255) & 0xFF
        let gi = UInt32(g * 255) & 0xFF
        let bi = UInt32(b * 255) & 0xFF
        let ai = UInt32(a * 255) & 0xFF
        let packed = (ai << 24) | (ri << 16) | (gi << 8) | bi
        framebuffer.clear(color: packed)
    }

    func drawTestPattern() {
        let w = framebuffer.width
        let h = framebuffer.height
        for y in 0..<h {
            for x in 0..<w {
                let r = UInt32(x * 255 / w)
                let g = UInt32(y * 255 / h)
                let b: UInt32 = 128
                framebuffer.writePixel(x: x, y: y,
                                       color: 0xFF000000 | (r << 16) | (g << 8) | b)
            }
        }
    }
}
