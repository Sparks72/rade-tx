/* Minimal Opus configuration for RADE feature extraction.
   Plain C, no SIMD and no run-time CPU dispatch, so a native build and a
   WebAssembly build execute the same arithmetic and can be compared exactly. */
#ifndef RADE_LEAN_CONFIG_H
#define RADE_LEAN_CONFIG_H
#define OPUS_BUILD 1
#define VAR_ARRAYS 1
#define HAVE_LRINTF 1
#define HAVE_LRINT 1
#define PACKAGE_VERSION "rade-lean"
#endif
