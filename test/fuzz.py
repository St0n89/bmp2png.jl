#!/usr/bin/env python3
"""Randomized BMP fuzz: N random BMPs -> bmp2png.jl -> exact verify."""
import subprocess, sys, os, random, shutil
sys.path.insert(0, os.path.dirname(__file__))
import mkbmp, pngcheck

def run(n=40, seed=7, outdir='fuzz', levels=(1, 5, 9)):
    shutil.rmtree(outdir, ignore_errors=True)
    os.makedirs(outdir, exist_ok=True)
    rnd = random.Random(seed)
    bmpdir = os.path.join(outdir, 'bmp')
    paths = []
    for k in range(n):
        w = rnd.choice([1, 2, 3, 5, 8, 13, 31, 64, 100, rnd.randint(1, 130)])
        h = rnd.choice([1, 2, 4, 7, 16, 33, 64, 90, rnd.randint(1, 130)])
        kind = rnd.choice(['flat', 'grad', 'noise', 'fbm', 'bands'])
        bpp = rnd.choice([1, 4, 8, 24, 32])
        td = rnd.random() < 0.3
        p = mkbmp.gen_bmp_all(bmpdir, 'f%03d.bmp' % k, w, h, kind, seed=rnd.randint(0, 10**6), bpp=bpp, topdown=td)
        paths.append(p)
    fails = 0
    for lv in levels:
        pngdir = os.path.join(outdir, 'png%d' % lv)
        subprocess.run(['julia', '--startup-file=no', 'bmp2png.jl'] + paths +
                       ['--outdir', pngdir, '--level', str(lv)], check=True,
                       stdout=subprocess.DEVNULL)
        for p in paths:
            b = os.path.basename(p)[:-4]
            try:
                ok = pngcheck.check(p, os.path.join(pngdir, b + '.png'), verbose=False)
            except Exception as e:
                print('FAIL %s L%d: %s' % (b, lv, e))
                ok = False
            if not ok:
                print('FAIL %s L%d' % (b, lv))
                fails += 1
        print('level %d: %d files, %d failures' % (lv, len(paths), fails))
    print('TOTAL FAILURES:', fails)
    return fails

if __name__ == '__main__':
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 40
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 7
    sys.exit(1 if run(n, seed) else 0)
