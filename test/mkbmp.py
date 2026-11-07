#!/usr/bin/env python3
"""Independent BMP writer + generators for testing bmp2png.jl (stdlib only)."""
import struct, math, random, os

def bmp_header(w, h, bpp, topdown=False):
    rowsize = ((bpp * w + 31) // 32) * 4
    npal = 0 if bpp >= 24 else (1 << bpp)
    off = 14 + 40 + 4 * npal
    size = off + rowsize * abs(h)
    hh = -h if topdown else h
    hdr = b'BM' + struct.pack('<IHHI', size, 0, 0, off)
    dib = struct.pack('<IiiHHIIiiII', 40, w, hh, 1, bpp, 0, 0, 2835, 2835, 0, 0)
    return hdr + dib, rowsize, off

def write_bmp(path, w, h, rows, palette=None, bpp=24, topdown=False):
    """rows: list of rows, each a list of pixels; pixel = (r,g,b) or palette index."""
    hdr, rowsize, off = bmp_header(w, h, bpp, topdown)
    pal = b''
    if palette:
        for (r, g, b) in palette:
            pal += struct.pack('<BBBB', b, g, r, 0)
    pad = b'\x00' * (rowsize - ((bpp * w + 7) // 8))
    body = b''
    for row in rows:
        rb = b''
        if bpp == 24:
            for (r, g, b) in row:
                rb += bytes((b, g, r))
        elif bpp == 32:
            for (r, g, b) in row:
                rb += bytes((b, g, r, 0))
        elif bpp == 8:
            rb += bytes(row)
        elif bpp == 4:
            acc = 0
            for i, v in enumerate(row):
                if i % 2 == 0:
                    acc = v << 4
                else:
                    rb += bytes((acc | v,))
            if w % 2 == 1:
                rb += bytes((acc,))
        elif bpp == 1:
            acc = 0; n = 0
            for v in row:
                acc = (acc << 1) | (v & 1); n += 1
                if n == 8:
                    rb += bytes((acc,)); acc = 0; n = 0
            if n:
                rb += bytes((acc << (8 - n),))
        body += rb + pad
    with open(path, 'wb') as f:
        f.write(hdr + pal + body)

def gen_flat(w, h, color):
    return [[color for _ in range(w)] for _ in range(h)]

def gen_gradient(w, h):
    return [[((x * 255) // max(1, w - 1), (y * 255) // max(1, h - 1), ((x + y) * 255) // max(1, w + h - 2))
             for x in range(w)] for y in range(h)]

def gen_noise(w, h, seed):
    rnd = random.Random(seed)
    return [[(rnd.randrange(256), rnd.randrange(256), rnd.randrange(256)) for _ in range(w)] for _ in range(h)]

def gen_fbm(w, h, seed, octaves=5):
    """smooth value noise, photo-like"""
    rnd = random.Random(seed)
    grids = []
    cell = 4
    for _ in range(octaves):
        gw, gh = max(2, w // cell + 2), max(2, h // cell + 2)
        grids.append([[rnd.random() for _ in range(gw)] for _ in range(gh)])
        cell *= 2
    rows = []
    for y in range(h):
        row = []
        for x in range(w):
            v = 0.0; amp = 1.0; cell = 4; tot = 0.0
            for g in grids:
                fx, fy = x / cell, y / cell
                x0, y0 = int(fx), int(fy)
                tx, ty = fx - x0, fy - y0
                sx, sy = (tx * tx * (3 - 2 * tx), ty * ty * (3 - 2 * ty))
                a = g[y0][x0]; b = g[y0][x0 + 1]; c = g[y0 + 1][x0]; d = g[y0 + 1][x0 + 1]
                v += amp * ((a + (b - a) * sx) + ((c + (d - c) * sx) - (a + (b - a) * sx)) * sy)
                tot += amp; amp *= 0.5; cell *= 2
            v /= tot
            row.append((int(40 + 60 * v), int(80 + 120 * v), int(150 + 90 * v)))
        rows.append(row)
    return rows

def gen_bands(w, h, ncolors=16):
    """flat color regions, palette-friendly"""
    cols = [(i * 17, (i * 7) % 256, 255 - i * 13) for i in range(ncolors)]
    return [[cols[(x * y // 7) % ncolors] for x in range(w)] for y in range(h)]

def gen_bmp_all(outdir, name, w, h, kind, seed=1, bpp=24, topdown=False):
    os.makedirs(outdir, exist_ok=True)
    if kind == 'flat':
        rows = gen_flat(w, h, (17, 42, 200))
    elif kind == 'grad':
        rows = gen_gradient(w, h)
    elif kind == 'noise':
        rows = gen_noise(w, h, seed)
    elif kind == 'fbm':
        rows = gen_fbm(w, h, seed)
    elif kind == 'bands':
        rows = gen_bands(w, h)
    else:
        raise ValueError(kind)
    if bpp in (8, 4, 1):
        # restrict color count for tiny palettes
        if bpp == 1 and kind not in ('flat', 'bands'):
            kind = 'bands'
            rows = gen_bands(w, h, ncolors=2)
        elif bpp == 4 and kind not in ('flat', 'bands'):
            kind = 'bands'
            rows = gen_bands(w, h, ncolors=16)
        # quantize rows to palette indices
        n = {1: 2, 4: 16, 8: 256}[bpp]
        pal = []
        idx_of = {}
        def q(c):
            if c not in idx_of:
                if len(pal) < n:
                    idx_of[c] = len(pal); pal.append(c)
                else:
                    # palette full: fold the color onto an existing index
                    return (c[0] * 3 + c[1] * 5 + c[2] * 7) % len(pal)
            return idx_of[c]
        rows = [[q(c) for c in row] for row in rows]
        while len(pal) < n:
            pal.append((0, 0, 0))
        path = os.path.join(outdir, name)
        write_bmp(path, w, h, rows, palette=pal[:n], bpp=bpp, topdown=topdown)
        return path
    path = os.path.join(outdir, name)
    write_bmp(path, w, h, rows, bpp=bpp, topdown=topdown)
    return path

if __name__ == '__main__':
    import sys
    out = sys.argv[1] if len(sys.argv) > 1 else 'bmps'
    gen_bmp_all(out, 'flat.bmp',        256, 256, 'flat')
    gen_bmp_all(out, 'grad.bmp',        512, 384, 'grad')
    gen_bmp_all(out, 'noise.bmp',       256, 256, 'noise')
    gen_bmp_all(out, 'fbm.bmp',         640, 480, 'fbm')
    gen_bmp_all(out, 'bands.bmp',       400, 300, 'bands')
    gen_bmp_all(out, 'tiny1x1.bmp',     1, 1, 'flat')
    gen_bmp_all(out, 'tiny3x1.bmp',     3, 1, 'grad')
    gen_bmp_all(out, 'tiny1x3.bmp',     1, 3, 'grad')
    gen_bmp_all(out, 'odd101.bmp',      101, 37, 'bands')
    gen_bmp_all(out, 'topdown.bmp',     200, 100, 'grad', topdown=True)
    gen_bmp_all(out, 'pal8.bmp',        300, 200, 'bands', bpp=8)
    gen_bmp_all(out, 'pal4.bmp',        64, 64, 'bands', bpp=4)
    gen_bmp_all(out, 'pal1.bmp',        64, 64, 'flat', bpp=1)
    gen_bmp_all(out, 'bmp32.bmp',       256, 256, 'fbm', bpp=32)
    gen_bmp_all(out, 'topdown8.bmp',    128, 64, 'bands', bpp=8, topdown=True)
    print('generated:', out)
