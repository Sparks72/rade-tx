/*
 * rade_web_rx.c — RADE V1 receive path for the browser.
 *
 * Received audio in, decoded speech out, called from JavaScript:
 *
 *   rr_init()                       start (or restart) the receiver
 *   rr_nin()                        how many 8 kHz samples the next call needs
 *   rr_process(in, pcm)             nin samples of rig audio -> 0 or more 16 kHz
 *                                   speech samples in pcm (up to rr_pcm_max())
 *   rr_sync(), rr_snr(), rr_foff()  receiver status after each call
 *   rr_eoo()                        1 if the last call saw an end-of-over
 *
 * This is the receive loop of rade_c's own rade_rx_wav.c, unchanged in what it
 * computes: real audio with the imaginary part zero (the OFDM correlators reject
 * the mirror image, so no Hilbert transform is needed), the V1 receiver with its
 * input bandpass filter as rade_open() configures it, then the FARGAN vocoder
 * with the same five-frame warm-up. Only the V1 receiver, decoder and FARGAN
 * are linked: no transmitter, no V2 code.
 *
 * Input scaling: rig audio arrives as floats in -1..1 (sound-card full scale).
 * rade_api.h defines real input as int16 * (2 / RADE_INT16_SCALE); with
 * int16 = x * 32768 that is x * 4, exact in floating point, so a WAV read here
 * gives the receiver bit-for-bit the same numbers rade_rx_wav.c gives it.
 */
#include <string.h>
#include "lpcnet.h"
#include "fargan.h"
#include "rade_rx.h"

#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#define EXPORT EMSCRIPTEN_KEEPALIVE
#else
#define EXPORT
#endif

#define RR_FEAT_MAX (12 * NB_TOTAL_FEATURES)     /* one V1 modem frame: 12 feature frames */

static rade_rx_state rx;
static FARGANState fargan;
static int ready = 0, fargan_ready, cont_frames, last_eoo, last_nfeat;
static float cont_buf[5 * NB_TOTAL_FEATURES];
static float feat_buf[RR_FEAT_MAX];
static RADE_COMP iq_buf[4096];

EXPORT int rr_init(void)
{
    if (rade_rx_init(&rx, NULL, 3, 1, 1) != 0) return -1;
    rx.verbose = 0;
    if (rade_rx_n_features_out(&rx) > RR_FEAT_MAX || rade_rx_nin_max(&rx) > 4096) return -2;
    fargan_init(&fargan);
    fargan_ready = 0; cont_frames = 0; last_eoo = 0; last_nfeat = 0;
    ready = 1;
    return 0;
}

EXPORT int rr_nin(void)      { return ready ? rade_rx_nin(&rx) : 0; }
EXPORT int rr_nin_max(void)  { return ready ? rade_rx_nin_max(&rx) : 0; }
EXPORT int rr_pcm_max(void)  { return (RR_FEAT_MAX / NB_TOTAL_FEATURES) * LPCNET_FRAME_SIZE; }  /* 1920 */
EXPORT int rr_sync(void)     { return ready ? rade_rx_sync(&rx) : 0; }
EXPORT float rr_snr(void)    { return ready ? rade_rx_snrdB_3k_est(&rx) : 0; }
EXPORT float rr_foff(void)   { return ready ? rade_rx_freq_offset(&rx) : 0; }
EXPORT int rr_eoo(void)      { return last_eoo; }
EXPORT int rr_nfeat(void)    { return last_nfeat; }          /* features decoded by the last call */
EXPORT float *rr_features(void) { return feat_buf; }         /* ...and where they are (for testing) */

/* in: rr_nin() samples, -1..1. pcm: room for rr_pcm_max() floats, -1..1.
   Returns the number of speech samples written. */
EXPORT int rr_process(const float *in, float *pcm)
{
    int nin = rade_rx_nin(&rx), n = 0;
    for (int i = 0; i < nin; i++) { iq_buf[i].real = in[i] * 4.0f; iq_buf[i].imag = 0.0f; }

    float eoo_bits[256];
    int ret = rade_rx_process(&rx, feat_buf, rade_rx_n_eoo_bits(&rx) <= 256 ? eoo_bits : NULL, iq_buf);
    last_eoo = (ret & 0x2) ? 1 : 0;
    last_nfeat = (ret & 0x1) ? rade_rx_n_features_out(&rx) : 0;

    for (int f = 0; f < last_nfeat / NB_TOTAL_FEATURES; f++) {
        float *feat = &feat_buf[f * NB_TOTAL_FEATURES];
        if (!fargan_ready) {                     /* FARGAN warm-up, as rade_rx_wav.c */
            memcpy(&cont_buf[cont_frames * NB_TOTAL_FEATURES], feat, NB_TOTAL_FEATURES * sizeof(float));
            if (++cont_frames >= 5) {
                float packed[5 * NB_FEATURES], zeros[FARGAN_CONT_SAMPLES];
                for (int i = 0; i < 5; i++)
                    memcpy(&packed[i * NB_FEATURES], &cont_buf[i * NB_TOTAL_FEATURES], NB_FEATURES * sizeof(float));
                memset(zeros, 0, sizeof(zeros));
                fargan_cont(&fargan, zeros, packed);
                fargan_ready = 1;
            }
            continue;
        }
        fargan_synthesize(&fargan, &pcm[n], feat);
        n += LPCNET_FRAME_SIZE;
    }
    return n;
}
