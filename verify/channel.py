"""
HF channel simulator for receiver tests: RADE IQ in, the 8 kHz 16-bit WAV an
SSB receiver would record out.

  python3 channel.py tx.iq out.wav [--snr dB] [--foff Hz] [--mp mpg|mpp]
                    [--prepend s] [--append s] [--level dB] [--seed n]

 - noise is set by SNR in a 3 kHz bandwidth, against the transmitted power,
   as radae's inference.py does (Eb/No there, SNR3k here; both reported), and
   added to the real audio as an SSB receiver adds it
 - frequency offset, optional noise-only lead-in and tail
 - multipath: Watterson two-path model, two equal Rayleigh-fading paths with
   Gaussian Doppler spectra (CCIR good: 0.1 Hz spread, 0.5 ms; poor: 1 Hz, 2 ms).
   This is the standard model, generated here rather than with codec2's Octave
   script, so the fading is statistically alike but not the same samples.
 - output: real part, scaled as a RADE WAV (IQ 1.0 = 16384), then --level dB,
   clipped to 16 bits
"""
import sys, argparse, wave
import numpy as np

Fs = 8000
p = argparse.ArgumentParser()
p.add_argument('iq'); p.add_argument('wav')
p.add_argument('--snr', type=float, default=100.0)
p.add_argument('--foff', type=float, default=0.0)
p.add_argument('--mp', default='')
p.add_argument('--prepend', type=float, default=0.0)
p.add_argument('--append', type=float, default=0.0)
p.add_argument('--level', type=float, default=0.0)
p.add_argument('--seed', type=int, default=1)
a = p.parse_args()
rng = np.random.default_rng(a.seed)

iq = np.fromfile(a.iq, np.float32).astype(np.float64)
x = iq[0::2] + 1j * iq[1::2]
S = np.mean(np.abs(x) ** 2)

def fading(n, spread):
    # complex Gaussian process with Gaussian Doppler spectrum, 2*sigma = spread, unit power
    f = np.fft.fftfreq(n, 1 / Fs)
    H = np.exp(-f ** 2 / (2 * (spread / 2) ** 2))
    g = np.fft.ifft(np.fft.fft(rng.standard_normal(n) + 1j * rng.standard_normal(n)) * np.sqrt(H))
    return g / np.sqrt(np.mean(np.abs(g) ** 2))

if a.mp:
    spread, delay = {'mpg': (0.1, 0.5e-3), 'mpp': (1.0, 2e-3)}[a.mp]
    d = int(round(delay * Fs))
    xd = np.concatenate([np.zeros(d), x[:-d]])
    x = (fading(len(x), spread) * x + fading(len(x), spread) * xd) / np.sqrt(2)

pre, post = int(a.prepend * Fs), int(a.append * Fs)
x = np.concatenate([np.zeros(pre), x, np.zeros(post)])
x = x * np.exp(2j * np.pi * a.foff * np.arange(len(x)) / Fs)

# Noise is added to the real audio, as it is in an SSB receiver: real white noise
# of variance N/4 has the same density in the modem's band, once the receiver has
# doubled the real signal (rade_api.h), as complex noise of power N in radae's
# complex channel. So SNR here means what it means there, and what an SNR in
# 3 kHz of the rig's audio means.
SNR = 10 ** (a.snr / 10)
N = S * Fs / (SNR * 3000)                     # radae: complex noise power over the 8 kHz bandwidth
y = np.real(x) + np.sqrt(N / 4) * rng.standard_normal(len(x))

y = y * 16384 * 10 ** (a.level / 20)
clipped = np.mean(np.abs(y) > 32767)
s = np.clip(np.round(y), -32768, 32767).astype(np.int16)
w = wave.open(a.wav, 'wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(Fs); w.writeframes(s.tobytes()); w.close()
EbNo = a.snr - 10 * np.log10(2000 / 3000)   # V1: 80 latents per 40 ms = 2000 bit/s
print(f"SNR3k {a.snr:.1f} dB (Eb/No {EbNo:.1f} dB), foff {a.foff:g} Hz, {a.mp or 'no multipath'}, "
      f"level {a.level:+g} dB, clipped {100 * clipped:.2f}%", file=sys.stderr)
