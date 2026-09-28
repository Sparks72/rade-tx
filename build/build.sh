#!/usr/bin/env bash
#
# Rebuild index.html (the RADE V1 browser transceiver) from source.
#
# Needs: git, curl, patch, tar, sha256sum, python3, and Emscripten (emcc).
# Built and verified with Emscripten 3.1.6; newer versions should work, but
# only 3.1.6 is known to reproduce the published file byte for byte.
#
# Everything is fetched from pinned, checkable sources:
#   - FreeDV's C port of RADE, rade_c, at a fixed commit
#   - Opus at the commit rade_c itself pins (cmake/BuildOpus.cmake), with
#     rade_c's two patches to dnn/nnet.h and dnn/nnet.c
#   - Opus's generated neural-network model files, from the official Opus 1.5.2
#     release tarball, checked against its published SHA-256
#
# Why the release tarball: Opus's autogen.sh normally downloads these model
# files from media.xiph.org. The transmit path needs only the pitch estimator's
# weights (plus three headers of layer sizes). Those were last retrained in
# October 2023 and come from the checkpoint pitch_vsmallconv1.pth in both the
# 1.5.2 release and the model set rade_c's Opus commit names. The release
# tarball is the same file everywhere; Ubuntu's archive mirrors it unchanged.
#
set -euo pipefail

RADE_C_COMMIT=cc17222acc597339199bdfd7253c3e6cf147f953
OPUS_COMMIT=940d4e5af64351ca8ba8390df3f555484c567fbb
OPUS_152_URL=http://archive.ubuntu.com/ubuntu/pool/main/o/opus/opus_1.5.2.orig.tar.gz
OPUS_152_SHA256=65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$HERE/work}
OUT=${OUT:-$HERE/..}
mkdir -p "$WORK/obj" "$WORK/objrx"
cd "$WORK"

say(){ printf '\n== %s\n' "$*"; }

say "rade_c at $RADE_C_COMMIT"
[ -d rade_c ] || git clone -q https://github.com/freedv/rade_c.git
git -C rade_c fetch -q origin 2>/dev/null || true
git -C rade_c checkout -q "$RADE_C_COMMIT"

say "Opus at $OPUS_COMMIT, with rade_c's patches"
[ -d opus ] || git clone -q https://github.com/xiph/opus.git
git -C opus checkout -q -f "$OPUS_COMMIT"
git -C opus checkout -q -- dnn/nnet.h dnn/nnet.c
patch -s -d opus -p0 dnn/nnet.h < rade_c/src/opus-nnet.h.diff
patch -s -d opus -p0 dnn/nnet.c < rade_c/src/opus-nnet.c.diff

say "Opus 1.5.2 release tarball (generated model files)"
[ -f opus_1.5.2.orig.tar.gz ] || curl -fsSLO "$OPUS_152_URL"
echo "$OPUS_152_SHA256  opus_1.5.2.orig.tar.gz" | sha256sum -c -
MODEL_FILES="pitchdnn_data.c pitchdnn_data.h fargan_data.c fargan_data.h plc_data.h dred_rdovae_constants.h"
for f in $MODEL_FILES; do
  tar xzf opus_1.5.2.orig.tar.gz -O "opus-1.5.2/dnn/$f" > "opus/dnn/$f"
done
head -1 opus/dnn/pitchdnn_data.c

O=opus; R=rade_c/src
INC="-I$HERE -I$O/dnn -I$O/celt -I$O/include -I$O/silk -I$O -I$R"
SRC="$HERE/rade_web.c
     $R/rade_tx.c $R/rade_enc.c $R/rade_enc_data.c $R/rade_ofdm.c $R/rade_dsp.c $R/rade_bpf.c
     $O/dnn/lpcnet_enc.c $O/dnn/pitchdnn.c $O/dnn/pitchdnn_data.c $O/dnn/nnet.c $O/dnn/nnet_default.c
     $O/dnn/freq.c $O/dnn/lpcnet_tables.c $O/dnn/burg.c $O/dnn/parse_lpcnet_weights.c
     $O/celt/kiss_fft.c $O/celt/mathops.c $O/celt/celt_lpc.c $O/celt/pitch.c"

RXSRC="$HERE/rade_web_rx.c
     $R/rade_rx.c $R/rade_dec.c $R/rade_dec_data.c $R/rade_ofdm.c $R/rade_dsp.c $R/rade_bpf.c $R/rade_acq.c
     $O/dnn/fargan.c $O/dnn/fargan_data.c $O/dnn/nnet.c $O/dnn/nnet_default.c $O/dnn/parse_lpcnet_weights.c
     $O/celt/mathops.c $O/celt/celt_lpc.c $O/celt/pitch.c $O/celt/kiss_fft.c $O/dnn/freq.c $O/dnn/lpcnet_tables.c $O/dnn/burg.c"

# strip build-directory paths from __FILE__ (rade_c uses assert()), so the
# output is the same wherever the build is run
CFLAGS="-O2 -ffile-prefix-map=$WORK/= -ffile-prefix-map=$HERE/= -DHAVE_CONFIG_H -DIS_BUILDING_RADE_API=1 $INC"
compile(){  # $1 = object dir, $2 = extra flags, rest = sources; prints the objects
  local dir=$1 extra=$2; shift 2; local objs=""
  for f in "$@"; do
    local o="$dir/$(basename "${f%.c}").o"
    emcc $CFLAGS $extra -c "$f" -o "$o" 2>/dev/null &
    objs="$objs $o"
  done
  wait; echo $objs
}

say "compiling the transmitter to WebAssembly"
# plain C arithmetic: the same numbers as a native plain-C build, bit for bit
objs=$(compile obj "" $SRC)

say "compiling the receiver to WebAssembly (SIMD)"
# the FARGAN vocoder is the heavy part: Opus's SSE code, which Emscripten maps
# onto WebAssembly SIMD, runs it about four times faster than plain C
rxobjs=$(compile objrx "-msimd128 -msse4.1" $RXSRC)

EXP='["_rw_init","_rw_frame_pcm","_rw_nb_features","_rw_n_features_in","_rw_n_samples_out","_rw_n_eoo_out","_rw_features","_rw_tx","_rw_eoo","_malloc","_free"]'
RXEXP='["_rr_init","_rr_nin","_rr_nin_max","_rr_pcm_max","_rr_sync","_rr_snr","_rr_foff","_rr_eoo","_rr_nfeat","_rr_features","_rr_process","_malloc","_free"]'
COMMON="-O3 -s ALLOW_MEMORY_GROWTH=1 -s INITIAL_MEMORY=32MB -s TOTAL_STACK=4MB -s FILESYSTEM=0 -s MODULARIZE=1"
LINK="$COMMON -s EXPORT_NAME=createRadeTx -s EXPORTED_FUNCTIONS=$EXP -s EXPORTED_RUNTIME_METHODS=[\"HEAPF32\",\"HEAP16\"]"
RXLINK="$COMMON -msimd128 -s EXPORT_NAME=createRadeRx -s EXPORTED_FUNCTIONS=$RXEXP -s EXPORTED_RUNTIME_METHODS=[\"HEAPF32\"]"

# for the page: WebAssembly embedded, so it runs from disk with no server
emcc $objs -lm $LINK -s ENVIRONMENT=web,worker -s SINGLE_FILE=1 -o rade_tx_single.js
emcc $rxobjs -lm $RXLINK -s ENVIRONMENT=web,worker -s SINGLE_FILE=1 -o rade_rx_single.js
# the same code for Node, used by the verification scripts
emcc $objs -lm $LINK -s ENVIRONMENT=node -o rade_tx_node.js
emcc $rxobjs -lm $RXLINK -s ENVIRONMENT=node -o rade_rx_node.js
ls -l rade_tx_node.wasm rade_rx_node.wasm

say "assembling the page"
python3 - "$HERE/rade-tx.src.html" rade_tx_single.js rade_rx_single.js "$OUT/index.html" <<'PY2'
import sys
src, tx, rx, out = sys.argv[1:5]
page = open(src, encoding='utf-8').read()
for mark, fn in (('/*__RADE_TX_MODULE__*/', tx), ('/*__RADE_RX_MODULE__*/', rx)):
    module = open(fn, encoding='utf-8').read()
    assert '</script' not in module.lower()
    assert page.count(mark) == 1
    page = page.replace(mark, module)
open(out, 'w', encoding='utf-8').write(page)
PY2
ls -l "$OUT/index.html"
sha256sum "$OUT/index.html"
