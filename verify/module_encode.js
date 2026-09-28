// Drive the browser module from JavaScript exactly as a web page would,
// frame by frame, and check it reproduces the command-line WebAssembly output.
const fs = require('fs');
const createRadeTx = require(process.env.RADE_MODULE || '../build/work/rade_tx_node.js');

(async () => {
  const t0 = process.hrtime.bigint();
  const M = await createRadeTx();
  const tLoad = Number(process.hrtime.bigint() - t0) / 1e6;

  const bpf = +(process.argv[2] || 0);
  if (M._rw_init(bpf) !== 0) throw new Error('init failed');
  const FR = M._rw_frame_pcm(), NF = M._rw_nb_features();
  const NIN = M._rw_n_features_in(), NOUT = M._rw_n_samples_out(), NEOO = M._rw_n_eoo_out();
  const perModem = NIN / NF;
  console.log(`module loaded in ${tLoad.toFixed(0)} ms — frame ${FR} samples, ${NF} features, `
    + `${perModem} frames per modem frame, ${NOUT} IQ out, ${NEOO} EOO`);

  // scratch buffers in wasm memory
  const pPcm = M._malloc(FR * 2), pFeat = M._malloc(NF * 4);
  const pIn = M._malloc(NIN * 4), pIq = M._malloc(Math.max(NOUT, NEOO) * 8);

  const pcm = new Int16Array(fs.readFileSync(process.argv[4] || 'brian.s16').buffer.slice(0));
  const nFrames = Math.floor(pcm.length / FR);
  const out = [];
  let tFeat = 0n, tTx = 0n, filled = 0;

  for (let f = 0; f < nFrames; f++) {
    M.HEAP16.set(pcm.subarray(f * FR, f * FR + FR), pPcm >> 1);
    let a = process.hrtime.bigint();
    M._rw_features(pPcm, pFeat);
    tFeat += process.hrtime.bigint() - a;
    M.HEAPF32.copyWithin((pIn >> 2) + filled * NF, pFeat >> 2, (pFeat >> 2) + NF);
    if (++filled === perModem) {
      a = process.hrtime.bigint();
      const n = M._rw_tx(pIn, pIq);
      tTx += process.hrtime.bigint() - a;
      out.push(M.HEAPF32.slice(pIq >> 2, (pIq >> 2) + n * 2));
      filled = 0;
    }
  }
  const n = M._rw_eoo(pIq);
  out.push(M.HEAPF32.slice(pIq >> 2, (pIq >> 2) + n * 2));
  out.push(new Float32Array(n * 2));                 // radae_tx appends one silent EOO-length block

  const iq = Float32Array.from(out.flatMap(a => Array.from(a)));
  fs.writeFileSync(process.argv[3] || 'mod_tx.iq', Buffer.from(iq.buffer));

  const secs = nFrames * 0.01, modemFrames = Math.floor(nFrames / perModem);
  const msFeat = Number(tFeat) / 1e6, msTx = Number(tTx) / 1e6;
  console.log(`${secs.toFixed(2)} s of speech -> ${iq.length / 2} IQ samples`);
  console.log(`feature extraction: ${(msFeat / nFrames).toFixed(3)} ms per 10 ms frame`);
  console.log(`RADE encode+modulate: ${(msTx / modemFrames).toFixed(2)} ms per 120 ms modem frame`);
  console.log(`total compute ${(msFeat + msTx).toFixed(0)} ms for ${(secs * 1000).toFixed(0)} ms of speech`
    + ` = ${(secs * 1000 / (msFeat + msTx)).toFixed(0)}x faster than real time`);
})();
