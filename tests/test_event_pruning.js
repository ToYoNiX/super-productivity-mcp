/**
 * Verifies the hook-event files are capped instead of accumulating forever.
 *
 * Runs the prune script straight out of plugin.js, in the same vm sandbox Super
 * Productivity uses, against a throwaway directory.
 */
const vm = require('vm');
const fs = require('fs');
const os = require('os');
const path = require('path');

const pluginPath = path.join(__dirname, '..', 'plugin.js');
const src = fs.readFileSync(pluginPath, 'utf8');

function extractScripts(s) {
  const out = [];
  let i = 0;
  while ((i = s.indexOf('script: `', i)) !== -1) {
    const start = i + 'script: `'.length;
    const end = s.indexOf('`,', start);
    out.push(s.slice(start, end).replace(/\\`/g, '`').replace(/\\\$/g, '$'));
    i = end;
  }
  return out;
}

const pruneScript = extractScripts(src).find((x) => x.includes('remaining'));
if (!pruneScript) {
  console.error('FAIL: prune script not found in plugin.js');
  process.exit(1);
}

function runDirect(script, args) {
  const sandbox = {
    require: (m) => {
      if (m === 'fs') return fs;
      if (m === 'path') return path;
      if (m === 'os') return os;
      throw new Error(`Module '${m}' is not allowed`);
    },
    console: { log() {}, error() {} },
    JSON, Math,
    args: args || [],
    __result: undefined,
  };
  const wrapped =
    `(async function(){ const r = await (async function(){ ${script} })(); __result = r; })()` +
    `.catch(e => { __result = { __throw: e.message }; });`;
  vm.runInContext(wrapped, vm.createContext(sandbox), { timeout: 5000 });
  return new Promise((res) => setImmediate(() => res(sandbox.__result)));
}

let failures = 0;
function check(label, ok, detail) {
  if (!ok) failures++;
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${label}${detail ? '  -> ' + detail : ''}`);
}

(async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sp-mcp-events-'));

  // 60 events plus files that must survive: a response and an unrelated file.
  const base = 1790000000000;
  for (let i = 0; i < 60; i++) {
    fs.writeFileSync(path.join(dir, `${base + i}_taskUpdate_event.json`), '{}');
  }
  fs.writeFileSync(path.join(dir, 'getTasks_1_response.json'), '{}');
  fs.writeFileSync(path.join(dir, 'unrelated.txt'), 'keep me');

  const r = await runDirect(pruneScript, [dir, 50]);
  check('prune reports success', r && r.success === true, JSON.stringify(r));
  check('removed the excess', r && r.removed === 10, `removed=${r && r.removed}`);

  const left = fs.readdirSync(dir).filter((f) => f.endsWith('_event.json')).sort();
  check('cap respected', left.length === 50, `${left.length} remaining`);
  check('kept the NEWEST events', left[0] === `${base + 10}_taskUpdate_event.json`,
        `oldest kept: ${left[0]}`);
  check('response files untouched', fs.existsSync(path.join(dir, 'getTasks_1_response.json')));
  check('unrelated files untouched', fs.existsSync(path.join(dir, 'unrelated.txt')));

  // Running again with nothing to do must be a no-op.
  const r2 = await runDirect(pruneScript, [dir, 50]);
  check('idempotent', r2 && r2.success === true && r2.removed === 0, `removed=${r2 && r2.removed}`);

  // keep=0 clears them all, for users who disable events.
  const r3 = await runDirect(pruneScript, [dir, 0]);
  const leftAfter = fs.readdirSync(dir).filter((f) => f.endsWith('_event.json'));
  check('keep=0 removes every event', r3 && r3.removed === 50 && leftAfter.length === 0,
        `${leftAfter.length} remaining`);
  check('response file still there after keep=0',
        fs.existsSync(path.join(dir, 'getTasks_1_response.json')));

  fs.rmSync(dir, { recursive: true, force: true });
  console.log('\n' + (failures ? `RESULT: ${failures} FAILED` : 'RESULT: ALL PASS'));
  process.exit(failures ? 1 : 0);
})();
