# bmp2png.jl

Handwritten BMP → PNG converter in pure Julia stdlib. One file, zero packages,
no `zlib`, no `ImageMagick`, no external tools — every layer (BMP reader, PNG
writer, CRC32, LZ77, Huffman) is implemented from scratch.

Written in the same stdlib-only spirit as
[Newton_Fractals](https://github.com/St0n89/Newton_Fractals) and
[INSAR](https://github.com/St0n89/INSAR), whose hand-written 24-bit BMP output
was the original motivation: this tool squeezes those BMPs into PNGs with a
from-scratch DEFLATE encoder.

## Usage

```
julia bmp2png.jl file.bmp [more.bmp ...] [--level 1-9] [--outdir DIR]
```

* `--level N` — DEFLATE effort, default 9. Level table follows zlib's tuned
  good/lazy/nice/chain parameters (level 9 tuned deeper: chain 8192).
* `--outdir DIR` — write PNGs to DIR (default: next to each input).

Per-file stats are printed: size, ratio, PNG color mode, time, MB/s, block types.

```
newton_fractal.bmp  1920054 ->    57485 B    3.0%  indexed  800x800 ...
```

## What's inside

* **BMP reader** — BI_RGB, 1/4/8/24/32-bit, bottom-up and top-down
  (negative height), V4/V5 DIB headers, palettes, row padding.
* **PNG mode reduction** — ≤ 256 colors → indexed (color type 3, palette
  re-mapped by first-seen color), R==G==B everywhere → grayscale (type 0),
  32-bit pad bytes all-0/all-255 → opaque RGB, else RGBA (type 6).
* **Adaptive filtering** — all 5 PNG filters tried per scanline, chosen by
  entropy of the filtered bytes (oxipng-style adaptive filtering).
* **DEFLATE encoder**
  * LZ77: 32 KiB window, 15-bit multiplicative hash of 3 bytes (×0x9E3779B1),
    hash chains (head/prev), lazy matching (zlib `deflate_slow`).
  * Dynamic Huffman per block: optimal length-limited trees via
    **package-merge** (Hirschberg–Larmore) — always complete, depth ≤ 15.
  * Precode (code-length) stream with RLE symbols 16/17/18, HCLEN trimming
    over the RFC 1951 permuted order.
  * Per block: cheapest of dynamic vs static vs stored (zlib-style).
  * 32768-token blocks.

## Validation

Everything is verified byte-for-byte against independent implementations
(Python stdlib `zlib` + a from-scratch Python PNG/BMP decoder):

* 54/54 raw-DEFLATE round-trips through `zlib.decompress` (18 buffers ×
  levels 1/4/9: empty, tiny, random 1 KiB–200 KiB, zeros, text, ramps,
  65535/65536/65537 stored-chunk boundaries, filter-like data).
* 5000 random tree-builder trials: Kraft sum exactly 1, depth ≤ maxbits.
* 21/21 curated images exact-pixel PASS, including real output of the tools
  above (Newton fractal 800×800, insar demo images 900×900).
* 120 random BMPs (all bit depths, odd sizes, top-down) × levels 1/5/9:
  0 failures.

## Compression

IDAT size vs zlib over the **same** filtered stream (isolates encoder quality):

| Image            | ours     | zlib -9  | delta  |
|------------------|----------|----------|--------|
| satellite (RGB)  | 707,815  | 725,204  | −2.4 % |
| interferogram    | 1,512,746| 1,540,371| −1.8 % |
| fBm (indexed)    | 221,292  | 227,667  | −2.8 % |
| coherence        | 105,098  | 105,576  | −0.5 % |
| SAR (indexed)    | 722,970  | 718,677  | +0.6 % |
| Newton fractal   | 57,485   | 56,867   | +1.1 % |

Beats zlib -6 everywhere; within ~1–2 % of zlib -9 on the remaining inputs.
Random noise falls back to stored blocks (~100.1 %, correct choice).

End-to-end ratios (24-bit BMP → PNG): Newton fractal 3.0 %, flat color 0.1 %,
insar unwrapped 1.2 %, satellite 29.3 %, interferogram 62.3 %.

Speed: 7–36 MB/s (level 1), 7–60 MB/s (level 6), 0.7–36 MB/s (level 9),
depending on match density. Julia JIT/startup (~2–3 s) dominates small
one-shot runs.

## Test harness

`test/` contains the complete validation suite (pure Python stdlib + one
Julia driver):

```
julia bmp2png.jl test.bmp --outdir /tmp        # convert something
python3 test/mkbmp.py bmps                     # generate test corpus
python3 test/fuzz.py 40 7                      # 40 random BMPs x 3 levels
julia test/deflate_fuzz.jl dtest               # raw deflate round-trips
python3 test/pngcheck.py --check a.bmp a.png   # exact-pixel verify one pair
```

## License

MIT — see [LICENSE](LICENSE).
