#!/usr/bin/env python3
"""
Generate Jeeves brand PNG icons from the geometric design specification.

Run from repo root:
    python3 tools/generate_icons.py

Produces:
  app/assets/brand/icon-source-1024.png          – Pointillist app icon (for flutter_launcher_icons)
  app/assets/brand/icon-adaptive-fg-1024.png     – Dots-only on transparent (Android adaptive fg)
  app/web/favicon.png                            – Signature 32×32
  app/web/icons/Icon-192.png                     – Pointillist app icon 192×192
  app/web/icons/Icon-512.png                     – Pointillist app icon 512×512
  app/web/icons/Icon-maskable-192.png            – Maskable (safe-zone scaled) 192×192
  app/web/icons/Icon-maskable-512.png            – Maskable 512×512
  app/web/apple-touch-icon.png                   – Pointillist app icon 180×180
"""

import math
import os
import struct
import zlib

# ---------------------------------------------------------------------------
# Design tokens
# ---------------------------------------------------------------------------
INK   = (0x1A, 0x1A, 0x2E, 255)
BRAND = (0x26, 0x67, 0xB7, 255)
WHITE = (0xFF, 0xFF, 0xFF, 255)

DOTS = [
    (0x26, 0x67, 0xB7, 255),  # brand  #2667B7
    (0x60, 0xA5, 0xFA, 255),  # sky    #60A5FA
    (0xC4, 0xB5, 0xFD, 255),  # lav    #C4B5FD
    (0xFD, 0xBA, 0x74, 255),  # peach  #FDBA74
    (0xF9, 0xA8, 0xD4, 255),  # blush  #F9A8D4
    (0x6E, 0xE7, 0xB7, 255),  # mint   #6EE7B7
    (0xFD, 0xE6, 0x8A, 255),  # butter #FDE68A
]

# Dot positions as fractions of the mark bounding box (0-1, top→hook)
DOT_POS = [
    (0.50, 0.10),
    (0.50, 0.30),
    (0.50, 0.50),
    (0.50, 0.68),
    (0.50, 0.82),
    (0.40, 0.91),
    (0.28, 0.87),
]
DOT_R_FRAC = 0.07   # dot radius as fraction of mark size

# Signature geometry (fractions)
SIG_TITTLE_CY  = 0.12
SIG_TITTLE_R   = 0.07
SIG_STEM_START = 0.24   # y of stem top
SIG_STEM_END   = 0.80   # y where stem meets hook
SIG_HOOK_P1    = (0.50, 0.96)  # quadratic bezier control point
SIG_HOOK_P2    = (0.36, 0.92)  # endpoint of hook
SIG_STROKE_W   = 0.08

# ---------------------------------------------------------------------------
# Canvas / pixel utilities
# ---------------------------------------------------------------------------

def create_buf(w, h, r=0, g=0, b=0, a=0):
    return bytearray([r, g, b, a] * (w * h))


def _composite(buf, w, px, py, sr, sg, sb, sa_int):
    if px < 0 or py < 0 or px >= w or py >= (len(buf) // (w * 4)):
        return
    sa = sa_int / 255.0
    if sa <= 0:
        return
    i = (py * w + px) * 4
    if sa >= 0.999:
        buf[i], buf[i+1], buf[i+2], buf[i+3] = sr, sg, sb, sa_int
        return
    da = buf[i+3] / 255.0
    oa = sa + da * (1 - sa)
    if oa < 1e-6:
        return
    buf[i]   = int((sr * sa + buf[i]   * da * (1 - sa)) / oa)
    buf[i+1] = int((sg * sa + buf[i+1] * da * (1 - sa)) / oa)
    buf[i+2] = int((sb * sa + buf[i+2] * da * (1 - sa)) / oa)
    buf[i+3] = int(oa * 255)


def draw_circle_aa(buf, w, h, cx, cy, r, color):
    """Anti-aliased circle using 4×4 supersampling on the edge ring only."""
    cr, cg, cb, ca = color
    rint = int(r)
    for py in range(max(0, int(cy - r) - 2), min(h, int(cy + r) + 3)):
        for px in range(max(0, int(cx - r) - 2), min(w, int(cx + r) + 3)):
            dist = math.hypot(px + 0.5 - cx, py + 0.5 - cy)
            if dist < r - 1:
                _composite(buf, w, px, py, cr, cg, cb, ca)
            elif dist < r + 1:
                cov = 0.0
                for sy in range(4):
                    for sx in range(4):
                        dx = px + (sx + 0.5) / 4.0 - cx
                        dy = py + (sy + 0.5) / 4.0 - cy
                        if dx*dx + dy*dy <= r*r:
                            cov += 1.0
                cov /= 16.0
                _composite(buf, w, px, py, cr, cg, cb, int(ca * cov))


def draw_rounded_rect(buf, w, h, x0, y0, x1, y1, rx, color):
    """Fill rounded rectangle (AA corners)."""
    cr, cg, cb, ca = color
    for py in range(max(0, y0), min(h, y1 + 1)):
        for px in range(max(0, x0), min(w, x1 + 1)):
            cdx = max(0, max(x0 + rx - px, px - (x1 - rx)))
            cdy = max(0, max(y0 + rx - py, py - (y1 - rx)))
            dist = math.hypot(cdx + 0.5, cdy + 0.5)
            if dist < rx - 1:
                _composite(buf, w, px, py, cr, cg, cb, ca)
            elif dist < rx + 1:
                cov = 0.0
                for sy in range(4):
                    for sx in range(4):
                        ssx = px + (sx + 0.5) / 4.0
                        ssy = py + (sy + 0.5) / 4.0
                        ddx = max(0, max(x0 + rx - ssx, ssx - (x1 - rx)))
                        ddy = max(0, max(y0 + rx - ssy, ssy - (y1 - rx)))
                        if ddx*ddx + ddy*ddy <= rx*rx:
                            cov += 1.0
                cov /= 16.0
                _composite(buf, w, px, py, cr, cg, cb, int(ca * cov))


def stroke_along_path(buf, w, h, points, stroke_r, color):
    """Render a thick stroke by compositing circles along a polyline."""
    cr, cg, cb, ca = color
    step = max(1.0, stroke_r * 0.3)
    for i in range(len(points) - 1):
        x0, y0 = points[i]
        x1, y1 = points[i + 1]
        dist = math.hypot(x1 - x0, y1 - y0)
        n = max(2, int(dist / step))
        for j in range(n + 1):
            t = j / n
            px = x0 + t * (x1 - x0)
            py = y0 + t * (y1 - y0)
            draw_circle_aa(buf, w, h, px, py, stroke_r, color)


def sample_quadratic_bezier(p0, p1, p2, steps):
    """Return a polyline approximation of a quadratic bezier."""
    pts = []
    for i in range(steps + 1):
        t = i / steps
        x = (1-t)**2 * p0[0] + 2*(1-t)*t * p1[0] + t**2 * p2[0]
        y = (1-t)**2 * p0[1] + 2*(1-t)*t * p1[1] + t**2 * p2[1]
        pts.append((x, y))
    return pts

# ---------------------------------------------------------------------------
# PNG encoder
# ---------------------------------------------------------------------------

def encode_png(buf, w, h):
    def chunk(ctype, data):
        c = ctype + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xFFFFFFFF)

    ihdr = struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        i = y * w * 4
        raw.extend(buf[i:i + w * 4])

    return (
        b'\x89PNG\r\n\x1a\n'
        + chunk(b'IHDR', ihdr)
        + chunk(b'IDAT', zlib.compress(bytes(raw), 6))
        + chunk(b'IEND', b'')
    )


def save(buf, w, h, path):
    os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
    with open(path, 'wb') as f:
        f.write(encode_png(buf, w, h))
    print(f'  wrote {path}  ({w}×{h})')

# ---------------------------------------------------------------------------
# Render functions
# ---------------------------------------------------------------------------

def render_pointillist_appicon(size, hairlines=False, maskable_scale=1.0):
    """Pointillist dots on INK rounded-square plate."""
    buf = create_buf(size, size)
    rx = round(56 * size / 256)
    draw_rounded_rect(buf, size, size, 0, 0, size - 1, size - 1, rx, INK)

    # For maskable icons shrink the mark into the safe zone (80 % of size)
    mark_size = size * maskable_scale
    offset = (size - mark_size) / 2.0

    r = DOT_R_FRAC * mark_size
    for (fx, fy), color in zip(DOT_POS, DOTS):
        cx = offset + fx * mark_size
        cy = offset + fy * mark_size
        if hairlines:
            draw_circle_aa(buf, size, size, cx, cy, r + 1.25, (255, 255, 255, 217))
        draw_circle_aa(buf, size, size, cx, cy, r, color)
    return buf


def render_pointillist_transparent(size, on_dark=False):
    """Dots only on transparent background."""
    buf = create_buf(size, size)
    r = DOT_R_FRAC * size
    for (fx, fy), color in zip(DOT_POS, DOTS):
        cx = fx * size
        cy = fy * size
        if on_dark:
            draw_circle_aa(buf, size, size, cx, cy, r + 1.25, (255, 255, 255, 217))
        draw_circle_aa(buf, size, size, cx, cy, r, color)
    return buf


def render_signature(size, on_dark=False, app_icon=False):
    """Signature j-mark."""
    if app_icon:
        buf = create_buf(size, size)
        rx = round(56 * size / 256)
        draw_rounded_rect(buf, size, size, 0, 0, size - 1, size - 1, rx, BRAND)
        stem_color  = WHITE
        tittle_color = WHITE
    elif on_dark:
        buf = create_buf(size, size)
        stem_color  = WHITE
        tittle_color = BRAND
    else:
        buf = create_buf(size, size)
        stem_color  = INK
        tittle_color = BRAND

    # Tittle
    draw_circle_aa(buf, size, size,
                   0.50 * size, SIG_TITTLE_CY * size,
                   SIG_TITTLE_R * size, tittle_color)

    # Stem: vertical line
    stroke_r = SIG_STROKE_W / 2 * size
    stem = [(0.50 * size, SIG_STEM_START * size),
            (0.50 * size, SIG_STEM_END   * size)]
    stroke_along_path(buf, size, size, stem, stroke_r, stem_color)

    # Hook: quadratic bezier
    p0 = (0.50 * size, SIG_STEM_END * size)
    p1 = (SIG_HOOK_P1[0] * size, SIG_HOOK_P1[1] * size)
    p2 = (SIG_HOOK_P2[0] * size, SIG_HOOK_P2[1] * size)
    hook = sample_quadratic_bezier(p0, p1, p2, max(20, size // 8))
    stroke_along_path(buf, size, size, hook, stroke_r, stem_color)

    return buf

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

BASE = os.path.join(os.path.dirname(__file__), '..', 'app')

def main():
    print('Generating Jeeves brand PNG icons…')

    # 1. Source icon for flutter_launcher_icons (1024×1024, Pointillist appicon)
    print('\nApp icon source:')
    buf = render_pointillist_appicon(1024)
    save(buf, 1024, 1024, os.path.join(BASE, 'assets/brand/icon-source-1024.png'))

    # 2. Adaptive Android foreground (dots-only transparent, 1024×1024)
    buf = render_pointillist_transparent(1024)
    save(buf, 1024, 1024, os.path.join(BASE, 'assets/brand/icon-adaptive-fg-1024.png'))

    # 3. Web favicon — Signature 32×32, light surface
    print('\nWeb:')
    buf = render_signature(32, on_dark=False)
    save(buf, 32, 32, os.path.join(BASE, 'web/favicon.png'))

    # 4. PWA icons
    for sz in (192, 512):
        buf = render_pointillist_appicon(sz)
        save(buf, sz, sz, os.path.join(BASE, f'web/icons/Icon-{sz}.png'))

    # 5. Maskable PWA icons (mark scaled to 80 % safe zone)
    for sz in (192, 512):
        buf = render_pointillist_appicon(sz, maskable_scale=0.80)
        save(buf, sz, sz, os.path.join(BASE, f'web/icons/Icon-maskable-{sz}.png'))

    # 6. Apple touch icon (180×180)
    buf = render_pointillist_appicon(180)
    save(buf, 180, 180, os.path.join(BASE, 'web/apple-touch-icon.png'))

    print('\nDone. Run `dart run flutter_launcher_icons` in app/ to regenerate platform icons.')


if __name__ == '__main__':
    main()
