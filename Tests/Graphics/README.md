# Framebuffer diagnostic

This self-contained test draws synthetic color quadrants; it does not run a 3DS game.

```sh
cd /Users/ocean/code/3duos
xcrun swiftc Core/Graphics/FramebufferDecoder.swift Core/Graphics/MetalScreenPresenter.swift Tests/Graphics/main.swift -o /tmp/3duos-graphics-test
/tmp/3duos-graphics-test
```

It checks both screen sizes, corner colors, 8 bytes of per-column padding, and a truncated buffer. A window then submits two `CAMetalLayer` frames for 12 seconds. Top quadrants should be red/green over blue/yellow; bottom quadrants magenta/cyan over white/gray.

`ThreeDSFramebuffer` models the LCD scanout format RGB8 stored in B,G,R byte order, at the standard rotated physical dimensions 240×400 (top) and 240×320 (bottom). For visible landscape coordinates `(x, y)`, the first B byte is at `x * stride + (239 - y) * 3`. The default stride is 720 bytes. The presenter consumes decoded landscape RGBA8 and stretches it to the `CAMetalLayer.drawableSize` set by the caller; the caller controls aspect ratio and thread scheduling.

This is the linear display-transfer output, not the PICA 8×8 tiled render target. A future renderer must generate or transfer to this LCD layout before using the decoder. References: [3dbrew LCD registers](https://www.3dbrew.org/wiki/LCD_Registers), [3dbrew GPU external registers](https://www.3dbrew.org/wiki/GPU/External_Registers), and [libctru framebuffer API](https://github.com/devkitPro/libctru/blob/master/libctru/include/3ds/gfx.h).
