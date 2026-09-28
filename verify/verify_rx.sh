#!/usr/bin/env bash
#
# Verify the WebAssembly RADE V1 receiver. Run ../build/build.sh and then
# verify.sh first (this uses the transmitter test signals verify.sh makes).
#
# Needs: gcc, node, python3 with numpy, sox.
#
# Reference: rade_c's own WAV receiver, rade_rx_wav.c, built natively in plain C.
# For each received signal:
#   1. the receive wrapper (rade_web_rx.c) built natively must reproduce the
#      reference tool exactly: same features, same speech, bit for bit
#   2. the WebAssembly module, driven as the page drives it, must decode the
#      same features as native (float rounding differences only) and the same
#      amount of speech
#   3. where the transmitted speech is known, the decoded features are scored
#      with RADE's distortion measure (port of radae/loss.py)
# Signals: two off-air recordings that ship with rade_c, and the transmitter's
# own output through a simulated channel (noise, frequency offset, fading,
# sound-card clock errors, input level). Then the vocoder's audio is compared,
# the page's speaker buffer is simulated against clock drift, and the receive
# path runs under AddressSanitizer, UBSan and Opus assertions.
#
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$HERE/../build/work}
T=$HERE/out; R=$T/rx; B=$T/bin; mkdir -p "$R"
cd "$R"
[ -f "$T/brian_g8sez.native.iq" ] || { echo "run verify.sh first"; exit 1; }
O=$WORK/opus; S=$WORK/rade_c/src
INC="-I$HERE/../build -I$O/dnn -I$O/celt -I$O/include -I$O/silk -I$O -I$S"
PLAIN="-O2 -U__SSE2__ -U__SSE__ -U__AVX__ -U__AVX2__ -DHAVE_CONFIG_H -DIS_BUILDING_RADE_API=1"
NN="$O/dnn/fargan.c $O/dnn/fargan_data.c $O/dnn/nnet.c $O/dnn/nnet_default.c $O/dnn/parse_lpcnet_weights.c
    $O/celt/mathops.c $O/celt/celt_lpc.c $O/celt/pitch.c $O/celt/kiss_fft.c $O/dnn/freq.c $O/dnn/lpcnet_tables.c $O/dnn/burg.c"
RXSRC="$S/rade_rx.c $S/rade_dec.c $S/rade_dec_data.c $S/rade_ofdm.c $S/rade_dsp.c $S/rade_bpf.c $S/rade_acq.c"
RADELIB="$S/rade_api.c $S/rade_enc.c $S/rade_dec.c $S/rade_enc_data.c $S/rade_dec_data.c $S/rade_dsp.c
         $S/rade_ofdm.c $S/rade_bpf.c $S/rade_acq.c $S/rade_tx.c $S/rade_rx.c $S/rade_enc_v2.c $S/rade_dec_v2.c
         $S/rade_sync.c $S/rade_enc_v2_data.c $S/rade_dec_v2_data.c $S/rade_sync_data.c $S/rade_v2_ofdm.c
         $S/rade_tx_v2.c $S/rade_rx_v2.c"

echo "== building native receive tools (plain C)"
gcc $PLAIN $INC -o $B/rx_ref $S/rade_rx_wav.c $RADELIB $NN $O/dnn/lpcnet_enc.c $O/dnn/pitchdnn.c $O/dnn/pitchdnn_data.c -lm 2>/dev/null
gcc $PLAIN $INC -o $B/rx_cli $HERE/rx_cli.c $HERE/../build/rade_web_rx.c $RXSRC $NN -lm 2>/dev/null
gcc -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer -DENABLE_ASSERTIONS -U__SSE2__ -U__SSE__ \
    -DHAVE_CONFIG_H $INC -o $B/rx_asan $HERE/rx_cli.c $HERE/../build/rade_web_rx.c $RXSRC $NN -lm 2>/dev/null

echo "== making received signals"
ch(){ python3 $HERE/channel.py "$@" 2>/dev/null; }
wav_s16(){ python3 -c "
import sys, wave, numpy as np
w = wave.open(sys.argv[1]); assert (w.getnchannels(), w.getsampwidth()) == (1, 2)
np.frombuffer(w.readframes(w.getnframes()), np.int16).tofile(sys.argv[2])" "$1" "$2"; }
s16_wav(){ sox -t raw -r 8000 -e signed -b 16 -c 1 "$1" "$2"; }
clock(){ # $1 in.wav  $2 rate  $3 out.wav : resample 8000 -> rate, then play it back as 8000
  sox "$1" -t raw -r "$2" -e signed -b 16 -c 1 tmp.s16 2>/dev/null; s16_wav tmp.s16 "$3"; rm tmp.s16; }

cp $WORK/rade_c/wav/long_qso.wav offair_long_qso.wav
sox $WORK/rade_c/FDV_offair.wav -r 8000 -c 1 -b 16 offair_fdv.wav 2>/dev/null
BR=$T/brian_g8sez.native.iq; ALL=$T/all.native.iq
ch $BR clean.wav
ch $BR level_-40dB.wav --level -40
ch $BR level_+6dB.wav  --level 6
ch $ALL awgn.wav        --snr -0.76 --foff 13  --prepend 1 --append 3 --level -10     # rade_c_v1_rx_awgn: Eb/No 1 dB
ch $ALL mpg.wav         --snr 1.24 --foff -11 --mp mpg --prepend 1 --append 3 --level -10   # Eb/No 3 dB, as rade_c_v1_rx_mpg
ch $ALL mpp.wav         --snr 1.24 --foff -11 --mp mpp --prepend 1 --append 3 --level -10   # Eb/No 3 dB, as rade_c_v1_rx_mpp
ch $BR c.wav --snr 8.24 --foff 11 --level -6;                 clock c.wav 8001 clock_+125ppm.wav   # as rade_c_v1_rx_dfs
ch $BR c.wav --snr 8.24 --foff 11 --level -6 --prepend 0.06;  clock c.wav 8005 clock_+625ppm.wav   # as ..._slip_plus
ch $BR c.wav --snr 8.24 --foff 31 --level -6 --prepend 0.11;  clock c.wav 7995 clock_-625ppm.wav   # as ..._slip_minus
clock offair_long_qso.wav 8020 offair_qso_+2500ppm.wav; rm c.wav

# Pass/fail thresholds where a test reproduces one of rade_c's own (radae's ctests):
# the clean signal (rade_c_v1_tx_basic, whose transmitter this is), AWGN
# (rade_c_v1_rx_awgn: Eb/No 1 dB, 13 Hz offset, noise before and after), and the
# QSO played 0.25% fast (rade_c_v1_rx_slip_plus_drops: in sync at the end).
# Fading and sound-card clock errors use this script's own channel (radae's
# multipath files come from codec2's Octave scripts, and its tests resample
# complex IQ, where a sound card resamples real audio), so their losses are
# reported without a threshold; what is checked there, as everywhere, is that
# WebAssembly decodes as native does.
T_CLEAN="--src $T/brian_g8sez.feat.f32 --loss_test 0.15 --acq_test 0.5 --clip_start 5"
T_BR="--src $T/brian_g8sez.feat.f32"
T_AWGN="--src $T/all.feat.f32 --loss_test 0.3 --acq_test 1.0 --clip_end 300"
T_ALL="--src $T/all.feat.f32 --clip_end 300"
CASES="offair_long_qso
offair_fdv
offair_qso_+2500ppm  --base offair_long_qso.ref.f32 --sync_at_end
clean                $T_CLEAN
level_-40dB          $T_CLEAN
level_+6dB           $T_CLEAN
awgn                 $T_AWGN
mpg                  $T_ALL
mpp                  $T_ALL
clock_+125ppm        $T_BR
clock_+625ppm        $T_BR
clock_-625ppm        $T_BR"

printf '\n== decode: reference tool (rade_rx_wav), native wrapper, WebAssembly\n'
printf '%-20s %5s %5s  %-14s %-34s %s\n' signal secs sync 'wrapper' 'WebAssembly' 'result'
fail=0
while read -r n opts; do
  wav_s16 $n.wav $n.in.s16
  $B/rx_ref -v 0 -f $n.ref.f32 $n.wav $n.ref.wav 2>/dev/null &
  $B/rx_cli $n.cli.f32 $n.cli.s16 < $n.in.s16 2>/dev/null &
  wait; wav_s16 $n.ref.wav $n.ref.s16
  node --no-experimental-fetch $HERE/rx_module.js $n.wav $n.w.f32 $n.w.s16 $n.w.stats > $n.w.log
  python3 $HERE/rx_compare.py $n $opts 2>>notes.txt || fail=1
done <<< "$CASES"
[ -s notes.txt ] && sed 's/^# /  /' notes.txt; rm -f notes.txt

printf '\n== the vocoder: native and WebAssembly speech, analysed again (offair_long_qso)\n'
n=offair_long_qso
$B/feat < $n.ref.s16 > v.ref.f32 2>/dev/null   # 16 kHz speech -> features
$B/feat < $n.w.s16   > v.w.f32   2>/dev/null
a=$(python3 $HERE/loss_np.py $n.w.f32 v.ref.f32 | awk '{print $2}')
b=$(python3 $HERE/loss_np.py $n.w.f32 v.w.f32   | awk '{print $2}')
c=$(python3 $HERE/loss_np.py v.ref.f32 v.w.f32  | awk '{print $2}')
printf '  decoded features vs native speech %s, vs WebAssembly speech %s; the two speech outputs differ by %s\n' "$a" "$b" "$c"
python3 -c "import sys; sys.exit(0 if abs($a - $b) <= 0.005 and $c < $a / 2 else 1)" \
  && echo "  the two are equivalent PASS" || { echo "  FAIL"; fail=1; }

printf '\n== speed\n  '; cat offair_long_qso.w.log

printf '\n== the page'"'"'s speaker buffer against sound-card clock errors (simulated 10-minute overs)\n'
node $HERE/test-speaker.js | sed 's/^/  /' || fail=1

printf '\n== receive path under AddressSanitizer + UBSan + Opus assertions (first 90 s of each)\n'
while read -r n _; do
  r=$(head -c 1440000 $n.in.s16 | $B/rx_asan a.f32 a.s16 2>&1 | grep -E "ERROR|runtime error|Assertion" | head -1 || true)
  printf '%-20s %s\n' "$n" "${r:-clean}"; [ -n "$r" ] && fail=1
done <<< "$CASES"

echo
[ $fail = 0 ] && echo "ALL RECEIVE CHECKS PASSED" || { echo "SOME RECEIVE CHECKS FAILED"; exit 1; }
