/* tx_cli — speech in (16 kHz int16, stdin), IQ out (8 kHz complex float32, stdout),
   through rade_web.c. Built natively for comparison, and with AddressSanitizer. */
#include <stdio.h>
#include "lpcnet.h"
int rw_init(int), rw_frame_pcm(void), rw_nb_features(void), rw_n_features_in(void), rw_n_samples_out(void), rw_n_eoo_out(void);
int rw_features(const opus_int16*, float*), rw_tx(const float*, float*), rw_eoo(float*);
int main(void){
  if (rw_init(1)) return 1;
  int FR = rw_frame_pcm(), NF = rw_nb_features(), per = rw_n_features_in() / NF;
  static opus_int16 pcm[160]; static float feat[36], in[432], iq[2*1152]; int filled = 0, frames = 0;
  while (fread(pcm, 2, FR, stdin) == (size_t)FR){
    rw_features(pcm, feat);
    for (int k = 0; k < NF; k++) in[filled * NF + k] = feat[k];
    if (++filled == per){ int n = rw_tx(in, iq); fwrite(iq, 8, n, stdout); filled = 0; frames++; }
  }
  int n = rw_eoo(iq); fwrite(iq, 8, n, stdout);
  fprintf(stderr, "asan_tx: %d modem frames + EOO\n", frames);
  return 0;
}
/* Opus's assertion handler (celt/celt.c), needed only when ENABLE_ASSERTIONS is on */
#include <stdlib.h>
void celt_fatal(const char *str, const char *file, int line){
  fprintf(stderr, "Assertion failed in %s, line %d: %s\n", file, line, str); abort();
}
