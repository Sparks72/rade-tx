// The page's speaker buffer, simulated: decoded speech arrives in 120 ms bursts
// clocked by the rig's sound card, with the main thread's delivery jitter, while
// the speakers run on their own clock. Over a 10-minute over, for clock errors
// up to ±1000 ppm (sound cards are usually within ±100), the buffer must stay
// bounded and never run dry.
//   node test-speaker.js [index.html]
const fs = require('fs'), path = require('path');
const page = fs.readFileSync(process.argv[2] || path.join(__dirname, '../build/rade-tx.src.html'), 'utf8');
const src = page.slice(page.indexOf('const WORKLETS = `') + 18, page.indexOf('`;', page.indexOf('const WORKLETS = `')));
const classes = {};
new Function('AudioWorkletProcessor', 'registerProcessor', src)(
  class { constructor(){ this.port = { postMessage: m => { this.last = m; }, onmessage: null }; } },
  (name, cls) => { classes[name] = cls; });
const Speaker = classes['rade-speaker'];

let fail = 0;
console.log('clock error   buffer (min–max after settling)   rate    gaps');
for (const ppm of [-1000, -300, -100, 0, 100, 300, 1000]){
  const sp = new Speaker(); const send = m => sp.port.onmessage({ data: m });
  send({ cmd: 'cfg', pre: 4000, target: 2000 });
  let seed = 7; const rnd = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648;
  const secs = 600, qPerSec = 16000 / 128, rigRate = 1 + ppm * 1e-6;
  let nextFrame = 0.12 / rigRate + 0.05 * rnd(), frames = 0, gaps = 0, wasPlaying = false, mn = Infinity, mx = 0;
  const out = [new Float32Array(128), new Float32Array(128)];
  for (let q = 0; q < secs * qPerSec; q++){
    const t = q / qPerSec;
    while (t >= nextFrame){                                        // a modem frame of speech arrives
      send({ cmd: 'push', buf: new Float32Array(1920).fill(0.1) });
      frames++;
      nextFrame = frames * 0.12 / rigRate + 0.1 * rnd() * (rnd() < 0.05 ? 1 : 0.3);  // jitter, now and then 100 ms
    }
    sp.process([], [out]);
    const playing = sp.playing;
    if (wasPlaying && !playing) gaps++;
    wasPlaying = playing;
    if (t > 30 && playing){ const a = sp.w - sp.r; mn = Math.min(mn, a); mx = Math.max(mx, a); }
  }
  const ok = gaps === 0 && mn > 300 && mx < 16000;
  if (!ok) fail = 1;
  console.log(`${String(ppm).padStart(6)} ppm   ${(mn / 16).toFixed(0).padStart(4)}–${(mx / 16).toFixed(0)} ms`.padEnd(46)
    + `${sp.rate.toFixed(5)}  ${gaps}  ${ok ? 'PASS' : 'FAIL'}`);
}
console.log(fail ? 'SPEAKER BUFFER FAILED' : 'SPEAKER BUFFER PASSED');
process.exit(fail);
