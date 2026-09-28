#!/usr/bin/env bash
#
# Verify the WebAssembly RADE V1 transmitter against native code and against
# RADE's own acceptance test. Run ../build/build.sh first; it leaves the pinned
# sources and the Node build of the encoder in ../build/work.
#
# Needs: gcc, node, python3 with numpy, sox.
#
# For each speech recording that ships with rade_c:
#   1. encode natively (plain C, the same arithmetic path WebAssembly takes)
#   2. encode with the WebAssembly module, exactly as the page does
#   3. compare the two
#   4. take the WebAssembly signal's real part, as an SSB rig receives it, and
#      decode it with rade_c's own receiver
#   5. measure loss with RADE's distortion measure (port of radae/loss.py)
# Then the transmit path once more under AddressSanitizer, UBSan and Opus's
# assertions.
#
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$HERE/../build/work}
T=$HERE/out; mkdir -p "$T/bin"
cd "$T"          # radae_rx writes eoo_rx.f32 into the current directory
O=$WORK/opus; R=$WORK/rade_c/src
INC="-I$HERE/../build -I$O/dnn -I$O/celt -I$O/include -I$O/silk -I$O -I$R"
PLAIN="-O2 -U__SSE2__ -U__SSE__ -U__AVX__ -U__AVX2__ -DHAVE_CONFIG_H -DIS_BUILDING_RADE_API=1"
OPUS="$O/dnn/lpcnet_enc.c $O/dnn/pitchdnn.c $O/dnn/pitchdnn_data.c $O/dnn/nnet.c $O/dnn/nnet_default.c
      $O/dnn/freq.c $O/dnn/lpcnet_tables.c $O/dnn/burg.c $O/dnn/parse_lpcnet_weights.c
      $O/celt/kiss_fft.c $O/celt/mathops.c $O/celt/celt_lpc.c $O/celt/pitch.c"
TX="$HERE/../build/rade_web.c $R/rade_tx.c $R/rade_enc.c $R/rade_enc_data.c $R/rade_ofdm.c $R/rade_dsp.c $R/rade_bpf.c"
RADELIB="$R/rade_api.c $R/rade_enc.c $R/rade_dec.c $R/rade_enc_data.c $R/rade_dec_data.c $R/rade_dsp.c
         $R/rade_ofdm.c $R/rade_bpf.c $R/rade_acq.c $R/rade_tx.c $R/rade_rx.c $R/rade_enc_v2.c $R/rade_dec_v2.c
         $R/rade_sync.c $R/rade_enc_v2_data.c $R/rade_dec_v2_data.c $R/rade_sync_data.c $R/rade_v2_ofdm.c
         $R/rade_tx_v2.c $R/rade_rx_v2.c"
B=$T/bin

echo "== building native reference tools (plain C)"
gcc $PLAIN $INC -o $B/feat     $HERE/feat.c $OPUS -lm 2>/dev/null
gcc $PLAIN $INC -o $B/tx_cli   $HERE/tx_cli.c $TX $OPUS -lm 2>/dev/null
gcc $PLAIN $INC -o $B/radae_rx $R/radae_rx.c $RADELIB $OPUS -lm 2>/dev/null
gcc -O2 -o $B/real2iq $R/real2iq.c -lm
gcc -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer -DENABLE_ASSERTIONS \
    -U__SSE2__ -U__SSE__ -DHAVE_CONFIG_H $INC -o $B/tx_asan $HERE/tx_cli.c $TX $OPUS -lm 2>/dev/null

# an IQ file's real part -> the receiver's real-input scaling -> complex IQ -> features
ssb_decode(){  # $1 = IQ in, $2 = features out
  python3 -c "
import sys, numpy as np
iq = np.fromfile(sys.argv[1], np.float32)
s = np.clip(np.floor(iq[0::2] * 16384 + 0.5), -32768, 32767).astype(np.int16)   # as a RADE WAV holds it
(s.astype(np.float32) * (2 / 16384)).tofile(sys.argv[1] + '.real')" "$1"
  $B/real2iq < "$1.real" | $B/radae_rx 2>/dev/null > "$2"
}
loss(){ python3 $HERE/loss_np.py "$@"; }

printf '\n== encode, compare, decode\n'
printf '%-15s %6s  %-26s %-15s %-15s %s\n' recording secs 'WebAssembly vs native' 'native loss' 'wasm loss' verdict
fail=0
for w in $WORK/rade_c/wav/*.wav; do
  b=$(basename "$w" .wav)
  [ "$b" = long_qso ] && continue            # a modem recording, not speech
  sox "$w" -r 16000 -c 1 -b 16 -t raw -e signed "$T/$b.s16" 2>/dev/null
  $B/feat   < "$T/$b.s16" > "$T/$b.feat.f32" 2>/dev/null
  $B/tx_cli < "$T/$b.s16" > "$T/$b.native.iq" 2>/dev/null
  node --no-experimental-fetch $HERE/module_encode.js 1 "$T/$b.wasm.iq" "$T/$b.s16" > /dev/null
  cmpres=$(python3 -c "
import numpy as np
a = np.fromfile('$T/$b.native.iq', np.float32); m = np.fromfile('$T/$b.wasm.iq', np.float32)[:len(a)]
rs = np.sqrt(np.mean(m ** 2)); rd = np.sqrt(np.mean((a - m) ** 2))
print('bit-identical' if np.array_equal(a, m) else f'rms diff {20 * np.log10(max(rd, 1e-30) / rs):.0f} dB')")
  ssb_decode "$T/$b.native.iq" "$T/$b.native.out.f32"
  ssb_decode "$T/$b.wasm.iq"   "$T/$b.wasm.out.f32"
  ln=$(loss "$T/$b.feat.f32" "$T/$b.native.out.f32" --clip_start 5 | awk '{print $2}')
  lw=$(loss "$T/$b.feat.f32" "$T/$b.wasm.out.f32"   --clip_start 5 | awk '{print $2}')
  secs=$(python3 -c "import os; print(round(os.path.getsize('$T/$b.s16') / 32000))")
  if [ "$b" = brian_g8sez ]; then                    # RADE's own acceptance test
    v=$(loss "$T/$b.feat.f32" "$T/$b.wasm.out.f32" --loss_test 0.15 --acq_time_test 0.5 --clip_start 5 | tail -1)
    v="$v (rade_c_v1_tx_basic: loss < 0.15, acquisition < 0.5 s)"
  else
    v=$(python3 -c "print('matches native' if abs($ln - $lw) <= 0.005 else 'DIFFERS FROM NATIVE')")
  fi
  case "$v" in *FAIL*|*DIFFERS*) fail=1;; esac
  printf '%-15s %6s  %-26s %-15s %-15s %s\n' "$b" "$secs" "$cmpres" "$ln" "$lw" "$v"
done

printf '\n== transmit path under AddressSanitizer + UBSan + Opus assertions\n'
for s in $T/*.s16; do
  r=$($B/tx_asan < "$s" 2>&1 >/dev/null | grep -E "ERROR|runtime error|Assertion" | head -1 || true)
  printf '%-15s %s\n' "$(basename "$s" .s16)" "${r:-clean}"
  [ -n "$r" ] && fail=1
done

echo
[ $fail = 0 ] && echo "ALL CHECKS PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
