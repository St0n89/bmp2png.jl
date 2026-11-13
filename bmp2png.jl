#!/usr/bin/env julia
# =============================================================================
# bmp2png.jl — handwritten BMP → PNG converter
#
# Pure Julia stdlib (only Printf). No packages, no external tools.
#
# Usage:
#   julia bmp2png.jl file.bmp [more.bmp ...] [--level N] [--outdir DIR]
#
#     --level N    DEFLATE effort 1..9 (default 9). Level table follows zlib's
#                  tuned good/lazy/nice/chain parameters.
#     --outdir DIR Write PNGs to DIR (default: next to each input).
#
# What's inside (everything hand-written):
#   * BMP reader: BI_RGB, 1/4/8/24/32-bit, bottom-up and top-down, V4/V5
#     DIB headers, palettes, row padding.
#   * PNG mode reduction: <=256 colors → indexed (color type 3),
#     R==G==B everywhere → grayscale (type 0), else RGB/RGBA.
#   * Adaptive filtering: all 5 PNG filters tried per scanline, chosen by
#     entropy of the filtered bytes (oxipng-style adaptive filtering).
#   * DEFLATE encoder:
#       - LZ77: 32 KiB window, 15-bit multiplicative hash, hash chains,
#         lazy matching (zlib deflate_slow), zlib's level parameter table
#         (level 9 tuned deeper: chain 8192), 32768-token blocks.
#       - Dynamic Huffman per block: two-queue optimal tree, length limiting
#         by clamping + Kraft repair, canonical codes, bit-reversed codes.
#       - Precode (code-length) stream with RLE symbols 16/17/18.
#       - Per block: dynamic vs static vs stored, cheapest wins (zlib-style).
#   * IDAT is a proper RFC 1950 zlib stream: 2-byte header (CMF/FLG,
#     FLEVEL mirrors the chosen level, (CMF<<8|FLG) % 31 == 0) around
#     the raw DEFLATE, plus a big-endian Adler-32 trailer over the
#     UNCOMPRESSED filtered stream.
#
# Output is verified against an independent Python decoder (see test/).
# =============================================================================

using Printf

# -----------------------------------------------------------------------------
# Section 1: CRC-32 (IEEE 802.3, reflected, poly 0xEDB88320) — PNG chunks
# -----------------------------------------------------------------------------

const CRC_TABLE = let
    t = Vector{UInt32}(undef, 256)
    for n in 0:255
        c = UInt32(n)
        for _ in 1:8
            c = (c & 1) == 1 ? (c >>> 1) ⊻ 0xEDB88320 : (c >>> 1)
        end
        t[n + 1] = c
    end
    t
end

function crc32(b::Vector{UInt8}, from::Int = 1, to::Int = length(b))::UInt32
    c = 0xFFFFFFFF
    @inbounds for i in from:to
        c = CRC_TABLE[((c ⊻ UInt32(b[i])) & 0xFF) + 1] ⊻ (c >>> 8)
    end
    return c ⊻ 0xFFFFFFFF
end

# -----------------------------------------------------------------------------
# Section 1b: Adler-32 (RFC 1950) + zlib stream wrapper
# -----------------------------------------------------------------------------

# Adler-32 over b. NMAX=5552 is the largest block with 255*n*(n+2)/2 + (n+1)
# still below 2^32, so a and s can be reduced once per block (zlib's trick).
function adler32(b::Vector{UInt8})::UInt32
    a = UInt32(1); s = UInt32(0)
    i = 1; n = length(b)
    @inbounds while i ≤ n
        block = min(n - i + 1, 5552)
        for _ in 1:block
            a += UInt32(b[i]); s += a; i += 1
        end
        a %= 65521; s %= 65521
    end
    return (s << 16) | a
end

# FLG byte for a zlib (RFC 1950) header at the given deflate level.
# FLEVEL mirrors zlib's convention: 0 for level 1, 1 for 2-5, 2 for 6,
# 3 for 7-9. (CMF<<8 | FLG) % 31 == 0 for every returned value.
function zlib_flg(level::Int)::UInt8
    level == 1 && return 0x01
    level ≤ 5 && return 0x5E
    level == 6 && return 0x9C
    return 0xDA
end

# Wrap raw DEFLATE output as a zlib (RFC 1950) stream. The Adler-32
# trailer is computed over src, the UNCOMPRESSED data (not over raw).
function zlib_wrap(raw::Vector{UInt8}, src::Vector{UInt8}, level::Int)::Vector{UInt8}
    out = Vector{UInt8}(undef, length(raw) + 6)
    out[1] = 0x78                     # CMF: CM=8 (deflate), CINFO=7 (32 KiB window)
    out[2] = zlib_flg(level)
    for i in 1:length(raw)
        out[2 + i] = raw[i]
    end
    ad = adler32(src)
    out[end - 3] = UInt8((ad >>> 24) & 0xFF)   # big-endian, RFC 1950
    out[end - 2] = UInt8((ad >>> 16) & 0xFF)
    out[end - 1] = UInt8((ad >>> 8) & 0xFF)
    out[end]     = UInt8(ad & 0xFF)
    return out
end

# -----------------------------------------------------------------------------
# Section 2: little/big endian helpers
# -----------------------------------------------------------------------------

@inline u16le(b::Vector{UInt8}, i::Int) = UInt16(b[i]) | (UInt16(b[i+1]) << 8)
@inline u32le(b::Vector{UInt8}, i::Int) =
    UInt32(b[i]) | (UInt32(b[i+1]) << 8) | (UInt32(b[i+2]) << 16) | (UInt32(b[i+3]) << 24)
@inline i32le(b::Vector{UInt8}, i::Int) = reinterpret(Int32, u32le(b, i))

@inline function push_u32be!(v::Vector{UInt8}, x::UInt32)
    push!(v, UInt8((x >>> 24) & 0xFF))
    push!(v, UInt8((x >>> 16) & 0xFF))
    push!(v, UInt8((x >>> 8) & 0xFF))
    push!(v, UInt8(x & 0xFF))
    return v
end

# -----------------------------------------------------------------------------
# Section 3: BMP reader → (w, h, RGB triplets, palette-or-nothing, alpha-or-nothing)
# -----------------------------------------------------------------------------

function read_bmp(path::String)
    b = try
        read(path)
    catch
        error("cannot read BMP: $(path)")
    end
    length(b) ≥ 54 || error("not a BMP (too short): $(path)")
    (b[1] == 0x42 && b[2] == 0x4D) || error("not a BMP (magic): $(path)")
    off = Int(u32le(b, 11))          # bfOffBits
    dib = Int(u32le(b, 15))          # biSize
    dib in (40, 108, 124) || error("unsupported DIB header size $(dib) (BI_RGB only)")
    w = Int(i32le(b, 19))
    hraw = i32le(b, 23)
    bpp = Int(u16le(b, 29))
    comp = u32le(b, 31)
    comp == 0 || error("only BI_RGB (uncompressed) BMPs supported, got compression=$(comp)")
    (w > 0 && hraw != 0) || error("degenerate BMP dimensions")
    topdown = hraw < 0
    h = abs(Int(hraw))
    bpp in (1, 4, 8, 24, 32) || error("unsupported bit depth $(bpp)")

    pal = UInt8[]                       # RGB triplets, only for bpp <= 8
    if bpp ≤ 8
        ncol = Int(u32le(b, 47))        # biClrUsed
        (ncol == 0 || ncol > 2^bpp) && (ncol = 2^bpp)
        pbase = 14 + dib
        length(b) ≥ pbase + 4 * ncol || error("truncated palette")
        for i in 0:(ncol - 1)
            push!(pal, b[pbase + 4*i + 3])   # R
            push!(pal, b[pbase + 4*i + 2])   # G
            push!(pal, b[pbase + 4*i + 1])   # B
        end
    end

    rowsize = ((bpp * w + 31) ÷ 32) * 4
    length(b) ≥ off + rowsize * h || error("truncated pixel data (need $(off + rowsize*h) B, have $(length(b)))")

    pix = Vector{UInt8}(undef, w * h * 3)          # RGB, top row first
    alpha = bpp == 32 ? Vector{UInt8}(undef, w * h) : UInt8[]
    d = off + 1                                     # 1-based data start

    for row in 0:(h - 1)
        srcrow = topdown ? row : (h - 1 - row)
        rb = d + srcrow * rowsize
        po = (row * w + 1) * 3 - 2                  # pix offset, 1-based, *3 stride
        if bpp == 24
            for x in 0:(w - 1)
                q = rb + 3 * x
                pix[po + 3*x]     = b[q + 2]        # R (file order is B,G,R)
                pix[po + 3*x + 1] = b[q + 1]
                pix[po + 3*x + 2] = b[q]
            end
        elseif bpp == 32
            ao = row * w + 1
            for x in 0:(w - 1)
                q = rb + 4 * x
                pix[po + 3*x]     = b[q + 2]
                pix[po + 3*x + 1] = b[q + 1]
                pix[po + 3*x + 2] = b[q]
                alpha[ao + x]     = b[q + 3]
            end
        elseif bpp == 8
            for x in 0:(w - 1)
                i = Int(b[rb + x]) * 3
                (i + 2 ≤ length(pal)) || error("pixel $(x),$(row): palette index out of range")
                pix[po + 3*x]     = pal[i + 1]
                pix[po + 3*x + 1] = pal[i + 2]
                pix[po + 3*x + 2] = pal[i + 3]
            end
        elseif bpp == 4
            for x in 0:(w - 1)
                byte = b[rb + (x >> 1)]
                i = (x & 1) == 0 ? (byte >> 4) : (byte & 0x0F)
                i = Int(i) * 3
                (i + 2 ≤ length(pal)) || error("pixel $(x),$(row): palette index out of range")
                pix[po + 3*x]     = pal[i + 1]
                pix[po + 3*x + 1] = pal[i + 2]
                pix[po + 3*x + 2] = pal[i + 3]
            end
        else # bpp == 1
            for x in 0:(w - 1)
                byte = b[rb + (x >> 3)]
                bit = (byte >> (7 - (x & 7))) & 1
                i = Int(bit) * 3
                (i + 2 ≤ length(pal)) || error("pixel $(x),$(row): palette index out of range")
                pix[po + 3*x]     = pal[i + 1]
                pix[po + 3*x + 1] = pal[i + 2]
                pix[po + 3*x + 2] = pal[i + 3]
            end
        end
    end
    return (w = w, h = h, pix = pix, pal = pal, alpha = alpha)
end

# -----------------------------------------------------------------------------
# Section 4: DEFLATE tables (length/distance codes, static trees)
# -----------------------------------------------------------------------------

# len (3..258) -> (code 257..285, extra bits, base value)
const LEN_CODE  = Vector{UInt16}(undef, 259)
const LEN_EBITS = Vector{UInt8}(undef, 259)
const LEN_EVAL  = Vector{UInt8}(undef, 259)
let
    bases = [257, 258, 259, 260, 261, 262, 263, 264, 265, 266, 267, 268, 269, 270,
             271, 272, 273, 274, 275, 276, 277, 278, 279, 280, 281, 282, 283, 284, 285]
    lbases = [3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,
              163,195,227,258]
    lebits = [0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0]
    for c in 1:29
        code = bases[c]; lo = lbases[c]; eb = lebits[c]
        hi = (c == 29) ? 258 : lbases[c+1] - 1
        for l in lo:hi
            LEN_CODE[l]  = UInt16(code)
            LEN_EBITS[l] = UInt8(eb)
            LEN_EVAL[l]  = UInt8(l - lo)
        end
    end
end

# dist (1..32768) -> (code 0..29, extra bits, base value)
const DIST_CODE  = Vector{UInt8}(undef, 32769)
const DIST_EBITS = Vector{UInt8}(undef, 32769)
const DIST_EVAL  = Vector{UInt16}(undef, 32769)
let
    dbases = [1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,
              1025,1537,2049,3073,4097,6145,8193,12289,16385,24577]
    debits = [0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13]
    for c in 1:30
        lo = dbases[c]; eb = debits[c]
        hi = (c == 30) ? 32768 : dbases[c+1] - 1
        for d in lo:hi
            DIST_CODE[d]  = UInt8(c - 1)
            DIST_EBITS[d] = UInt8(eb)
            DIST_EVAL[d]  = UInt16(d - lo)
        end
    end
end

# static (fixed) Huffman code lengths, RFC 1951 3.2.6
const STATIC_LL_LEN = vcat(fill(UInt8(8), 144), fill(UInt8(9), 112),
                           fill(UInt8(7), 24), fill(UInt8(8), 8))   # 288
const STATIC_DL_LEN = fill(UInt8(5), 30)

# -----------------------------------------------------------------------------
# Section 5: Huffman tree building (two-queue, length-limited, canonical)
# -----------------------------------------------------------------------------

# build optimal length-limited code lengths via package-merge
# (Hirschberg-Larmore). Always yields a COMPLETE code with depth <= maxbits,
# unlike clamp+repair which can land on incomplete codes for skewed trees.
# Caller guarantees >= 2 nonzero symbols (force_two!).
function huff_lengths(freq::Vector{UInt32}, maxbits::Int)::Vector{UInt8}
    n = length(freq)
    L = zeros(UInt8, n)
    syms = Int[s for s in 0:(n - 1) if freq[s + 1] > 0]
    ns = length(syms)
    if ns == 0
        return L
    elseif ns == 1
        L[syms[1] + 1] = 1                # single-symbol code (length-1)
        return L
    end
    sort!(syms, by = s -> (freq[s + 1], s))

    # items: (weight, isleaf, leafsym_or_pkgidx, level)
    # level 1: the sorted leaves
    weights = Vector{Int}(undef, ns)          # leaf weight lookup
    for k in 1:ns
        weights[k] = Int(freq[syms[k] + 1])
    end
    # items per level: tuples (w, kind, ref) kind: 1=leaf(k), 2=package(index into pkg arrays)
    pkg_children = Vector{Tuple{Int,Int}}()   # (left_item_level, left_item_idx)… we store refs per level
    level_items = Vector{Vector{Tuple{Int,Int,Int}}}(undef, maxbits + 1)
    level_items[1] = Tuple{Int,Int,Int}[(weights[k], 1, k) for k in 1:ns]
    # pkg_refs[level] maps package idx -> (idx of child A, idx of child B in level-1 list)
    pkg_refs = Vector{Vector{Tuple{Int,Int}}}(undef, maxbits + 1)
    for l in 2:maxbits
        prev = level_items[l - 1]
        pkgs = Tuple{Int,Int,Int}[]
        refs = Tuple{Int,Int}[]
        i = 1
        while i + 1 ≤ length(prev)
            wa = prev[i][1]; wb = prev[i + 1][1]
            push!(refs, (i, i + 1))
            push!(pkgs, (wa + wb, 2, length(refs)))
            i += 2
        end
        pkg_refs[l] = refs
        merged = vcat(Tuple{Int,Int,Int}[(weights[k], 1, k) for k in 1:ns], pkgs)
        sort!(merged, by = t -> t[1])          # stable: leaves before packages on ties
        level_items[l] = merged
    end

    # select the cheapest 2ns-2 items at the top level; each selected item
    # adds 1 to the code length of every leaf it contains
    top = level_items[maxbits]
    want = 2 * ns - 2
    length(top) ≥ want || error("package-merge: too few items (internal error)")

    # iterative DFS over the selected items
    stack = Tuple{Int,Int}[]                   # (level, item index in level_items[level])
    for j in 1:want
        push!(stack, (maxbits, j))
    end
    while !isempty(stack)
        (lvl, idx) = pop!(stack)
        item = level_items[lvl][idx]
        if item[2] == 1
            L[syms[item[3]] + 1] += UInt8(1)
        else
            (ca, cb) = pkg_refs[lvl][item[3]]
            push!(stack, (lvl - 1, ca))
            push!(stack, (lvl - 1, cb))
        end
    end
    for k in 1:ns
        (1 ≤ Int(L[syms[k] + 1]) ≤ maxbits) || error("package-merge: bad length (internal error)")
    end
    return L
end

# canonical codes from lengths (RFC 1951 3.2.2); also bit-reversed codes
function canonical_codes(L::Vector{UInt8}, maxbits::Int)
    n = length(L)
    codes = zeros(UInt32, n)
    rcodes = zeros(UInt32, n)
    cnt = zeros(Int, maxbits + 1)     # cnt[k+1] = #codes of length k
    for s in 1:n
        if L[s] > 0; cnt[L[s] + 1] += 1; end
    end
    nxt = zeros(UInt32, maxbits + 1)  # nxt[bits+1] = first code of length `bits`
    code = UInt32(0)
    for bits in 1:maxbits
        code = (code + UInt32(cnt[bits])) << 1   # cnt[bits] = count of length bits-1
        nxt[bits + 1] = code
    end
    for s in 1:n
        if L[s] > 0
            c = nxt[L[s] + 1]
            nxt[L[s] + 1] += 1
            codes[s] = c
            r = UInt32(0)
            for i in 0:(Int(L[s]) - 1)
                r = (r << 1) | ((c >> i) & 1)
            end
            rcodes[s] = r
        end
    end
    return codes, rcodes
end

# force at least two nonzero symbols (zlib's "tree must have two codes")
function force_two!(freq::Vector{UInt32})
    used = Int[s for s in 0:(length(freq) - 1) if freq[s + 1] > 0]
    if isempty(used)
        freq[1] += 1; freq[2] += 1
    elseif length(used) == 1
        s = used[1]
        d = (s == 0) ? 1 : 0
        freq[d + 1] += 1
    end
end

# -----------------------------------------------------------------------------
# Section 6: LSB-first bit writer
# -----------------------------------------------------------------------------

mutable struct BitWriter
    buf::Vector{UInt8}
    acc::UInt64
    cnt::UInt32
end
BitWriter() = BitWriter(UInt8[], 0, 0)

@inline function putbits!(w::BitWriter, v::Integer, nb::Integer)
    vv = UInt32(v); nn = UInt32(nb)
    m = (UInt64(1) << nn) - 1
    w.acc |= (UInt64(vv) & m) << w.cnt
    w.cnt += nn
    while w.cnt ≥ 8
        push!(w.buf, UInt8(w.acc & 0xFF))
        w.acc >>= 8
        w.cnt -= 8
    end
    return w
end

@inline function align_byte!(w::BitWriter)
    if w.cnt > 0
        push!(w.buf, UInt8(w.acc & 0xFF))
        w.acc = 0
        w.cnt = 0
    end
    return w
end

# -----------------------------------------------------------------------------
# Section 7: LZ77 tokenizer + block emitter (the DEFLATE core)
# -----------------------------------------------------------------------------

# zlib's tuned level table: (good_length, max_lazy, nice_length, max_chain)
const LEVEL_TABLE = [
    (4,   4,   8,    4),      # 1  (greedy)
    (4,   5,   16,   8),      # 2
    (4,   6,   32,   32),     # 3
    (4,   4,   16,   16),     # 4
    (8,   16,  32,   32),     # 5
    (8,   16,  128,  128),    # 6
    (8,   32,  128,  256),    # 7
    (32,  128, 258,  1024),   # 8
    (32,  258, 258,  8192),   # 9
]

const HASH_BITS = 15
const HASH_SIZE = 1 << HASH_BITS
const BLOCK_TOKENS = 32768
const WINDOW = 32768
const MIN_MATCH = 3
const MAX_MATCH = 258

mutable struct DeflateState
    src::Vector{UInt8}
    n::Int
    head::Vector{Int32}
    prev::Vector{Int32}
    # level params
    good::Int
    max_lazy::Int
    nice::Int
    max_chain::Int
    lazy::Bool
    # tokens (value: 0..255 literal, 259..514 = 256+len; dist 0 = literal)
    tv::Vector{UInt16}
    td::Vector{UInt16}
    tcount::Int
    tstart::Int
    lfreq::Vector{UInt32}         # 286
    dfreq::Vector{UInt32}         # 30
    extrabits::Int
    bstart::Int                   # src position where current block begins
    # stats
    nblocks::Int
    ndyn::Int
    nstatic::Int
    nstored::Int
end

function DeflateState(src::Vector{UInt8}, level::Int)
    cfg = LEVEL_TABLE[level]
    DeflateState(src, length(src),
        zeros(Int32, HASH_SIZE), zeros(Int32, max(length(src), 1)),
        cfg[1], cfg[2], cfg[3], cfg[4], level ≥ 4,
        UInt16[], UInt16[], 0, 0,
        zeros(UInt32, 286), zeros(UInt32, 30), 0, 1,
        0, 0, 0, 0)
end

@inline function hash3(src::Vector{UInt8}, i::Int)::Int
    h = (UInt32(src[i]) << 16) | (UInt32(src[i+1]) << 8) | UInt32(src[i+2])
    h = h * 0x9E3779B1
    return Int((h >>> (32 - HASH_BITS)) & (HASH_SIZE - 1)) + 1
end

@inline function insert_pos!(st::DeflateState, p::Int)
    p + 2 ≤ st.n || return
    h = hash3(st.src, p)
    st.prev[p] = st.head[h]
    st.head[h] = p
end

# find best match at position i, and insert i into the hash chains
function find_match!(st::DeflateState, i::Int)
    src = st.src
    n = st.n
    if i + 2 > n
        return (0, 0)
    end
    h = hash3(src, i)
    cand = st.head[h]
    st.prev[i] = cand
    st.head[h] = i
    (cand == 0) && return (0, 0)

    limit = i - WINDOW
    maxlen = min(MAX_MATCH, n - i + 1)
    best_len = 0
    best_dist = 0
    chain = st.max_chain
    reduced = false
    @inbounds while cand > limit && cand != 0 && chain > 0
        if src[cand] == src[i] && src[cand+1] == src[i+1] && src[cand+2] == src[i+2]
            # fast reject: match must be able to beat best_len
            if best_len == 0 || (best_len < maxlen && src[cand + best_len] == src[i + best_len])
                l = 3
                while l < maxlen && src[cand + l] == src[i + l]
                    l += 1
                end
                if l > best_len
                    best_len = l
                    best_dist = i - cand
                    if l ≥ st.nice || l ≥ maxlen
                        break
                    end
                    if !reduced && l ≥ st.good
                        chain = min(chain, st.max_chain >> 2)
                        reduced = true
                    end
                end
            end
        end
        cand = st.prev[cand]
        chain -= 1
    end
    return best_len ≥ MIN_MATCH ? (best_len, best_dist) : (0, 0)
end

@inline function emit_token!(st::DeflateState, v::UInt16, dist::UInt16)
    st.tcount += 1
    push!(st.tv, v)
    push!(st.td, dist)
    if v ≤ 255
        st.lfreq[v + 1] += 1
    else
        l = Int(v) - 256
        st.lfreq[LEN_CODE[l] + 1] += 1
        st.extrabits += Int(LEN_EBITS[l])
        d = Int(dist)
        st.dfreq[DIST_CODE[d] + 1] += 1
        st.extrabits += Int(DIST_EBITS[d])
    end
    return nothing
end

# --- precode stream: RLE over concatenated code lengths with symbols 16/17/18 ---

function build_precode(total::Vector{UInt8})
    pfreq = zeros(UInt32, 19)
    ops = Tuple{UInt8,UInt32,UInt32,UInt8}[]   # (presym, extra, extrabits, _unused)
    n = length(total)
    i = 1
    while i ≤ n
        v = total[i]
        run = 1
        while i + run ≤ n && total[i + run] == v
            run += 1
        end
        if v == 0
            r = run
            while r ≥ 3
                if r ≥ 11
                    k = min(r, 138)
                    pfreq[19] += 1
                    push!(ops, (0x12, UInt32(k - 11), 7, 0x00))
                    r -= k
                else
                    k = r                     # 3..10
                    pfreq[18] += 1
                    push!(ops, (0x11, UInt32(k - 3), 3, 0x00))
                    r -= k
                end
            end
            for _ in 1:r
                pfreq[1] += 1                 # literal zero
                push!(ops, (0x00, 0, 0, 0x00))
            end
        else
            pfreq[v + 1] += 1
            push!(ops, (v, 0, 0, 0x00))       # literal length
            r = run - 1
            while r ≥ 3
                k = min(r, 6)
                pfreq[17] += 1
                push!(ops, (0x10, UInt32(k - 3), 2, 0x00))
                r -= k
            end
            for _ in 1:r
                pfreq[v + 1] += 1
                push!(ops, (v, 0, 0, 0x00))
            end
        end
        i += run
    end
    return pfreq, ops
end

const PRECODE_ORDER = UInt8[16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

# --- one block: decide dynamic vs static vs stored, emit cheapest ---

function flush_block!(bw::BitWriter, st::DeflateState, final::Bool, upto::Int)
    t0 = st.tstart + 1
    t1 = st.tcount
    st.lfreq[257] += 1                        # EOB symbol 256
    force_two!(st.lfreq)
    force_two!(st.dfreq)

    litL = huff_lengths(st.lfreq, 15)
    distL = huff_lengths(st.dfreq, 15)
    _, litR = canonical_codes(litL, 15)
    _, distR = canonical_codes(distL, 15)

    # number of code lengths to emit (decoder reads exactly these)
    nlit = 257
    for s in 286:-1:258
        if litL[s] > 0; nlit = s; break; end
    end
    ndist = 1
    for s in 30:-1:2
        if distL[s] > 0; ndist = s; break; end
    end

    # precode over the trimmed length arrays (exactly nlit + ndist entries)
    pfreq, ops = build_precode(vcat(litL[1:nlit], distL[1:ndist]))
    force_two!(pfreq)
    preL = huff_lengths(pfreq, 7)
    _, preR = canonical_codes(preL, 7)
    hclen = 4
    for j in 19:-1:4
        if preL[PRECODE_ORDER[j] + 1] > 0
            hclen = j
            break
        end
    end
    pre_extra = 0
    for op in ops
        pre_extra += Int(op[3])
    end
    dyn_bits = 3 + 5 + 5 + 4 + 3 * hclen
    for s in 1:19
        if pfreq[s] > 0
            dyn_bits += Int(pfreq[s]) * Int(preL[s])
        end
    end
    dyn_bits += pre_extra
    for s in 1:286
        if st.lfreq[s] > 0
            dyn_bits += Int(st.lfreq[s]) * Int(litL[s])
        end
    end
    for s in 1:30
        if st.dfreq[s] > 0
            dyn_bits += Int(st.dfreq[s]) * Int(distL[s])
        end
    end
    dyn_bits += st.extrabits

    # static cost
    stat_bits = 3 + st.extrabits
    for s in 1:286
        if st.lfreq[s] > 0
            stat_bits += Int(st.lfreq[s]) * Int(STATIC_LL_LEN[s])
        end
    end
    for s in 1:30
        if st.dfreq[s] > 0
            stat_bits += Int(st.dfreq[s]) * 5
        end
    end

    # stored cost (upper bound: assume 7 pad bits)
    nbytes = upto - st.bstart
    nchunks = max(1, (nbytes + 65534) ÷ 65535)
    stored_bits = 3 + 7 + 8 * (4 * nchunks + nbytes)

    st.nblocks += 1
    if stored_bits < dyn_bits && stored_bits < stat_bits
        # ---- stored: each <=65535-byte chunk is its OWN block (own header) ----
        st.nstored += 1
        if nbytes == 0
            putbits!(bw, final ? 1 : 0, 1)
            putbits!(bw, 0, 2)
            align_byte!(bw)
            append!(bw.buf, reinterpret(UInt8, [UInt16(0)]))
            append!(bw.buf, reinterpret(UInt8, [UInt16(0xFFFF)]))
        else
            o = st.bstart
            last = upto - 1
            while o ≤ last
                chunk = min(65535, last - o + 1)
                isfinal = final && (o + chunk > last)
                putbits!(bw, isfinal ? 1 : 0, 1)
                putbits!(bw, 0, 2)
                align_byte!(bw)
                append!(bw.buf, reinterpret(UInt8, [UInt16(chunk)]))
                append!(bw.buf, reinterpret(UInt8, [UInt16(chunk ⊻ 0xFFFF)]))
                append!(bw.buf, @view st.src[o:(o + chunk - 1)])
                o += chunk
            end
        end
    elseif stat_bits ≤ dyn_bits
        # ---- static Huffman ----
        st.nstatic += 1
        putbits!(bw, final ? 1 : 0, 1)
        putbits!(bw, 1, 2)
        emit_tokens!(bw, st, t0, t1, STATIC_LL_LEN, STATIC_DL_LEN,
            STATIC_LL_RC, STATIC_DL_RC, true)
    else
        # ---- dynamic Huffman ----
        st.ndyn += 1
        putbits!(bw, final ? 1 : 0, 1)
        putbits!(bw, 2, 2)
        putbits!(bw, UInt32(nlit - 257), 5)
        putbits!(bw, UInt32(ndist - 1), 5)
        putbits!(bw, UInt32(hclen - 4), 4)
        for j in 1:hclen
            putbits!(bw, UInt32(preL[PRECODE_ORDER[j] + 1]), 3)
        end
        for op in ops
            p = op[1]
            putbits!(bw, preR[p + 1], UInt32(preL[p + 1]))
            if op[3] > 0
                putbits!(bw, op[2], op[3])
            end
        end
        emit_tokens!(bw, st, t0, t1, litL, distL, litR, distR, false)
    end

    # reset block state
    fill!(st.lfreq, 0)
    fill!(st.dfreq, 0)
    st.extrabits = 0
    st.tstart = st.tcount
    st.bstart = upto
    return nothing
end

# static dist codes: all 5 bits, canonical 0..29 — precompute reversed
const STATIC_LL_RC = let
    _, rc = canonical_codes(STATIC_LL_LEN, 9)
    rc
end
const STATIC_DL_RC = let
    _, rc = canonical_codes(STATIC_DL_LEN, 5)
    rc
end

# emit the token stream using the given code tables
function emit_tokens!(bw::BitWriter, st::DeflateState, t0::Int, t1::Int,
                      litL::Vector{UInt8}, distL::Vector{UInt8},
                      litR::Vector{UInt32}, distR::Vector{UInt32},
                      static_mode::Bool)
    for t in t0:t1
        v = st.tv[t]
        if v ≤ 255
            if static_mode
                l = Int(STATIC_LL_LEN[v + 1])
                putbits!(bw, STATIC_LL_RC[v + 1], UInt32(l))
            else
                putbits!(bw, litR[v + 1], UInt32(litL[v + 1]))
            end
        else
            l = Int(v) - 256
            c = LEN_CODE[l]                       # 257..285
            if static_mode
                sl = Int(STATIC_LL_LEN[c + 1])
                putbits!(bw, STATIC_LL_RC[c + 1], UInt32(sl))
            else
                putbits!(bw, litR[c + 1], UInt32(litL[c + 1]))
            end
            eb = LEN_EBITS[l]
            eb > 0 && putbits!(bw, UInt32(LEN_EVAL[l]), UInt32(eb))
            d = Int(st.td[t])
            dc = DIST_CODE[d]                      # 0..29
            if static_mode
                putbits!(bw, STATIC_DL_RC[dc + 1], 5)
            else
                putbits!(bw, distR[dc + 1], UInt32(distL[dc + 1]))
            end
            deb = DIST_EBITS[d]
            deb > 0 && putbits!(bw, UInt32(DIST_EVAL[d]), UInt32(deb))
        end
    end
    # end-of-block symbol 256, AFTER all tokens
    if static_mode
        putbits!(bw, STATIC_LL_RC[257], 7)
    else
        putbits!(bw, litR[257], UInt32(litL[257]))
    end
    return nothing
end

# --- top-level deflate ---

function deflate(src::Vector{UInt8}, level::Int)
    bw = BitWriter()
    n = length(src)
    st = DeflateState(src, level)
    if n == 0
        flush_block!(bw, st, true, 1)
        align_byte!(bw)
        return bw.buf, st
    end
    i = 1
    ins = 0                                     # highest inserted position
    while i ≤ n
        # block boundary?
        if st.tcount - st.tstart ≥ BLOCK_TOKENS
            flush_block!(bw, st, false, i)
        end
        ml, md = find_match!(st, i)
        ins = max(ins, i)
        if st.lazy && ml ≥ MIN_MATCH && ml < st.max_lazy && i + 3 ≤ n
            # lazy: look ahead one position
            ml2, md2 = find_match!(st, i + 1)
            ins = max(ins, i + 1)
            if ml2 > ml
                emit_token!(st, UInt16(src[i]), UInt16(0))
                i += 1
                ml, md = ml2, md2
                while st.lazy && ml ≥ MIN_MATCH && ml < st.max_lazy && i + 2 ≤ n
                    ml2, md2 = find_match!(st, i + 1)
                    ins = max(ins, i + 1)
                    if ml2 > ml
                        emit_token!(st, UInt16(src[i]), UInt16(0))
                        i += 1
                        ml, md = ml2, md2
                    else
                        break
                    end
                end
            end
        end
        if ml ≥ MIN_MATCH
            emit_token!(st, UInt16(256 + ml), UInt16(md))
            for p in (ins + 1):(i + ml - 1)
                insert_pos!(st, p)
            end
            ins = i + ml - 1
            i += ml
        else
            emit_token!(st, UInt16(src[i]), UInt16(0))
            i += 1
        end
    end
    flush_block!(bw, st, true, n + 1)
    align_byte!(bw)
    return bw.buf, st
end

# -----------------------------------------------------------------------------
# Section 8: PNG mode selection + adaptive filtering
# -----------------------------------------------------------------------------

@inline function paeth(a::UInt8, b::UInt8, c::UInt8)::UInt8
    p = Int(a) + Int(b) - Int(c)
    pa = abs(p - Int(a)); pb = abs(p - Int(b)); pc = abs(p - Int(c))
    if pa ≤ pb && pa ≤ pc
        return a
    elseif pb ≤ pc
        return b
    else
        return c
    end
end

# choose filter per scanline by entropy; write filtered stream (filter byte + row)
function filter_stream(px::Vector{UInt8}, w::Int, h::Int, bpp::Int)
    stride = w * bpp
    out = Vector{UInt8}(undef, h * (stride + 1))
    cur = Vector{UInt8}(undef, stride)
    prev = zeros(UInt8, stride)
    fb = Vector{UInt8}(undef, stride)
    best = Vector{UInt8}(undef, stride)
    fhist = zeros(Int, 5)

    for r in 0:(h - 1)
        ro = r * stride + 1
        @inbounds for x in 1:stride
            cur[x] = px[ro + x - 1]
        end
        bestf = 0
        bestcost = typemax(Float64)
        for f in 0:4
            @inbounds if f == 0
                cost = 0.0
                hist = zeros(Int, 256)
                for x in 1:stride
                    hist[px[ro + x - 1] + 1] += 1
                end
                for c in 1:256
                    if hist[c] > 0
                        cost -= hist[c] * log(hist[c])
                    end
                end
                fb = px[ro:(ro + stride - 1)]
            elseif f == 1
                cost = 0.0
                hist = zeros(Int, 256)
                for x in 1:stride
                    v = x ≤ bpp ? cur[x] : cur[x] - cur[x - bpp]
                    fb[x] = v
                    hist[v + 1] += 1
                end
                for c in 1:256
                    if hist[c] > 0
                        cost -= hist[c] * log(hist[c])
                    end
                end
            elseif f == 2
                cost = 0.0
                hist = zeros(Int, 256)
                for x in 1:stride
                    v = cur[x] - prev[x]
                    fb[x] = v
                    hist[v + 1] += 1
                end
                for c in 1:256
                    if hist[c] > 0
                        cost -= hist[c] * log(hist[c])
                    end
                end
            elseif f == 3
                cost = 0.0
                hist = zeros(Int, 256)
                for x in 1:stride
                    left = x ≤ bpp ? UInt8(0) : cur[x - bpp]
                    v = cur[x] - UInt8((UInt32(left) + UInt32(prev[x])) >> 1)
                    fb[x] = v
                    hist[v + 1] += 1
                end
                for c in 1:256
                    if hist[c] > 0
                        cost -= hist[c] * log(hist[c])
                    end
                end
            else
                cost = 0.0
                hist = zeros(Int, 256)
                for x in 1:stride
                    left = x ≤ bpp ? UInt8(0) : cur[x - bpp]
                    upleft = x ≤ bpp ? UInt8(0) : prev[x - bpp]
                    v = cur[x] - paeth(left, prev[x], upleft)
                    fb[x] = v
                    hist[v + 1] += 1
                end
                for c in 1:256
                    if hist[c] > 0
                        cost -= hist[c] * log(hist[c])
                    end
                end
            end
            if cost < bestcost
                bestcost = cost
                bestf = f
                @inbounds for x in 1:stride
                    best[x] = fb[x]
                end
            end
        end
        fhist[bestf + 1] += 1
        oo = r * (stride + 1) + 1
        out[oo] = UInt8(bestf)
        @inbounds for x in 1:stride
            out[oo + x] = best[x]
        end
        @inbounds for x in 1:stride
            prev[x] = cur[x]
        end
    end
    return out, fhist
end

# -----------------------------------------------------------------------------
# Section 9: PNG chunk writer
# -----------------------------------------------------------------------------

function push_chunk!(out::Vector{UInt8}, typ::String, payload::Vector{UInt8})
    push_u32be!(out, UInt32(length(payload)))
    p = length(out) + 1
    for c in typ
        push!(out, UInt8(c))
    end
    append!(out, payload)
    c = crc32(out, p)             # CRC over type+payload
    push_u32be!(out, c)
    return out
end

# -----------------------------------------------------------------------------
# Section 10: top-level conversion
# -----------------------------------------------------------------------------

mutable struct Ctx
    nblocks::Int
    ndyn::Int
    nstatic::Int
    nstored::Int
    fhist::Vector{Int}
end
Ctx() = Ctx(0, 0, 0, 0, zeros(Int, 5))

function convert_bmp_png(inpath::String, outpath::String, level::Int, ctx::Ctx)
    t0 = time_ns()
    img = read_bmp(inpath)
    w, h, pix, pal, alpha = img.w, img.h, img.pix, img.pal, img.alpha

    # --- decide PNG color mode ---
    mode = "rgb"
    idx = UInt8[]
    plte = UInt8[]
    use_alpha = false
    if !isempty(alpha)
        amin, amax = extrema(alpha)
        use_alpha = !(amax == 0 || (amin == 0 && amax == 0) || (amin == 255 && amax == 255))
        # note: fully-zero pad bytes (BI_RGB padding) or fully-255 → opaque
        if amin == 255 && amax == 255
            use_alpha = false
        end
    end

    gray = false
    if !isempty(pal)
        # paletted BMP → indexed PNG
        mode = "indexed"
        plte = pal
        idx = Vector{UInt8}(undef, w * h)
        seen = Dict{UInt32,UInt8}()
        pmap = UInt8[]
        po = 1
        for p in 1:(w * h)
            key = UInt32(pix[po]) << 16 | UInt32(pix[po+1]) << 8 | UInt32(pix[po+2])
            gi = get(seen, key, UInt8(255))
            if gi == 255
                gi = UInt8(length(pmap) ÷ 3)          # pmap is a flat RGB byte array
                seen[key] = gi
                push!(pmap, pix[po], pix[po+1], pix[po+2])
                plte = pmap
            end
            idx[p] = gi
            po += 3
        end
    elseif use_alpha
        mode = "rgba"
    else
        # count distinct colors (early abort above 256)
        seen = Vector{Bool}(undef, 1 << 24)
        fill!(seen, false)
        ncol = 0
        po = 1
        @inbounds for _ in 1:(w * h)
            key = (UInt32(pix[po]) << 16) | (UInt32(pix[po+1]) << 8) | UInt32(pix[po+2])
            if !seen[key + 1]
                seen[key + 1] = true
                ncol += 1
                ncol > 256 && break
            end
            po += 3
        end
        if ncol ≤ 256
            mode = "indexed"
            plte = Vector{UInt8}()
            seen2 = Dict{UInt32,UInt8}()
            idx = Vector{UInt8}(undef, w * h)
            po = 1
            for p in 1:(w * h)
                key = (UInt32(pix[po]) << 16) | (UInt32(pix[po+1]) << 8) | UInt32(pix[po+2])
                gi = get(seen2, key, UInt8(255))
                if gi == 255
                    gi = UInt8(length(plte) ÷ 3)
                    seen2[key] = gi
                    push!(plte, pix[po], pix[po+1], pix[po+2])
                end
                idx[p] = gi
                po += 3
            end
        else
            # grayscale?
            gray = true
            @inbounds for p in 1:(w * h)
                if pix[3*p - 2] != pix[3*p - 1] || pix[3*p - 1] != pix[3*p]
                    gray = false
                    break
                end
            end
            mode = gray ? "gray" : "rgb"
        end
    end

    # --- build scanline pixels ---
    if mode == "indexed"
        pxdata = idx
        pbpp = 1
        colortype = UInt8(3)
    elseif mode == "gray"
        pxdata = Vector{UInt8}(undef, w * h)
        @inbounds for p in 1:(w * h)
            pxdata[p] = pix[3*p - 2]
        end
        pbpp = 1
        colortype = UInt8(0)
    elseif mode == "rgba"
        pxdata = Vector{UInt8}(undef, w * h * 4)
        po = 1
        @inbounds for p in 1:(w * h)
            pxdata[po] = pix[3*p - 2]
            pxdata[po+1] = pix[3*p - 1]
            pxdata[po+2] = pix[3*p]
            pxdata[po+3] = alpha[p]
            po += 4
        end
        pbpp = 4
        colortype = UInt8(6)
    else
        pxdata = pix
        pbpp = 3
        colortype = UInt8(2)
    end

    # --- filter ---
    fstream, fhist = filter_stream(pxdata, w, h, pbpp)
    ctx.fhist .+= fhist

    # --- deflate ---
    idat, dst = deflate(fstream, level)
    idat = zlib_wrap(idat, fstream, level)     # RFC 1950 stream, strict decoders
    t1 = time_ns()
    ctx.nblocks = dst.nblocks
    ctx.ndyn = dst.ndyn
    ctx.nstatic = dst.nstatic
    ctx.nstored = dst.nstored

    # --- assemble PNG ---
    out = UInt8[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    ihdr = UInt8[]
    push_u32be!(ihdr, UInt32(w))
    push_u32be!(ihdr, UInt32(h))
    push!(ihdr, 0x08)            # bit depth
    push!(ihdr, colortype)
    push!(ihdr, 0x00)           # compression
    push!(ihdr, 0x00)           # filter method
    push!(ihdr, 0x00)           # interlace
    push_chunk!(out, "IHDR", ihdr)
    if mode == "indexed"
        push_chunk!(out, "PLTE", plte)
    end
    push_chunk!(out, "IDAT", idat)
    push_chunk!(out, "IEND", UInt8[])

    open(outpath, "w") do io
        write(io, out)
    end

    insize = filesize(inpath)
    outsize = length(out)
    ms = (t1 - t0) / 1e6
    mbps = (length(fstream) / 1e6) / (ms / 1000)
    @printf("%-34s %8d -> %8d B  %5.1f%%  %5s  %dx%d  %6.1f ms  %5.1f MB/s  blocks: %d (dyn %d/stat %d/stored %d)\n",
        basename(inpath), insize, outsize, 100 * outsize / max(insize, 1), mode, w, h, ms, mbps, ctx.nblocks, ctx.ndyn, ctx.nstatic, ctx.nstored)
    ctx.nblocks = 0; ctx.ndyn = 0; ctx.nstatic = 0; ctx.nstored = 0
    return outsize
end

# -----------------------------------------------------------------------------
# Section 11: CLI
# -----------------------------------------------------------------------------

function main(args::Vector{String})
    level = 9
    outdir = ""
    files = String[]
    i = 1
    while i ≤ length(args)
        a = args[i]
        if a == "--level"
            i += 1
            (i ≤ length(args)) || (println(stderr, "--level needs a value"); exit(1))
            level = parse(Int, args[i])
            (1 ≤ level ≤ 9) || (println(stderr, "--level must be 1..9"); exit(1))
        elseif startswith(a, "--level=")
            level = parse(Int, split(a, '=')[2])
            (1 ≤ level ≤ 9) || (println(stderr, "--level must be 1..9"); exit(1))
        elseif a == "--outdir"
            i += 1
            (i ≤ length(args)) || (println(stderr, "--outdir needs a value"); exit(1))
            outdir = args[i]
        else
            push!(files, a)
        end
        i += 1
    end
    isempty(files) && (println(stderr, "usage: julia bmp2png.jl file.bmp [...] [--level 1-9] [--outdir DIR]"); exit(1))
    ctx = Ctx()
    for f in files
        out = outdir
        if isempty(out)
            out = dirname(f)
        end
        isdir(out) || mkpath(out)
        base = basename(f)
        base = endswith(lowercase(base), ".bmp") ? base[1:(end - 4)] : base
        outp = joinpath(out, base * ".png")
        convert_bmp_png(f, outp, level, ctx)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
