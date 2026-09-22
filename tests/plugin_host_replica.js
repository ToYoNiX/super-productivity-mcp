/**
 * Replica of Super Productivity's plugin host, for testing without the app.
 *
 * Mirrors electron/plugin-node-executor.js `executeDirectly`: plugin scripts run
 * in a vm context exposing only fs/path/os/console/JSON/args, and notably NO
 * `process` object. That absence is what broke upstream's data-directory lookup,
 * so the tests must reproduce it exactly.
 *
 * Usage: node tests/plugin_host_replica.js <path-to-plugin.js> [seconds]
 */
const vm = require('vm');
const fs = require('fs');
const path = require('path');
const os = require('os');

const pluginPath = process.argv[2] || path.join(__dirname, '..', 'plugin.js');
const runSeconds = parseInt(process.argv[3] || '30', 10);
const pluginSrc = fs.readFileSync(pluginPath, 'utf8');

/** Pull the `script:` template literals back out of plugin.js. */
function extractScripts(src) {
  const out = [];
  let i = 0;
  while ((i = src.indexOf('script: `', i)) !== -1) {
    const start = i + 'script: `'.length;
    const end = src.indexOf('`,', start);
    // Undo template-literal escaping; the JS engine does this before the host
    // ever sees the string.
    out.push(src.slice(start, end).replace(/\\`/g, '`').replace(/\\\$/g, '$'));
    i = end;
  }
  return out;
}

const scripts = extractScripts(pluginSrc);
const find = (kw) => scripts.find((s) => s.includes(kw));
const setupScript = find('write-probe');
const pollScript = find('newCommands');
const respondScript = find('_response.json');

if (!setupScript || !pollScript || !respondScript) {
  console.error('FAIL: could not extract the expected scripts from plugin.js');
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
    JSON,
    args: args || [],
    __result: undefined,
  };
  const wrapped =
    `(async function(){ const r = await (async function(){ ${script} })(); __result = r; })()` +
    `.catch(e => { __result = { __throw: e.message }; });`;
  vm.runInContext(wrapped, vm.createContext(sandbox), { timeout: 5000 });
  return new Promise((resolve) => setImmediate(() => resolve(sandbox.__result)));
}

// Stand-in for PluginAPI's responses.
const FAKE_TASKS = [
  { id: 't1', title: 'Task one', isDone: false, timeSpent: 0, tagIds: [] },
  { id: 't2', title: 'Task two', isDone: true, timeSpent: 900000, tagIds: [] },
];

function handle(action, command) {
  switch (action) {
    case 'getTasks': return FAKE_TASKS;
    case 'getAllProjects': return [{ id: 'p1', title: 'Inbox' }];
    case 'getAllTags': return [{ id: 'TODAY', title: 'Today' }];
    case 'addTask': return 'new-task-id';
    case 'addProject': return 'new-project-id';
    case 'addTag': return 'new-tag-id';
    case 'updateTask': return { updated: true, taskId: command.taskId };
    case 'deleteTask': return { deleted: true, taskId: command.taskId };
    case 'showSnack': return { shown: true };
    default: return { unhandled: action };
  }
}

(async () => {
  const dirs = await runDirect(setupScript, []);
  if (!dirs || !dirs.success) {
    console.error('FAIL: setup script did not resolve a directory:', JSON.stringify(dirs));
    process.exit(1);
  }
  console.log('HOST_READY ' + dirs.mcpServerPath);

  let lastProcessed = 0;
  const deadline = Date.now() + runSeconds * 1000;
  while (Date.now() < deadline) {
    const res = await runDirect(pollScript, [dirs.commandDir, lastProcessed]);
    if (res && res.success && Array.isArray(res.commands)) {
      for (const ci of res.commands) {
        const result = handle(ci.command.action, ci.command);
        await runDirect(respondScript, [
          dirs.responseDir,
          ci.command.id,
          { success: true, result, timestamp: Date.now() },
        ]);
        console.log('HOST_HANDLED ' + ci.command.action);
        try { fs.unlinkSync(ci.path); } catch (e) { /* already gone */ }
        lastProcessed = Math.max(lastProcessed, ci.timestamp);
      }
    }
    await new Promise((r) => setTimeout(r, 200));
  }
})().catch((e) => {
  console.error('FAIL: host replica crashed:', e.message);
  process.exit(1);
});
