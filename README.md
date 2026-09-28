# RADE V1 Transceiver in the browser

**Demo:** https://sparks72.github.io/rade-tx/

A FreeDV **RADE V1** transceiver that runs entirely in a web page. Speak into
your microphone and the page sends RADE audio to your rig's USB sound card and
keys it over CAT; between overs it decodes RADE from the rig and plays the
speech on your speakers. There is nothing to install and no server. It works
from GitHub Pages or straight from disk: download `index.html` and
double-click it.

It is the real RADE V1 code, not an imitation: FreeDV's own C implementation
(rade_c), Opus's speech analysis and the FARGAN vocoder, compiled to
WebAssembly with the trained network weights built in. It has been checked
against native builds of the same code, against RADE's own tests, and on
off-air recordings (see *Verification* below).

## What you need

- Chrome or Edge on a desktop computer (Windows, macOS or Linux). Firefox and
  Safari lack Web Serial, so CAT keying will not work there, and Safari cannot
  choose audio output devices.
- A rig with a USB sound card and a CAT serial port, such as the QRP Labs QMX,
  in USB/data mode. Without CAT you can still key with VOX or by hand.
- A headset or microphone, and speakers.

## Using it

1. **Find audio devices.** Allow microphone access, then choose four devices:
   - *Transmit:* your **Microphone** → **To rig** (the rig's USB sound card)
   - *Receive:* **From rig** (the rig's USB sound card) → your **Speakers**

   The page picks devices that look like a radio where it can, and remembers
   your choices. It warns if the speakers and the rig are the same device.
2. **Receive.** With *Receive* ticked the page listens as soon as the devices
   are chosen. The status line shows *searching*, then *RADE signal* with the
   SNR and frequency offset when a station is decoded, and *end of over* when
   they finish. The receiver doesn't mind the level from the rig (tested from
   −40 dB to +6 dB): keep the *From rig* meter out of the red and that's all.
3. **Connect CAT.** Choose the rig's serial port. The page sends `TX;` to key
   and `RX;` to unkey at 115200 baud (the Kenwood-style commands the QMX and
   many other rigs accept); both commands can be edited. Untick *Key the rig
   over CAT* to key with VOX or by hand instead.
4. **Set the drive.** Start with the drive low and bring it up while watching
   your rig's power output, as you would for FreeDV. RADE's peak-to-average
   ratio is low (under 1 dB), so the signal is close to a steady carrier:
   mind your PA's duty cycle.
5. **Transmit.** Click *Transmit* or press **Space** to start an over, and again
   to end it. Ending an over sends RADE's end-of-over signal, waits for the
   audio to finish playing, then unkeys. Receiving pauses while you transmit
   and resumes afterwards.

Safety:

- **Esc** unkeys immediately at any time.
- A **safety limit** (1, 2, 5 or 10 minutes; 2 by default) ends an over that
  runs too long.
- The rig is also unkeyed if the page hits an error or is closed.

Also on the page:

- **Waterfall** of the received signal, or of your own while transmitting.
- **Save the last over heard**, as speech (16 kHz WAV) or as the RADE audio
  the rig delivered (8 kHz WAV, which FreeDV or `rade_rx_wav` can decode).
- **Decode a recording.** Load a recording of RADE from your rig, FreeDV or a
  web SDR, then play or save the speech, without touching the radio.
- **Transmit a recording.** Load a WAV of speech to transmit it, or save it as
  RADE audio to check what you would send. **Save my last over** does the same
  for your last live transmission.
- **Transmit bandpass filter** (on by default), the filter rade_c provides for
  V1 transmission; it trims the signal's skirts outside the carriers.
- **Browser voice processing** (off by default): the browser's echo
  cancellation, noise suppression and automatic gain on your microphone. RADE
  is trained on clean speech, so try it only in a noisy room.

## Limits

- RADE **V1** only (the mode in current FreeDV releases). V2 is not included.
- End-of-over frames are sent and detected, but carry no callsign: FreeDV
  encodes callsigns with its own text scheme, which this page does not yet
  implement.
- Receiving needs WebAssembly SIMD (Chrome and Edge 91, Firefox 89, Safari 16.4
  or later). Without it the page still transmits.
- Audio passes through the browser's audio stack, so leave your system's sound
  effects and enhancements off for the rig's sound card.
- It has been tested thoroughly in software (below), but an over-the-air QSO
  is the real proof. Reports are welcome.

## How it works

```
transmit   microphone ─► 16 kHz capture (AudioWorklet)
                     ─► Opus LPCNet feature extraction with PitchDNN   (10 ms frames, 36 features)
                     ─► RADE V1 encoder network                        (12 frames ─► one 120 ms modem frame)
                     ─► OFDM modulator, optional transmit bandpass filter
                     ─► real part of the IQ signal, 8 kHz ─► rig's sound card (AudioWorklet)

receive    rig's sound card ─► 8 kHz capture (AudioWorklet)
                     ─► RADE V1 receiver: bandpass filter, acquisition, OFDM demodulator,
                        timing and frequency tracking, end-of-over detection
                     ─► RADE V1 decoder network                        (one modem frame ─► 12 feature frames)
                     ─► FARGAN vocoder                                  (features ─► 16 kHz speech)
                     ─► speaker buffer with clock-drift correction ─► speakers (AudioWorklet)
```

There are two WebAssembly modules. `build/rade_web.c` calls rade_c's
transmitter with the settings `rade_open()` uses for V1. `build/rade_web_rx.c`
is the receive loop of rade_c's own `rade_rx_wav.c`: it computes exactly what
that tool computes (checked bit for bit, below). Neither links V2 code, and
each links only its own half of RADE. The only dependencies are Opus and the C
maths library.

The receive module uses WebAssembly SIMD: the FARGAN vocoder is the heavy part,
and Opus's SSE code, mapped onto SIMD by Emscripten, runs it about four times
faster than plain C. The transmit module is plain C, which makes its output
identical to a native plain-C build.

Decoded speech arrives in 120 ms bursts on the rig sound card's clock, and the
speakers run on their own. The speaker buffer measures its low point each
second and nudges the playback rate (at most 0.3%, inaudible) to hold it
steady, so the two clocks never drift into a gap or a pile-up.

| | |
|---|---|
| Transmit module | 4.8 MB, weights included (4.3 MB compressed) |
| Receive module | 5.5 MB, weights included (4.9 MB compressed) |
| Page, both modules embedded | 13.8 MB, a single file (10 MB compressed as served) |
| Start-up | under half a second for each module |
| Transmit | about 30× real time; about 4% of one CPU core while transmitting |
| Receive | about 16× real time; 7–8% of one CPU core while receiving, in testing |
| Speech buffer when receiving | about a quarter of a second |

## Verification

### Transmit

`verify/verify.sh` compares the WebAssembly encoder with a native build of the
same code, then decodes the result with rade_c's own receiver. It takes the
real part of the signal, as an SSB rig transmits it, and measures the
distortion with a port of RADE's `loss.py`. The recordings are the speech
samples that ship with rade_c.

```
recording         secs  WebAssembly vs native      native loss     wasm loss       verdict
all                 50  rms diff -147 dB           0.117           0.117           matches native
brian_g8sez         10  rms diff -147 dB           0.129           0.129           PASS (rade_c_v1_tx_basic: loss < 0.15, acquisition < 0.5 s)
david_vk5dgr        11  rms diff -147 dB           0.110           0.110           matches native
jh0pcf_kanda        13  rms diff -147 dB           0.088           0.088           matches native
jh0veq_yuichi        9  rms diff -147 dB           0.108           0.108           matches native
k0pfx_mel           13  rms diff -147 dB           0.097           0.097           matches native
mooneer              8  rms diff -148 dB           0.173           0.173           matches native
peter                9  rms diff -147 dB           0.132           0.132           matches native
rick_w7yc_1         15  rms diff -147 dB           0.123           0.123           matches native
rick_w7yc_2         17  rms diff -147 dB           0.102           0.102           matches native
w0atn_phyllis       11  rms diff -148 dB           0.095           0.095           matches native

transmit path under AddressSanitizer + UBSan + Opus assertions: clean on every recording
ALL CHECKS PASSED
```

- The speech features are bit-identical between WebAssembly and native plain C.
  The modem signal differs only at the level of float rounding in the maths
  library (−147 dB), and the decoded loss is the same to three decimals.
- `brian_g8sez` is the recording RADE's own `rade_c_v1_tx_basic` test uses,
  held to that test's thresholds.

### Receive

`verify/verify_rx.sh` decodes each signal three ways: with rade_c's own
`rade_rx_wav` built natively (the reference), with the page's receive wrapper
built natively, and with the WebAssembly module driven as the page drives it.
The signals are two off-air recordings that ship with rade_c (a 10-minute QSO
and a 5-minute FreeDV recording), the same QSO played 0.25% fast, and the
transmitter's own output through a simulated HF channel: noise, frequency
offset, CCIR fading, sound-card clock errors and input level.

```
signal                secs  sync  wrapper        WebAssembly                        result
offair_long_qso        600   99%  bit-identical  matches native, 133 dB             594 s of speech
offair_fdv             326   97%  bit-identical  matches native, 134 dB             315 s of speech
offair_qso_+2500ppm    602   98%  bit-identical  split at 188 s, equal quality      585 s of speech, in sync at the end PASS
clean                   10   95%  bit-identical  matches native, 134 dB             loss 0.129, acquired in 0.41 s (< 0.15, < 0.5 s) PASS
level_-40dB             10   95%  bit-identical  matches native, 134 dB             loss 0.129, acquired in 0.41 s (< 0.15, < 0.5 s) PASS
level_+6dB              10   95%  bit-identical  matches native, 134 dB             loss 0.129, acquired in 0.41 s (< 0.15, < 0.5 s) PASS
awgn                    54   92%  bit-identical  matches native, 133 dB             loss 0.233, acquired in 0.36 s (< 0.3, < 1.0 s) PASS
mpg                     54   92%  bit-identical  matches native, 133 dB             loss 0.260, acquired in 0.36 s
mpp                     54   96%  bit-identical  matches native, 133 dB             loss 0.319, acquired in 0.36 s
clock_+125ppm           10   95%  bit-identical  matches native, 134 dB             loss 0.144, acquired in 0.36 s
clock_+625ppm           10   95%  bit-identical  matches native, 134 dB             loss 0.250, acquired in 0.36 s
clock_-625ppm           10   93%  bit-identical  matches native, 134 dB             loss 0.159, acquired in 0.48 s

the vocoder, native and WebAssembly speech analysed again: decoded features vs native speech 0.114,
  vs WebAssembly speech 0.114; the two speech outputs differ by 0.024          PASS
speed: 600 s decoded in 38 s (15.8× real time)
speaker buffer, simulated 10-minute overs at -1000 to +1000 ppm clock error: no gaps  PASS
receive path under AddressSanitizer + UBSan + Opus assertions: clean on every signal
ALL RECEIVE CHECKS PASSED
```

- **The wrapper** reproduces rade_c's `rade_rx_wav` bit for bit: the same
  features and the same speech samples, on every signal.
- **WebAssembly** decodes the same features as native to within float rounding
  (about 133 dB). RADE's receiver makes threshold decisions, and in the QSO
  played 0.25% fast (twelve times a sound card's rated error) one timing
  decision fell the other way at 188 s. From there the two decodes follow
  different, equally valid timing until they rejoin. Scored against the
  undisturbed recording in 2-second windows, both are as good as each other
  (median distortion 0.026 native, 0.024 WebAssembly).
- **The vocoder's** audio is not sample-identical: FARGAN feeds its own output
  back, so last-bit differences change the waveform. Analysed again as speech,
  native and WebAssembly output are equally close to what was decoded (0.114
  each) and much closer to each other (0.024).
- **Thresholds** apply where a test reproduces one of rade_c's own: the clean
  signal (`rade_c_v1_tx_basic`), AWGN at Eb/No 1 dB (`rade_c_v1_rx_awgn`) and
  the fast QSO (`rade_c_v1_rx_slip_plus_drops`). Fading and clock errors use
  this project's own channel simulator: radae's fading comes from codec2's
  Octave scripts, and its clock tests resample complex IQ where a sound card
  resamples real audio. Those losses are reported for reference. rade_c's own
  tests allow up to 0.2 at +625 ppm, on their simulator; here it is 0.250,
  natively and in WebAssembly alike, at three times the clock error sound
  cards are rated for.
- **Level:** V1's receiver normalises on its pilots, so the loss is identical
  from −40 dB to +6 dB (with some clipping) at the input.

### In the browser

`verify/page.sh` drives `index.html` in a real Chromium, with Chromium's fake
audio input playing a recording and a mocked serial port. For transmitting it
plays speech; for receiving it plays RADE off air (10 dB SNR, +15 Hz offset,
looping overs):

```
transmit
live capture contains the source recording: correlation 0.967  PASS
live transmission equals the reference encoding: 170304 samples, identical PASS
file WAV saved by the page, decoded:  loss: 0.129 acq_time: 0.41 s PASS
live WAV saved by the page, decoded:  loss: 0.135 acq_time: 0.41 s PASS
PTT:  on connect → RX;   start of over → TX;   end of over → RX; after the audio drains
      safety limit → RX;   Esc → RX; immediately   Space → TX; … RX;
live over: 21 s, no audio gaps, 3.7% load

receive
live decode equals the Node replay: 2448 feature frames, 24.4 s of speech, identical  PASS
last over heard, saved as RADE audio: 10.8 s, exactly what the decoder was fed  PASS
last over heard, saved as RADE audio, decoded by rade_rx_wav: loss 0.140, acquired in 0.41 s  PASS
last over heard, saved as speech: 9.2 s at 16000 Hz  PASS
showing a RADE signal 61% of the time (signal present 60%), 2 end-of-over shown  PASS
SNR shown 10 dB (channel 10 dB), offset +15.0 Hz (channel +15 Hz)  PASS
speech buffer during overs 209–332 ms (kept between 40 and 400)  PASS
while transmitting "paused while transmitting", after "searching"  PASS
"Decode a recording" equals the Node build: 924 frames, 9.2 s, saved WAV identical  PASS
PAGE CHECKS PASSED
```

## Rebuilding

```
build/build.sh        # needs git, curl, patch, python3, Emscripten (emcc)
verify/verify.sh      # needs gcc, node, python3 + numpy, sox
verify/verify_rx.sh   # the same; about 15 minutes (it decodes 40 minutes of audio three ways)
verify/page.sh        # also needs Playwright (npm install playwright)
```

`build.sh` fetches pinned sources and writes `index.html`:

- rade_c at commit `cc17222acc597339199bdfd7253c3e6cf147f953`
- Opus at commit `940d4e5af64351ca8ba8390df3f555484c567fbb` (the commit rade_c
  pins), with rade_c's two patches to `dnn/nnet.h` and `dnn/nnet.c`
- Opus's generated model files from the Opus 1.5.2 release tarball, SHA-256
  `65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1`: the
  pitch estimator's weights (transmit) and FARGAN's (receive). Between 1.5.2
  and the model set rade_c's Opus commit names, only DRED's weights changed,
  and DRED is not used here.

With Emscripten 3.1.6 the build is reproducible byte for byte, wherever it is
run. The published `index.html` has SHA-256
`bbd390c2633d17b51ee0510ef6d9e121e0c4c75d35775ce802b30fa2a52aab71`.

## Credits and licences

RADE was created by David Rowe VK5DGR and the FreeDV project, building on
Jean-Marc Valin's and Jan Buethe's work on Opus's neural speech coding at
Amazon. The C port, rade_c, is by Peter B Marks. This page adds the browser
wrappers, audio handling and PTT control around their code.

The components compiled into `index.html` are under BSD licences; their
notices are in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
