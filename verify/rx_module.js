// Decode a RADE WAV with the WebAssembly receiver, exactly as the page does.
//   node --no-experimental-fetch rx_module.js in.wav out_features.f32 out_speech.s16 [stats.txt]
// in.wav: 8 kHz mono 16-bit. Or in.f32: the float samples a page fed its decoder
// (a replay; no zero padding at the end, as the live page waits for more).
// Features are what the decoder produced (36 floats per 10 ms frame); speech is
// the vocoder's 16 kHz output, rounded as rade_rx_wav.c does.
const fs = require('fs');
const createRadeRx = require(process.env.RADE_RX_MODULE || '../build/work/rade_rx_node.js');

function readWav(fn){
  const b = fs.readFileSync(fn);
  let p = 12, fmt = null;
  while (p + 8 <= b.length){
    const id = b.toString('ascii', p, p + 4), sz = b.readUInt32LE(p + 4);
    if (id === 'fmt ') fmt = { ch: b.readUInt16LE(p + 10), rate: b.readUInt32LE(p + 12), bits: b.readUInt16LE(p + 22) };
    if (id === 'data'){
      if (!fmt || fmt.ch !== 1 || fmt.rate !== 8000 || fmt.bits !== 16) throw new Error('need 8 kHz mono 16-bit');
      const n = Math.min(sz, b.length - p - 8) >> 1;
      return new Int16Array(b.buffer.slice(b.byteOffset + p + 8, b.byteOffset + p + 8 + 2 * n));
    }
    p += 8 + sz + (sz & 1);
  }
  throw new Error('no data chunk');
}

createRadeRx().then(M => {
  const [inFn, featFn, pcmFn, statsFn] = process.argv.slice(2);
  const replay = inFn.endsWith('.f32');
  let x;
  if (replay) x = new Float32Array(fs.readFileSync(inFn).buffer.slice(0));
  else {
    const s16 = readWav(inFn);
    x = new Float32Array(s16.length);
    for (let i = 0; i < s16.length; i++) x[i] = s16[i] / 32768;    // as the browser delivers it
  }

  if (M._rr_init() !== 0) throw new Error('rr_init failed');
  const inP = M._malloc(4 * M._rr_nin_max()), pcmP = M._malloc(4 * M._rr_pcm_max());
  const feats = [], pcm = [], stats = [];
  let pos = 0, eoos = 0;
  const t0 = process.hrtime.bigint();
  while (pos < x.length){
    const nin = M._rr_nin();
    if (replay && pos + nin > x.length) break;
    const blk = new Float32Array(nin);                              // zero-pad the last block, as rade_rx_wav.c
    blk.set(x.subarray(pos, Math.min(pos + nin, x.length)));
    pos += nin;
    M.HEAPF32.set(blk, inP >> 2);
    const n = M._rr_process(inP, pcmP);
    const nf = M._rr_nfeat();
    if (nf) feats.push(M.HEAPF32.slice(M._rr_features() >> 2, (M._rr_features() >> 2) + nf));
    for (let i = 0; i < n; i++){
      let v = M.HEAPF32[(pcmP >> 2) + i] * 32768;
      v = Math.fround(v);
      if (v > 32767) v = 32767; if (v < -32767) v = -32767;
      pcm.push(Math.floor(0.5 + v));
    }
    if (M._rr_eoo()) eoos++;
    stats.push(`${M._rr_sync()} ${M._rr_snr().toFixed(2)} ${M._rr_foff().toFixed(2)}`);
  }
  const secs = Number(process.hrtime.bigint() - t0) / 1e9;
  const F = new Float32Array(feats.reduce((a, f) => a + f.length, 0)); let o = 0;
  for (const f of feats){ F.set(f, o); o += f.length; }
  fs.writeFileSync(featFn, Buffer.from(F.buffer));
  fs.writeFileSync(pcmFn, Buffer.from(Int16Array.from(pcm).buffer));
  if (statsFn) fs.writeFileSync(statsFn, stats.join('\n') + '\n');
  const dur = x.length / 8000;
  console.log(`${dur.toFixed(1)} s decoded in ${secs.toFixed(2)} s (${(dur / secs).toFixed(1)}x real time), `
    + `${F.length / 36} feature frames, ${(pcm.length / 16000).toFixed(1)} s speech, ${eoos} end-of-over`);
});
