// End-to-end browser test of index.html (needs: npm install playwright).
// CHROME=/path/to/chrome to use a particular browser build.
//   1. file mode  — encode a recording in the page, save the WAV via the button
//   2. live mode  — Chromium's fake microphone plays a WAV; transmit, end the over
//   3. PTT safety — Web Serial mocked; check key/unkey order, safety limit, Esc
// Everything the page produces is written to disk for the native decoder.
const { chromium } = require('playwright');
const fs = require('fs');

const PAGE = 'file://' + require('path').resolve(process.env.PAGE || __dirname + '/../index.html');
// resolved: Chromium does not resolve '..' in --use-file-for-fake-audio-capture and
// silently falls back to a silent fake microphone
const WAV  = require('path').resolve(process.env.WAV || __dirname + '/../build/work/rade_c/wav/brian_g8sez.wav');
const OUT  = __dirname + '/out/page';
fs.mkdirSync(OUT, { recursive: true });

// A fake Web Serial port that records every write with a timestamp.
const SERIAL_MOCK = () => {
  window.__cat = [];
  const t0 = performance.now();
  const port = {
    async open(){},
    async close(){},
    writable: new WritableStream({ write(chunk){
      window.__cat.push({ t: performance.now() - t0, s: new TextDecoder().decode(chunk) });
    }}),
    readable: new ReadableStream({ start(){} })
  };
  Object.defineProperty(navigator, 'serial', { value: { requestPort: async () => port } });
};

async function newPage(browser){
  const ctx = await browser.newContext({ acceptDownloads: true });
  await ctx.addInitScript(SERIAL_MOCK);
  const page = await ctx.newPage();
  page.on('console', m => { if (m.type() === 'error') console.log('  [console error]', m.text()); });
  page.on('pageerror', e => console.log('  [page error]', e.message));
  await page.goto(PAGE);
  await page.waitForSelector('#engine.ok', { timeout: 30000 });
  console.log('  ' + await page.textContent('#engine'));
  return page;
}
const save = (name, arr) => fs.writeFileSync(`${OUT}/${name}`, Buffer.from(new Uint8Array(arr)));

(async () => {
  const browser = await chromium.launch({
    executablePath: process.env.CHROME || undefined,
    args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
           `--use-file-for-fake-audio-capture=${WAV}`, '--autoplay-policy=no-user-gesture-required']
  });

  // ---------------------------------------------------------------- 0. regressions
  console.log('\n=== 0. transmit before finding devices; meter before transmitting ===');
  let p0 = await newPage(browser);
  await p0.click('#txBtn');                                   // straight to transmit, default microphone
  await p0.waitForSelector('#state.tx', { timeout: 15000 });
  await p0.waitForTimeout(2500);
  console.log(`  transmitting with the default mic: "${await p0.textContent('#state')}", gaps ${await p0.textContent('#under')}`);
  await p0.keyboard.press('Escape'); await p0.waitForSelector('#state.rx');
  await p0.context().close();
  p0 = await newPage(browser);
  await p0.click('#allow');
  await p0.waitForFunction(() => !document.getElementById('micSel').disabled);
  await p0.waitForFunction(() => /dB/.test(document.getElementById('micDb').textContent), null, { timeout: 5000, polling: 100 })
    .catch(async e => {
      console.log('  meter never read — engine:', await p0.textContent('#engine'));
      console.log('  capture:', await p0.evaluate(() => capCtx ? capCtx.state + ' @' + capCtx.sampleRate
        + ' tracks ' + (micStream ? micStream.getTracks().map(t => t.readyState + '/' + t.muted).join(',') : 'none') : 'none'));
      throw e;
    });
  const seen = [];
  for (let i = 0; i < 6; i++){ await p0.waitForTimeout(300); seen.push(await p0.textContent('#micDb')); }
  console.log(`  speech meter before any over: ${seen.join('  ')}  (state "${await p0.textContent('#state')}")`);
  await p0.context().close();

  // ---------------------------------------------------------------- 1. file
  console.log('\n=== 1. file mode ===');
  let page = await newPage(browser);
  await page.setInputFiles('#fileIn', WAV);
  await page.waitForFunction(() => /encoded in/.test(document.getElementById('fileInfo').textContent), null, { timeout: 30000 });
  console.log('  ' + await page.textContent('#fileInfo'));
  const [dl] = await Promise.all([page.waitForEvent('download'), page.click('#fileSave')]);
  await dl.saveAs(`${OUT}/file_rade.wav`);
  const fileSpeech = await page.evaluate(() => Array.from(new Uint8Array(window.radeFile.speech.buffer)));
  save('file_speech.s16', fileSpeech);
  console.log(`  saved ${dl.suggestedFilename()} and the page's 16 kHz speech`);
  await page.context().close();

  // ---------------------------------------------------------------- 2. live
  console.log('\n=== 2. live microphone ===');
  page = await newPage(browser);
  await page.click('#allow');
  await page.waitForFunction(() => !document.getElementById('micSel').disabled, null, { timeout: 15000 });
  console.log('  mic:', await page.$eval('#micSel', s => s.selectedOptions[0].textContent));
  await page.click('#txBtn');
  await page.waitForSelector('#state.tx', { timeout: 15000 });
  const liveSecs = 21;
  for (let s = 0; s < liveSecs; s += 7){
    await page.waitForTimeout(7000);
    console.log(`  t=${s + 7}s  state "${await page.textContent('#state')}"  load ${await page.textContent('#load')}`
      + `  buffer ${await page.textContent('#buf')}  gaps ${await page.textContent('#under')}`);
  }
  await page.click('#txBtn');                               // end over
  await page.waitForSelector('#state.rx', { timeout: 15000 });
  console.log('  after ending:', await page.textContent('#state'));
  const live = await page.evaluate(() => ({
    rade: Array.from(new Uint8Array(window.radeLastOver.rade.buffer)),
    speech: Array.from(new Uint8Array(window.radeLastOver.speech.buffer)),
    rates: [window.__capRate, window.__outRate]
  }));
  save('live_rade.f32', live.rade); save('live_speech.s16', live.speech);
  // refuse to carry on if the fake microphone delivered silence: everything
  // downstream would still "pass", having tested nothing
  const sp = new Int16Array(new Uint8Array(live.speech).buffer);
  let silent = 0, frames = Math.floor(sp.length / 160);
  for (let f = 0; f < frames; f++){ let pk = 0; for (let k = 0; k < 160; k++) pk = Math.max(pk, Math.abs(sp[f*160+k])); if (!pk) silent++; }
  console.log(`  captured speech: ${(100 * (1 - silent / frames)).toFixed(0)}% of frames non-silent`);
  if (silent > 0.1 * frames) throw new Error('the microphone delivered silence — check the WAV path given to Chromium');
  const [dl2] = await Promise.all([page.waitForEvent('download'), page.click('#lastSave')]);
  await dl2.saveAs(`${OUT}/live_last_over.wav`);
  console.log(`  captured ${(live.speech.length / 2 / 16000).toFixed(1)} s of speech, `
    + `${(live.rade.length / 4 / 8000).toFixed(1)} s of RADE audio; saved ${dl2.suggestedFilename()}`);
  await page.context().close();

  // ---------------------------------------------------------------- 3. PTT
  console.log('\n=== 3. PTT sequencing and safety ===');
  page = await newPage(browser);
  await page.click('#allow');
  await page.waitForFunction(() => !document.getElementById('micSel').disabled);
  await page.click('#catBtn');
  await page.waitForSelector('#catState.ok');
  console.log('  CAT:', await page.textContent('#catState'));
  const log = async (label) => {
    const c = await page.evaluate(() => window.__cat.splice(0));
    console.log(`  ${label.padEnd(34)} ${c.map(x => `${x.s} @${Math.round(x.t)}ms`).join('  ') || '(nothing sent)'}`);
    return c;
  };
  await log('on connect');

  // a normal over: key, then audio; end: drain, then unkey
  await page.click('#txBtn'); await page.waitForSelector('#state.tx');
  const tKey = await page.evaluate(() => performance.now());
  await log('start of over');
  await page.waitForTimeout(3000);
  await page.click('#txBtn'); await page.waitForSelector('#state.rx', { timeout: 10000 });
  await log('end of over (button)');

  // safety limit: inject a 4-second option and let it expire
  await page.evaluate(() => { const o = new Option('4 s (test)', '4', true, true); document.getElementById('tot').add(o); });
  await page.click('#txBtn'); await page.waitForSelector('#state.tx');
  await log('start of over');
  await page.waitForSelector('#state.rx', { timeout: 15000 });
  console.log('  state:', await page.textContent('#state'));
  await log('after the safety limit');

  // Esc: immediate unkey mid-over
  await page.selectOption('#tot', '120');
  await page.click('#txBtn'); await page.waitForSelector('#state.tx');
  await log('start of over');
  await page.waitForTimeout(1500);
  const tEsc = await page.evaluate(() => performance.now());
  await page.keyboard.press('Escape');
  await page.waitForSelector('#state.rx', { timeout: 5000 });
  const c = await log('after Esc');
  console.log('  state:', await page.textContent('#state'));

  // space bar toggles an over
  await page.focus('body');
  await page.keyboard.press('Space'); await page.waitForSelector('#state.tx');
  await page.waitForTimeout(1000);
  await page.keyboard.press('Space'); await page.waitForSelector('#state.rx', { timeout: 10000 });
  await log('space bar start + end');

  await browser.close();
})().catch(e => { console.error('TEST FAILED:', e); process.exit(1); });
