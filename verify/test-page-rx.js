// Browser test of index.html's receiver (needs: npm install playwright).
// Chromium's fake audio input plays RXWAV — RADE off air, as the rig's sound card
// would deliver it — and the page receives it live:
//   1. live receive: sync, SNR, the speaker buffer, the last over heard (saved via
//      its buttons), and everything the page fed its decoder (for replay in Node)
//   2. receive pauses while transmitting, and resumes after
//   3. decode a recording: the same WAV through "Decode"
// Everything is written to verify/out/page-rx for page-rx checks in page.sh.
const { chromium } = require('playwright');
const fs = require('fs'), path = require('path');

const PAGE = 'file://' + path.resolve(process.env.PAGE || __dirname + '/../index.html');
const RXWAV = path.resolve(process.env.RXWAV || __dirname + '/out/page-rx/rx_test.wav');   // absolute: see test-page.js
const OUT = __dirname + '/out/page-rx';
const LIVE_S = +(process.env.LIVE_S || 40);
fs.mkdirSync(OUT, { recursive: true });
const save = (name, typed) => fs.writeFileSync(`${OUT}/${name}`, Buffer.from(typed.buffer, typed.byteOffset, typed.byteLength));

(async () => {
  const browser = await chromium.launch({
    executablePath: process.env.CHROME || undefined,
    args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
           `--use-file-for-fake-audio-capture=${RXWAV}`, '--autoplay-policy=no-user-gesture-required']
  });
  const ctx = await browser.newContext({ acceptDownloads: true });
  await ctx.addInitScript(() => { window.__radeTap = true; });
  const page = await ctx.newPage();
  page.on('console', m => { if (m.type() === 'error') console.log('  [console error]', m.text()); });
  page.on('pageerror', e => console.log('  [page error]', e.message));
  await page.goto(PAGE);
  await page.waitForSelector('#engine.ok', { timeout: 30000 });
  await page.waitForSelector('#decoder.ok', { timeout: 30000 });
  console.log('  ' + await page.textContent('#engine') + ' ' + await page.textContent('#decoder'));

  // ---------------------------------------------------------------- 1. live receive
  console.log(`\n=== 1. live receive, ${LIVE_S} s ===`);
  await page.click('#allow');
  await page.waitForFunction(() => ['searching', 'RADE signal', 'end of over'].includes(document.getElementById('sync').textContent), null, { timeout: 15000 });
  console.log('  from rig:', await page.$eval('#rigInSel', s => s.selectedOptions[0].textContent));
  const trace = [];
  for (let t = 0; t < LIVE_S * 4; t++){
    await page.waitForTimeout(250);
    trace.push(await page.evaluate(() => ({ t: performance.now(), sync: document.getElementById('sync').textContent,
      snr: document.getElementById('snr').textContent, foff: document.getElementById('foff').textContent,
      buf: document.getElementById('spkBuf').textContent, load: document.getElementById('decLoad').textContent })));
    if (t % 20 === 19){ const s = trace[trace.length - 1];
      console.log(`  t=${(t + 1) / 4}s  ${s.sync.padEnd(12)} SNR ${s.snr.padEnd(6)} offset ${s.foff.padEnd(9)} speech buffer ${s.buf.padEnd(7)} decoder load ${s.load}`); }
  }
  fs.writeFileSync(`${OUT}/live_trace.json`, JSON.stringify(trace));
  const info = await page.textContent('#rxLastInfo');
  console.log('  last over heard:', info || '(none)');
  if (info){
    for (const [btn, fn] of [['#rxLastSave', 'last_heard_speech.wav'], ['#rxLastRaw', 'last_heard_rade.wav']]){
      const [dl] = await Promise.all([page.waitForEvent('download'), page.click(btn)]);
      await dl.saveAs(`${OUT}/${fn}`);
      console.log(`  saved ${dl.suggestedFilename()}`);
    }
  }

  // everything the page's decoder saw and produced, from the moment receive started
  // (fetched as base64: large arrays through JSON would stall the page for seconds)
  const tap = await page.evaluate(() => {
    const cat = a => { const n = a.reduce((s, x) => s + x.length, 0), o = new Float32Array(n); let p = 0; for (const x of a){ o.set(x, p); p += x.length; } return o; };
    const b64 = f => { const u = new Uint8Array(f.buffer); let s = ''; for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode.apply(null, u.subarray(i, i + 0x8000)); return btoa(s); };
    const t = window.radeRxTap;
    return { in: b64(cat(t.in)), feat: b64(cat(t.feat)), pcm: b64(cat(t.pcm)) };
  });
  const B = k => Buffer.from(tap[k], 'base64');
  fs.writeFileSync(`${OUT}/live_in.f32`, B('in'));
  fs.writeFileSync(`${OUT}/live_feat.f32`, B('feat'));
  fs.writeFileSync(`${OUT}/live_pcm.f32`, B('pcm'));
  console.log(`  decoder fed ${(B('in').length / 4 / 8000).toFixed(1)} s of rig audio, `
    + `decoded ${B('feat').length / 4 / 36} feature frames, ${(B('pcm').length / 4 / 16000).toFixed(1)} s of speech`);

  // ---------------------------------------------------------------- 2. pause while transmitting
  console.log('\n=== 2. receive pauses while transmitting ===');
  await page.click('#txBtn'); await page.waitForSelector('#state.tx');
  await page.waitForTimeout(1500);
  const during = await page.textContent('#sync');
  await page.click('#txBtn'); await page.waitForFunction(() => !document.getElementById('state').classList.contains('tx')
    && !document.getElementById('state').classList.contains('end'), null, { timeout: 10000 });
  await page.waitForTimeout(6000);
  const after = await page.textContent('#sync');
  console.log(`  while transmitting: "${during}";  6 s after the over: "${after}"`);
  fs.writeFileSync(`${OUT}/pause.json`, JSON.stringify({ during, after }));

  // ---------------------------------------------------------------- 3. decode a recording
  console.log('\n=== 3. decode a recording ===');
  await page.setInputFiles('#rxFileIn', RXWAV);
  await page.waitForFunction(() => /decoded in|no RADE/.test(document.getElementById('rxFileInfo').textContent), null, { timeout: 60000 });
  console.log('  ' + await page.textContent('#rxFileInfo'));
  const f = await page.evaluate(() => {
    const b64 = f => { const u = new Uint8Array(f.buffer); let s = ''; for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode.apply(null, u.subarray(i, i + 0x8000)); return btoa(s); };
    return { feat: b64(window.radeRxFile.features), pcm: b64(window.radeRxFile.speech) };
  });
  fs.writeFileSync(`${OUT}/file_feat.f32`, Buffer.from(f.feat, 'base64'));
  fs.writeFileSync(`${OUT}/file_pcm.f32`, Buffer.from(f.pcm, 'base64'));
  const [dl] = await Promise.all([page.waitForEvent('download'), page.click('#rxFileSave')]);
  await dl.saveAs(`${OUT}/file_decoded.wav`);
  console.log(`  saved ${dl.suggestedFilename()}`);

  await browser.close();
})().catch(e => { console.error('TEST FAILED:', e); process.exit(1); });
