#!/usr/bin/env bash
#
# Drive index.html in a real browser and check what it transmits and receives.
# Run verify.sh and verify_rx.sh first: they build the native tools this uses.
#
# Needs: node with Playwright (npm install playwright), python3 with numpy.
# CHROME=/path/to/chrome selects a browser build; otherwise Playwright's own.
#
#   1. test-page.js drives the page: a recording, a live over from Chromium's
#      fake microphone (fed from brian_g8sez.wav), and PTT sequencing against a
#      mocked serial port. It saves everything the page produced.
#   2. The live capture must actually contain the source recording.
#   3. The page's live transmission must equal the reference module's encoding
#      of the same captured speech, sample for sample.
#   4. The WAV files the page saved are decoded by rade_c's native receiver and
#      held to RADE's acceptance thresholds.
#   5. test-page-rx.js plays a received RADE signal into the page as rig audio.
#      Replaying what the page fed its decoder through the Node build must give
#      exactly what the page decoded live; the over the page saved must decode
#      natively within RADE's thresholds; the status display, the speech buffer,
#      pausing for transmit, and "Decode a recording" are checked too.
#
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$HERE/../build/work}
B=$HERE/out/bin; P=$HERE/out/page
[ -x "$B/radae_rx" ] || { echo "run verify.sh first"; exit 1; }
[ -x "$B/rx_ref" ] || { echo "run verify_rx.sh first"; exit 1; }
mkdir -p "$P"; cd "$P"   # radae_rx writes eoo_rx.f32 into the current directory

echo "== driving the page"
node "$HERE/test-page.js"

echo
echo "== checking what it produced"
node --no-experimental-fetch "$HERE/module_encode.js" 1 "$P/ref_live.iq" "$P/live_speech.s16" > /dev/null
WAV=$WORK/rade_c/wav/brian_g8sez.wav python3 - "$P" <<'PY'
import os, sys, wave, numpy as np
P = sys.argv[1]
src = wave.open(os.environ['WAV']); b = np.frombuffer(src.readframes(src.getnframes()), np.int16).astype(float)
x = np.fromfile(f'{P}/live_speech.s16', np.int16).astype(float)
c = b[16000:48000]
n = 1 << int(np.ceil(np.log2(len(x) + len(c))))
xc = np.fft.irfft(np.fft.rfft(x, n) * np.conj(np.fft.rfft(c, n)), n)[:len(x) - len(c)]
e = np.sqrt(np.convolve(x ** 2, np.ones(len(c)), 'valid')[:len(xc)]) * np.linalg.norm(c)
r = float((np.abs(xc) / np.maximum(e, 1e-9)).max())
ok1 = r >= 0.8
print(f"  live capture contains the source recording: correlation {r:.3f}  {'PASS' if ok1 else 'FAIL'}")
page = np.fromfile(f'{P}/live_rade.f32', np.float32)
ref = np.fromfile(f'{P}/ref_live.iq', np.float32)[0::2]
ok2 = np.array_equal(page, ref[:len(page)]) and len(page) <= len(ref)
print(f"  live transmission equals the reference encoding: {len(page)} samples, {'identical PASS' if ok2 else 'DIFFERENT FAIL'}")
def w(fn):
    f = wave.open(fn); assert (f.getnchannels(), f.getsampwidth(), f.getframerate()) == (1, 2, 8000)
    return np.frombuffer(f.readframes(f.getnframes()), np.int16)
for name, fn in [('file', f'{P}/file_rade.wav'), ('live', f'{P}/live_last_over.wav')]:
    (w(fn).astype(np.float32) * (2 / 16384)).tofile(f'{P}/{name}_rx.f32')
sys.exit(0 if ok1 and ok2 else 1)
PY
fail=0
for m in file live; do
  "$B/feat" < "$P/${m}_speech.s16" > "$P/${m}_feat_ref.f32" 2>/dev/null
  "$B/real2iq" < "$P/${m}_rx.f32" | "$B/radae_rx" 2>/dev/null > "$P/${m}_feat_out.f32"
  r=$(python3 "$HERE/loss_np.py" "$P/${m}_feat_ref.f32" "$P/${m}_feat_out.f32" --loss_test 0.15 --acq_time_test 0.5 --clip_start 5 | tr '\n' ' ')
  echo "  $m WAV saved by the page, decoded:$r"
  case "$r" in *PASS*) ;; *) fail=1;; esac
done

echo
echo "== receiving: driving the page"
Q=$HERE/out/page-rx; mkdir -p "$Q"
python3 $HERE/channel.py $HERE/out/brian_g8sez.native.iq $Q/rx_test.wav --snr 10 --foff 15 --prepend 2 --append 4 --level -6
node "$HERE/test-page-rx.js"

echo
echo "== receiving: checking what it produced"
cd "$Q"
node --no-experimental-fetch $HERE/rx_module.js live_in.f32 replay_feat.f32 replay_pcm.s16 > /dev/null
node --no-experimental-fetch $HERE/rx_module.js rx_test.wav ref_feat.f32 ref_pcm.s16 > /dev/null
[ -f last_heard_rade.wav ] && $B/rx_ref -v 0 -f last_heard_feat.f32 last_heard_rade.wav last_heard_native.wav 2>/dev/null
HERE=$HERE REF=$HERE/out/brian_g8sez.feat.f32 python3 - "$Q" <<'PY2' || fail=1
import sys, json, wave, os, numpy as np
Q = sys.argv[1]; os.chdir(Q); ok = True
def say(msg, good):
    global ok; ok &= bool(good); print(f"  {msg}  {'PASS' if good else 'FAIL'}")
f32 = lambda fn: np.fromfile(fn, np.float32)
def s16(pcm):   # as rade_rx_wav.c writes speech
    v = np.clip((pcm * np.float32(32768)).astype(np.float32), -32767, 32767)
    return np.floor(0.5 + v.astype(np.float64)).astype(np.int16)
# a. the live page decoded exactly what the Node build decodes from the same samples
lf, rf = f32('live_feat.f32'), f32('replay_feat.f32'); lp, rp = s16(f32('live_pcm.f32')), np.fromfile('replay_pcm.s16', np.int16)
n, m = min(len(lf), len(rf)), min(len(lp), len(rp))
say(f"live decode equals the Node replay: {n // 36} feature frames, {m / 16000:.1f} s of speech, identical",
    n > 36 * 500 and np.array_equal(lf[:n], rf[:n]) and np.array_equal(lp[:m], rp[:m]))
# b. the over the page saved, decoded natively, is as good as the file itself decoded directly
if os.path.exists('last_heard_feat.f32'):
    w = wave.open('last_heard_rade.wav'); x = np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float64)
    L = f32('live_in.f32').astype(np.float64) * 32768
    hits = [i for i in np.where(np.abs(L[:len(L) - len(x)] - x[0]) <= 0.5)[0] if np.abs(L[i:i + len(x)] - x).max() <= 0.5]
    say(f"last over heard, saved as RADE audio: {len(x) / 8000:.1f} s, exactly what the decoder was fed", len(hits) > 0)
    sys.path.insert(0, os.environ['HERE']); from loss_np import find_loss
    ld, ad, _ = find_loss(os.environ['REF'], 'ref_feat.f32', 5, 0)
    ll, al, _ = find_loss(os.environ['REF'], 'last_heard_feat.f32', 5, 0)
    say(f"last over heard, saved as RADE audio, decoded by rade_rx_wav: loss {ll:.3f}, acquired in {al:.2f} s "
        f"(the file itself: {ld:.3f}, {ad:.2f} s)", ll <= ld + 0.05 and al <= 1.0)
    w = wave.open('last_heard_speech.wav'); secs = w.getnframes() / w.getframerate()
    say(f"last over heard, saved as speech: {secs:.1f} s at {w.getframerate()} Hz", w.getframerate() == 16000 and secs > 8)
else:
    say("the page kept the last over heard", False)
# c. the display while receiving
tr = json.load(open('live_trace.json'))
syn = [t for t in tr if t['sync'] == 'RADE signal']
frac = len(syn) / len(tr)
snr = [float(t['snr'].split()[0]) for t in syn if t['snr'] != '—']
fo = [float(t['foff'].replace('−', '-').replace('+', '').split()[0]) for t in syn if t['foff'] != '—']
eoo = sum(1 for a, b in zip(tr, tr[1:]) if b['sync'] == 'end of over' and a['sync'] != 'end of over')
say(f"showing a RADE signal {100 * frac:.0f}% of the time (signal present 60%), {eoo} end-of-over shown", 0.4 < frac < 0.7 and eoo >= 1)
say(f"SNR shown {np.median(snr):.0f} dB (channel 10 dB), offset {np.median(fo):+.1f} Hz (channel +15 Hz)",
    abs(np.median(snr) - 10) <= 4 and abs(np.median(fo) - 15) <= 2)
buf = []
for i, t in enumerate(tr):     # speech buffer, once an over has been in sync for 1.5 s
    if i >= 6 and all(x['sync'] == 'RADE signal' for x in tr[i - 6:i + 1]): buf.append(int(t['buf'].split()[0]))
say(f"speech buffer during overs {min(buf)}–{max(buf)} ms (kept between 40 and 400)", buf and min(buf) >= 40 and max(buf) <= 400)
# d. receive pauses for transmit and comes back
p = json.load(open('pause.json'))
say(f"while transmitting \"{p['during']}\", after \"{p['after']}\"",
    p['during'] == 'paused while transmitting' and p['after'] in ('searching', 'RADE signal', 'end of over'))
# e. decode a recording
ff, fp = f32('file_feat.f32'), f32('file_pcm.f32')
ref_f, ref_p = f32('ref_feat.f32'), np.fromfile('ref_pcm.s16', np.int16)
w = wave.open('file_decoded.wav'); saved = np.frombuffer(w.readframes(w.getnframes()), np.int16)
say(f"\"Decode a recording\" equals the Node build: {len(ff) // 36} frames, {len(fp) / 16000:.1f} s, saved WAV identical",
    np.array_equal(ff, ref_f) and np.array_equal(s16(fp), ref_p) and np.array_equal(saved, ref_p))
sys.exit(0 if ok else 1)
PY2

echo
[ $fail = 0 ] && echo "PAGE CHECKS PASSED" || { echo "PAGE CHECKS FAILED"; exit 1; }
