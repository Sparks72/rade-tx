/* feat — speech to RADE feature vectors, exactly as `lpcnet_demo -features`
   does it, without linking the FARGAN synthesiser (receive side only).
   stdin : 16 kHz mono int16 PCM
   stdout: 36 float32 features per 10 ms frame                                  */
#include <stdio.h>
#include "lpcnet.h"
#include "lpcnet_private.h"
#include "os_support.h"

int main(void){
  LPCNetEncState *net = lpcnet_encoder_create();
  if (!net) { fprintf(stderr, "feat: encoder init failed\n"); return 1; }
  opus_int16 pcm[LPCNET_FRAME_SIZE];
  float features[NB_TOTAL_FEATURES];
  long n = 0;
  while (fread(pcm, sizeof(pcm[0]), LPCNET_FRAME_SIZE, stdin) == LPCNET_FRAME_SIZE){
    lpcnet_compute_single_frame_features(net, pcm, features, 0);
    fwrite(features, sizeof(float), NB_TOTAL_FEATURES, stdout);
    n++;
  }
  lpcnet_encoder_destroy(net);
  fprintf(stderr, "feat: %ld frames\n", n);
  return 0;
}
