/* rx_cli — rade_web_rx.c driven natively, as the page drives it:
     rx_cli features.f32 speech.s16 < rade_audio.s16      (8 kHz mono int16 in)
   Built in plain C to check the wrapper against rade_c's own rade_rx_wav tool,
   and with AddressSanitizer. */
#include <stdio.h>
#include <string.h>
#include <math.h>
int rr_init(void), rr_nin(void), rr_nin_max(void), rr_pcm_max(void), rr_nfeat(void), rr_eoo(void), rr_sync(void);
float *rr_features(void);
int rr_process(const float *in, float *pcm);
int main(int argc, char **argv){
  if (argc < 3 || rr_init()) return 1;
  FILE *ff = fopen(argv[1], "wb"), *fs = fopen(argv[2], "wb");
  if (!ff || !fs) return 1;
  static short s[4096]; static float in[4096], pcm[1920];
  int eof = 0, eoos = 0, syncs = 0, calls = 0;
  while (!eof){
    int nin = rr_nin();
    size_t got = fread(s, 2, nin, stdin);
    if (got < (size_t)nin){ memset(&s[got], 0, (nin - got) * 2); eof = 1; if (!got) break; }
    for (int i = 0; i < nin; i++) in[i] = s[i] / 32768.0f;
    int n = rr_process(in, pcm);
    fwrite(rr_features(), 4, rr_nfeat(), ff);
    for (int i = 0; i < n; i++){
      float v = pcm[i] * 32768.0f;
      if (v > 32767.0f) v = 32767.0f;
      if (v < -32767.0f) v = -32767.0f;
      short o = (short)floor(0.5 + (double)v); fwrite(&o, 2, 1, fs);
    }
    eoos += rr_eoo(); syncs += rr_sync(); calls++;
  }
  fclose(ff); fclose(fs);
  fprintf(stderr, "rx_cli: %d calls, in sync %d, end-of-over %d\n", calls, syncs, eoos);
  return 0;
}
/* Opus's assertion handler (celt/celt.c), needed only when ENABLE_ASSERTIONS is on */
#include <stdlib.h>
void celt_fatal(const char *str, const char *file, int line){
  fprintf(stderr, "Assertion failed in %s, line %d: %s\n", file, line, str); abort();
}
