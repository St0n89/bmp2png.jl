#!/usr/bin/env python3
"""Independent PNG verifier + BMP reference reader (stdlib only).

Verifies a PNG produced by bmp2png.jl against the source BMP:
  * signature, chunk CRCs, chunk order
  * IHDR fields, PLTE sanity
  * strictly zlib-decompresses IDAT: RFC 1950 header checked (CM=8,
    FCHECK % 31 == 0, FDICT clear) and the Adler-32 trailer verified
    against the decompressed bytes (zlib.decompress default mode, NOT
    raw -15 mode — raw mode silently accepts a headerless stream and
    masked exactly that bug in bmp2png.jl before commit 2)
  * unfilters all rows, reconstructs pixels
  * exact pixel comparison with an independent BMP parse
  * reports size vs zlib level 1/6/9 over the SAME filtered stream
    (isolates encoder quality from filter choice)
"""
import struct, sys, zlib, os

def read_bmp(path):
    b = open(path, 'rb').read()
    assert b[:2] == b'BM', 'not BMP'
    off = struct.unpack('<I', b[10:14])[0]
    w, h = struct.unpack('<ii', b[18:26])
    bpp = struct.unpack('<H', b[28:30])[0]
    comp = struct.unpack('<I', b[30:34])[0]
    assert comp == 0, 'BI_RGB only'
    topdown = h < 0
    h = abs(h)
    pal = []
    if bpp <= 8:
        n = struct.unpack('<I', b[46:50])[0] or (1 << bpp)
        for i in range(n):
            e = b[14 + 40 + 4 * i: 14 + 40 + 4 * i + 4]
            pal.append((e[2], e[1], e[0]))  # RGB
    rowsize = ((bpp * w + 31) // 32) * 4
    px = []
    alpha = []
    for row in range(h):
        src = row if topdown else (h - 1 - row)
        rb = off + src * rowsize
        prow = []
        arow = []
        for x in range(w):
            if bpp == 24:
                q = rb + 3 * x
                prow.append((b[q + 2], b[q + 1], b[q]))
            elif bpp == 32:
                q = rb + 4 * x
                prow.append((b[q + 2], b[q + 1], b[q]))
                arow.append(b[q + 3])
            else:
                if bpp == 8:
                    i = b[rb + x]
                elif bpp == 4:
                    byte = b[rb + (x >> 1)]
                    i = (byte >> 4) if x % 2 == 0 else (byte & 0xF)
                else:
                    byte = b[rb + (x >> 3)]
                    i = (byte >> (7 - (x & 7))) & 1
                prow.append(pal[i] if i < len(pal) else None)
        px.append(prow)
        if bpp == 32:
            alpha.append(arow)
    return dict(w=w, h=h, bpp=bpp, px=px, alpha=alpha if bpp == 32 else None)

def unfilter(data, stride, h, bpp):
    out = []
    prev = bytearray(stride)
    pos = 0
    for _ in range(h):
        f = data[pos]; pos += 1
        row = bytearray(data[pos:pos + stride]); pos += stride
        if f == 1:
            for x in range(bpp, stride):
                row[x] = (row[x] + row[x - bpp]) & 0xFF
        elif f == 2:
            for x in range(stride):
                row[x] = (row[x] + prev[x]) & 0xFF
        elif f == 3:
            for x in range(stride):
                a = row[x - bpp] if x >= bpp else 0
                row[x] = (row[x] + ((a + prev[x]) >> 1)) & 0xFF
        elif f == 4:
            for x in range(stride):
                a = row[x - bpp] if x >= bpp else 0
                c = prev[x - bpp] if x >= bpp else 0
                p = a + prev[x] - c
                pa, pb, pc = abs(p - a), abs(p - prev[x]), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (prev[x] if pb <= pc else c)
                row[x] = (row[x] + pr) & 0xFF
        assert f in (0, 1, 2, 3, 4), 'bad filter byte %d' % f
        out.append(bytes(row))
        prev = row
    return out

def read_png(path):
    b = open(path, 'rb').read()
    assert b[:8] == bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), 'bad signature'
    chunks = {}
    order = []
    idat = b''
    pos = 8
    while pos < len(b):
        ln = struct.unpack('>I', b[pos:pos + 4])[0]
        typ = b[pos + 4:pos + 8].decode('ascii')
        payload = b[pos + 8:pos + 8 + ln]
        crc = struct.unpack('>I', b[pos + 8 + ln:pos + 12 + ln])[0]
        calc = zlib.crc32(b[pos + 4:pos + 8 + ln]) & 0xFFFFFFFF
        assert crc == calc, 'CRC mismatch in chunk %s' % typ
        if typ == 'IDAT':
            idat += payload
        else:
            chunks[typ] = payload
        order.append(typ)
        pos += 12 + ln
    assert order[0] == 'IHDR' and order[-1] == 'IEND'
    w, h, depth, ctype, compm, filt, inter = struct.unpack('>IIBBBBB', chunks['IHDR'])
    assert depth == 8, 'bit depth %d unexpected' % depth
    assert compm == 0 and filt == 0 and inter == 0
    assert ctype in (0, 2, 3, 6), 'color type %d' % ctype
    bpp = {0: 1, 2: 3, 3: 1, 6: 4}[ctype]
    stride = w * bpp
    # strict RFC 1950 checks (raw -15 mode would silently accept a
    # headerless deflate stream — the exact bug this guards against)
    assert len(idat) >= 6, 'IDAT too short for a zlib stream'
    cmf, flg = idat[0], idat[1]
    assert (cmf & 0x0F) == 8, 'bad CM %d (not deflate)' % (cmf & 0x0F)
    assert ((cmf << 8) | flg) % 31 == 0, 'FCHECK failed (CMF/FLG not divisible by 31)'
    assert (flg & 0x20) == 0, 'FDICT set (preset dictionary not allowed in PNG)'
    data = zlib.decompress(idat)  # default mode: requires the zlib header
    assert zlib.adler32(data) & 0xFFFFFFFF == struct.unpack('>I', idat[-4:])[0], \
        'Adler-32 trailer mismatch'
    assert len(data) == h * (stride + 1), 'decompressed length %d != %d' % (len(data), h * (stride + 1))
    rows = unfilter(data, stride, h, bpp)
    return dict(w=w, h=h, ctype=ctype, rows=rows, idat=idat, data=data, plte=chunks.get('PLTE'))

def png_pixels(png):
    w, h, ctype, rows = png['w'], png['h'], png['ctype'], png['rows']
    px = []
    for r in range(h):
        row = rows[r]
        prow = []
        for x in range(w):
            if ctype == 0:
                g = row[x]; prow.append((g, g, g))
            elif ctype == 2:
                o = 3 * x; prow.append((row[o], row[o + 1], row[o + 2]))
            elif ctype == 3:
                i = row[x]
                p = png['plte']
                prow.append((p[3 * i], p[3 * i + 1], p[3 * i + 2]))
            else:
                o = 4 * x; prow.append((row[o], row[o + 1], row[o + 2], row[o + 3]))
        px.append(prow)
    return px

def alpha_handling_ok(bmp, png):
    """32-bit BMPs with all-zero or all-255 pad → opaque RGB; else RGBA exact."""
    a = bmp['alpha']
    if a is None:
        return None
    mn, mx = min(min(r) for r in a), max(max(r) for r in a)
    if mn == mx and mx in (0, 255):
        return 'opaque'
    return 'rgba'

def check(bmppath, pngpath, verbose=True):
    bmp = read_bmp(bmppath)
    png = read_png(pngpath)
    assert (bmp['w'], bmp['h']) == (png['w'], png['h']), 'dimensions differ'
    bppx = png['ctype']
    bpx = png_pixels(png)
    mode = alpha_handling_ok(bmp, png)
    ok = True
    for y in range(bmp['h']):
        for x in range(bmp['w']):
            bp = bmp['px'][y][x]
            pp = bpx[y][x]
            if mode == 'opaque' or bmp['bpp'] < 32:
                if pp[:3] != bp:
                    print('MISMATCH at (%d,%d): bmp=%s png=%s' % (x, y, bp, pp[:3]))
                    ok = False
                    if y * bmp['w'] + x > 50: return False
            else:
                ba = bmp['alpha'][y][x]
                if pp != (bp[0], bp[1], bp[2], ba):
                    print('MISMATCH at (%d,%d): bmp=%s+a%d png=%s' % (x, y, bp, ba, pp))
                    ok = False
                    if y * bmp['w'] + x > 50: return False
    if not ok:
        return False
    if verbose:
        insize = os.path.getsize(bmppath)
        pngsize = os.path.getsize(pngpath)
        idatz = len(png['idat'])
        ref = {}
        for lv in (1, 6, 9):
            ref[lv] = len(zlib.compress(png['data'], lv))
        print('%-16s %8d -> %8d B (%5.1f%%)  ctype=%d  IDAT: ours=%d  zlib1=%d zlib6=%d zlib9=%d' %
              (os.path.basename(pngpath), insize, pngsize, 100.0 * pngsize / insize,
               png['ctype'], idatz, ref[1], ref[6], ref[9]))
    return True

if __name__ == '__main__':
    if sys.argv[1] == '--check':
        ok = check(sys.argv[2], sys.argv[3])
        print('PASS' if ok else 'FAIL')
        sys.exit(0 if ok else 1)
