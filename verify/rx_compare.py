"""
One row of verify_rx.sh: compare the three decodes of a received signal
(rade_rx_wav = .ref, native wrapper = .cli, WebAssembly = .w) and score them.

  python3 rx_compare.py NAME [--src features.f32 --loss_test L --acq_test A
                              --clip_start N --clip_end N] [--base features.f32] [--sync_at_end]

WebAssembly vs native: the receiver runs the same code on the same numbers, but
float rounding differs at the level of the last bit (Emscripten's maths library
and SIMD against plain C), so the features agree to about 130 dB rather than
exactly. RADE's receiver also makes threshold decisions (sync, timing slips);
very rarely a decision lands on the other side of a threshold, and from there
the two decodes follow different but equally valid timing. That is accepted only
when the WebAssembly decode is then shown to be as good as the native one:
the same loss against the transmitted speech, or, for off-air audio with no
transmitted reference, the same distortion against a decode of the undisturbed
recording (--base).
"""
import sys, os, argparse, filecmp
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from loss_np import find_loss, distortion_loss

p = argparse.ArgumentParser()
p.add_argument('name')
p.add_argument('--src'); p.add_argument('--base')
p.add_argument('--loss_test', type=float, default=0); p.add_argument('--acq_test', type=float, default=0)
p.add_argument('--clip_start', type=int, default=0); p.add_argument('--clip_end', type=int, default=0)
p.add_argument('--sync_at_end', action='store_true')
a = p.parse_args(); n = a.name
ok = True

same = filecmp.cmp(f'{n}.ref.f32', f'{n}.cli.f32', shallow=False) and filecmp.cmp(f'{n}.ref.s16', f'{n}.cli.s16', shallow=False)
ok &= same

ref, w = np.fromfile(f'{n}.ref.f32', np.float32), np.fromfile(f'{n}.w.f32', np.float32)
sref, sw = np.fromfile(f'{n}.ref.s16', np.int16), np.fromfile(f'{n}.w.s16', np.int16)
if len(ref) == len(w) and len(sref) == len(sw) and len(ref):
    d = ref - w
    snr = np.inf if not d.any() else 10 * np.log10((ref ** 2).sum() / (d ** 2).sum())
    match = snr >= 100
    cmp = 'identical' if snr == np.inf else f'matches native, {snr:.0f} dB'
else:
    match, cmp = False, ''
if not match:
    k = min(len(ref), len(w)) // 36
    R, W = ref[:36 * k].reshape(-1, 36), w[:36 * k].reshape(-1, 36)
    div = int(np.argmax(np.abs(R - W).max(1) > 1e-3)) if k else 0
    if a.src:
        ln = find_loss(a.src, f'{n}.ref.f32', a.clip_start, a.clip_end)[0]
        lw = find_loss(a.src, f'{n}.w.f32', a.clip_start, a.clip_end)[0]
        good = abs(ln - lw) <= 0.01
        cmp = f'split at {div / 100:.0f} s, loss {lw:.3f} vs {ln:.3f}'
    elif a.base:
        # distortion of 2 s windows against the best-matching stretch of the undisturbed decode
        B = np.fromfile(a.base, np.float32).reshape(-1, 36)[:, :20].astype(float)
        def windows(f):
            F = np.fromfile(f, np.float32).reshape(-1, 36)[:, :20].astype(float)
            out = []
            for s in range(0, len(F) - 200, 200):
                x = F[s:s + 200]
                lo, hi = max(0, s - 1500), min(len(B) - 200, s + 1500)
                out.append(min(distortion_loss(B[None, o:o + 200], x[None])[0] for o in range(lo, hi, 2)))
            return np.array(out)
        wn, ww = windows(f'{n}.ref.f32'), windows(f'{n}.w.f32')
        good = abs(np.median(wn) - np.median(ww)) <= 0.01 and abs((wn > 0.3).mean() - (ww > 0.3).mean()) <= 0.05
        cmp = f'split at {div / 100:.0f} s, equal quality'
        print(f'# {n}: native and WebAssembly decodes split at {div / 100:.1f} s. Against the undisturbed decode, 2 s windows: '
              f'median distortion {np.median(wn):.3f} native, {np.median(ww):.3f} WebAssembly; windows over 0.3: '
              f'{(wn > 0.3).sum()} and {(ww > 0.3).sum()} of {len(wn)}', file=sys.stderr)
    else:
        good = False
    if not good: cmp += ' DIFFERS'
    ok &= good

st = np.loadtxt(f'{n}.w.stats', usecols=0, ndmin=1)
sync = f'{100 * st.mean():.0f}%'
if a.src:
    loss, acq, _ = find_loss(a.src, f'{n}.w.f32', a.clip_start, a.clip_end)
    v = f'loss {loss:.3f}, acquired in {acq:.2f} s'
    if a.loss_test:
        good = loss <= a.loss_test and acq <= a.acq_test
        v += f' (< {a.loss_test}, < {a.acq_test} s) ' + ('PASS' if good else 'FAIL'); ok &= good
else:
    v = f'{len(sw) / 16000:.0f} s of speech'
    if a.sync_at_end:
        good = st[-1] == 1; ok &= good
        v += ', in sync at the end ' + ('PASS' if good else 'FAIL')
secs = os.path.getsize(f'{n}.in.s16') / 16000
print(f"{n:<20} {secs:5.0f} {sync:>5}  {'bit-identical' if same else 'DIFFERENT':<14} {cmp:<34} {v}")
sys.exit(0 if ok else 1)
