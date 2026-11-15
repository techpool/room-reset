// CHROME=/path/to/chromium node tests/browser-smoke.mjs (Node 22+).
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { once } from 'node:events';
import { setTimeout as wait } from 'node:timers/promises';

const profile = await mkdtemp(join(tmpdir(), 'room-reset-chrome-'));
const executable =
  process.env.CHROME ||
  (process.platform === 'darwin'
    ? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
    : 'chromium');
const chrome = spawn(
  executable,
  [
    '--headless=new',
    '--disable-gpu',
    '--disable-background-networking',
    '--disable-extensions',
    '--no-first-run',
    '--remote-debugging-port=0',
    '--user-data-dir=' + profile,
    'about:blank',
  ],
  { stdio: 'ignore' },
);
const terminal = once(chrome, 'exit');
let socket,
  sequence = 0;
const calls = new Map(),
  errors = [];
async function until(operation) {
  const deadline = Date.now() + 45000;
  while (Date.now() < deadline) {
    const value = await operation();
    if (value) return value;
    await wait(55);
  }
  throw new Error('Timed out: ' + operation.toString().slice(0, 200));
}
function send(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = ++sequence;
    calls.set(id, { resolve, reject });
    socket.send(JSON.stringify({ id, method, params }));
  });
}
async function js(expression) {
  const r = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  assert.equal(
    r.exceptionDetails,
    undefined,
    expression + ': ' + JSON.stringify(r.exceptionDetails),
  );
  return r.result.value;
}
const $ = (sel) => `document.querySelector(${JSON.stringify(sel)})`;
const click = (sel) => js($(sel) + '.click()');
const count = () => js('document.querySelectorAll(".object").length');
const ready = () => until(() => js(`document.body?.getAttribute('aria-busy') === 'false'`));
const centered = (sel) =>
  js(
    `(() => { const r = ${$(sel)}.getBoundingClientRect(); return {x:r.x+r.width/2,y:r.y+r.height/2}; })()`,
  );
async function pointer(from, to) {
  const a = await centered(from),
    b = await centered(to);
  await send('Input.dispatchMouseEvent', {
    type: 'mousePressed',
    ...a,
    button: 'left',
    buttons: 1,
    clickCount: 1,
  });
  await send('Input.dispatchMouseEvent', {
    type: 'mouseMoved',
    x: a.x + 10,
    y: a.y,
    button: 'left',
    buttons: 1,
  });
  await send('Input.dispatchMouseEvent', { type: 'mouseMoved', ...b, button: 'left', buttons: 1 });
  await send('Input.dispatchMouseEvent', {
    type: 'mouseReleased',
    ...b,
    button: 'left',
    clickCount: 1,
  });
}
async function screenshot(name) {
  if (!process.env.SCREENSHOTS) return;
  await mkdir(process.env.SCREENSHOTS, { recursive: true });
  const { data } = await send('Page.captureScreenshot', { format: 'png' });
  await writeFile(join(process.env.SCREENSHOTS, name + '.png'), Buffer.from(data, 'base64'));
}
try {
  const port = await until(async () => {
    try {
      return Number((await readFile(join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0]);
    } catch {
      return 0;
    }
  });
  const tabs = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
  socket = new WebSocket(tabs.find((tab) => tab.type === 'page').webSocketDebuggerUrl);
  socket.addEventListener('message', ({ data }) => {
    const msg = JSON.parse(data);
    if (msg.method === 'Runtime.exceptionThrown') errors.push(msg.params.exceptionDetails);
    if (!msg.id) return;
    const task = calls.get(msg.id);
    if (!task) return;
    calls.delete(msg.id);
    if (msg.error) task.reject(new Error(msg.error.message));
    else task.resolve(msg.result);
  });
  await once(socket, 'open');
  await send('Page.enable');
  await send('Runtime.enable');
  await send('Emulation.setDeviceMetricsOverride', {
    width: 1160,
    height: 800,
    deviceScaleFactor: 1,
    mobile: false,
  });
  const url = new URL('../web/index.html', import.meta.url).href;
  await send('Page.navigate', { url });
  await ready();
  await until(() =>
    js('Array.from(document.images).every(img => img.complete && img.naturalWidth > 0)'),
  );
  assert.equal(await count(), 6);
  await screenshot('practice-desktop');
  await js("const area = document.querySelector('#area'); area.value='rug';area.dispatchEvent(new Event('change'))");
  assert.equal(await js($('#sweepLabel') + '.textContent'), 'Sweep rug');
  await click('#sweep'); await ready();
  assert.equal(await count(), 4);
  await click('#undo'); assert.equal(await count(), 6);
  await pointer('[data-item=p0]', '.tray[data-kind=paper]');
  await ready();
  assert.equal(await count(), 5);
  await wait(340);
  await click('[data-item=p1]');
  await click('.tray[data-kind=paper]');
  assert.equal(await count(), 5);
  await click('.tray[data-kind=media]');
  await ready();
  assert.equal(await count(), 4);
  await click('.tray[data-kind=paper]');
  await click('#sweep');
  await ready();
  assert.equal(await count(), 3);
  await click('#undo');
  assert.equal(await count(), 4);
  await send('Page.reload');
  await until(
    async () => (await count()) === 4 && (await js('document.readyState === "complete"')),
  );
  await ready();
  await click('#sweep');
  await ready();
  assert.equal(await count(), 0);
  assert.equal(await js($('#sweepLabel') + '.textContent'), 'Next round');
  await click('#sweep');
  assert.equal(await count(), 7);
  assert.equal(await js($('#title') + '.textContent'), 'The moonlit room');
  await until(() => js($('#backdrop') + '.complete && ' + $('#backdrop') + '.naturalWidth > 0'));
  await screenshot('practice-evening');
  await click('#folder');
  assert.equal(await js($('#sheet') + '.open'), true);
  await click('#closeSheet');
  await send('Emulation.setDeviceMetricsOverride', {
    width: 390,
    height: 844,
    deviceScaleFactor: 1,
    mobile: true,
  });
  await js("localStorage.removeItem('room-reset.practice')");
  await send('Page.reload');
  await until(async () => (await count()) === 6);
  assert.equal(await js('document.documentElement.scrollWidth <= innerWidth'), true);
  await screenshot('practice-phone');
  await send('Emulation.setEmulatedMedia', {
    features: [{ name: 'prefers-reduced-motion', value: 'reduce' }],
  });
  await send('Emulation.setTouchEmulationEnabled', { enabled: true });
  const source = await centered('[data-item=p2]'),
    drop = await centered('.tray[data-kind=archive]');
  assert.ok(drop.y < 844, 'Phone drop target is visible without scrolling');
  for (const [type, points] of [
    ['touchStart', [source]],
    ['touchMove', [{ x: source.x + 15, y: source.y }]],
    ['touchMove', [drop]],
    ['touchEnd', []],
  ]) {
    await send('Input.dispatchTouchEvent', { type, touchPoints: points });
  }
  await until(async () => (await count()) === 5);
  await click('#undo');
  await js($('[data-item=p2]') + '.focus()');
  async function enter() {
    for (const type of ['keyDown', 'keyUp'])
      await send('Input.dispatchKeyEvent', {
        type,
        key: 'Enter',
        code: 'Enter',
        windowsVirtualKeyCode: 13,
        text: type === 'keyDown' ? '\r' : '',
      });
  }
  await enter();
  assert.equal(await js("document.activeElement.matches('.tray[data-kind=archive]')"), true);
  await enter();
  await until(async () => (await count()) === 5);
  await click('#undo');
  await js(`window.testCalls=[];window.testItems=[{id:'x01',name:'notes.txt',bytes:32,kind:'paper'},{id:'x02',name:'copy.archive.gz',bytes:512,kind:'cache'}]; window.testStaged=0;window.testUndo=false;
    window.RoomNative={postMessage(raw){const m=JSON.parse(raw);testCalls.push(m);let value=null;
      if(m.op==='tidy'){window.testPrior=testItems.slice();testItems=testItems.filter(i=>!m.args.ids.includes(i.id));testUndo=true;testStaged+=testPrior.filter(i=>i.kind==='cache'&&m.args.ids.includes(i.id)).length;}
      if(m.op==='undo'){testItems=testPrior;testUndo=false;testStaged=0;} if(m.op==='purge'){testStaged=0;testUndo=false;}
      if(m.op!=='scan'||testCalls.length>1)value={name:'Fixture room',items:testItems,canUndo:testUndo,stagedCount:testStaged,stagedBytes:testStaged*512};queueMicrotask(()=>window.roomReply(m.id,{ok:true,value}));}};`);
  await click('#folder');
  await ready();
  assert.equal(await count(), 2);
  assert.equal(await js($('#title') + '.textContent'), 'Fixture room');
  await click('#sweep');
  assert.equal(await js('testCalls.some(c=>c.op==="tidy")'), false);
  assert.equal(await js('document.querySelectorAll(".file-row").length'), 2);
  await screenshot('folder-preview');
  await click('.sheet-actions button:first-child');
  await click('#list');
  await click('.file-jump');
  await click('.tray[data-kind=paper]');
  await click('.sheet-actions .confirm');
  await ready();
  assert.equal(await count(), 1);
  await click('#undo');
  await ready();
  assert.equal(await count(), 2);
  await click('#sweep');
  await click('.sheet-actions .confirm');
  await ready();
  assert.equal(await count(), 0);
  await click('#empty');
  assert.equal(await js('testCalls.some(c=>c.op==="purge")'), false);
  await click('.danger');
  await ready();
  assert.equal(await js('testCalls.filter(c=>c.op==="purge").length'), 1);
  await click('#practice');
  assert.equal(await count(), 6);
  await js(`window.retryOps = [];
    window.RoomNative.postMessage = raw => {
      const {id, op} = JSON.parse(raw);
      retryOps.push(op);
      const response = op === 'scan'
        ? {ok:false, error:'Permission revoked'}
        : {ok:true, value:{name:'Replacement folder', items:[{id:'new', name:'new.txt', kind:'paper', bytes:12}], canUndo:false, stagedCount:0}};
      queueMicrotask(() => window.roomReply(id, response));
    };`);
  await click('#folder');
  await ready();
  assert.deepEqual(await js('retryOps'), ['scan', 'pick']);
  assert.equal(await js($('#title') + '.textContent'), 'Replacement folder');
  assert.equal(await count(), 1);
  assert.deepEqual(errors, []);
  console.log(
    'Passed desktop drag, tap, wrong tray, partial/room sweep, undo, reload, night round, phone touch drag, keyboard sorting, folder previews, native tidy, undo, purge, mode isolation and revoked-folder recovery.',
  );
} finally {
  socket?.close();
  chrome.kill();
  await terminal.catch(() => {});
  await rm(profile, { recursive: true, force: true, maxRetries: 3 });
}
