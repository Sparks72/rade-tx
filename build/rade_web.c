/*
 * rade_web.c — RADE V1 transmit path for the browser.
 *
 * Speech in, modem IQ out, called from JavaScript one frame at a time:
 *
 *   rw_features(pcm160, feat36)   10 ms of 16 kHz speech  -> 36 features
 *   rw_tx(feat432, iq1920)        12 feature frames       -> 960 complex samples (120 ms at 8 kHz)
 *   rw_eoo(iq)                    end of over             -> 1152 complex samples
 *
 * Uses exactly the settings rade_open() uses for V1 (bottleneck 3, auxdata on,
 * built-in weights), but calls the transmitter directly, so neither the
 * receiver/decoder nor any V2 code is linked. The optional transmit bandpass
 * filter is the one in rade_tx.c, which the V1 API leaves switched off.
 *
 * Audio for an SSB transmitter is the real part of the IQ (see rade_api.h).
 */
#include <string.h>
#include "lpcnet.h"
#include "lpcnet_private.h"
#include "rade_tx.h"

#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#define EXPORT EMSCRIPTEN_KEEPALIVE
#else
#define EXPORT
#endif

static LPCNetEncState *enc = NULL;
static rade_tx_state tx;
static int ready = 0;

/* (Re)start an over. bpf: 1 = apply the transmit bandpass filter. */
EXPORT int rw_init(int bpf)
{
    if (enc == NULL) enc = lpcnet_encoder_create();
    else lpcnet_encoder_init(enc);
    if (enc == NULL) return -1;
    if (rade_tx_init(&tx, NULL, 3, 1, bpf) != 0) return -2;
    ready = 1;
    return 0;
}

EXPORT int rw_frame_pcm(void)      { return LPCNET_FRAME_SIZE; }            /* 160  */
EXPORT int rw_nb_features(void)    { return NB_TOTAL_FEATURES; }            /* 36   */
EXPORT int rw_n_features_in(void)  { return ready ? rade_tx_n_features_in(&tx) : 0; }  /* 432  */
EXPORT int rw_n_samples_out(void)  { return ready ? rade_tx_n_samples_out(&tx) : 0; }  /* 960  */
EXPORT int rw_n_eoo_out(void)      { return ready ? rade_tx_n_eoo_out(&tx) : 0; }      /* 1152 */

EXPORT int rw_features(const opus_int16 *pcm, float *features)
{
    lpcnet_compute_single_frame_features(enc, pcm, features, 0);
    return NB_TOTAL_FEATURES;
}

/* iq is interleaved I,Q float32 */
EXPORT int rw_tx(const float *features, float *iq)
{
    return rade_tx_process(&tx, (RADE_COMP *)iq, features);
}

EXPORT int rw_eoo(float *iq)
{
    return rade_tx_state_eoo(&tx, (RADE_COMP *)iq);
}
