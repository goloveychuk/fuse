import fs from 'fs';
import path from 'path';
import os from 'os';

const GLOBAL_STORE = path.join(os.homedir(), '.yarn', 'berry', 'store-pnpm');

const entries = fs.readdirSync(GLOBAL_STORE, { withFileTypes: true })
  .filter(e => e.isDirectory() && !e.name.startsWith('.'));

console.log(`Found ${entries.length} packages in global store\n`);

const tmpBase = fs.mkdtempSync(path.join(os.tmpdir(), 'hardlink-bench-'));

async function hardlinkDir(src, dst) {
  await fs.promises.mkdir(dst, { recursive: true });
  const items = await fs.promises.readdir(src, { withFileTypes: true });
  await Promise.all(items.map(item => {
    const srcPath = path.join(src, item.name);
    const dstPath = path.join(dst, item.name);
    if (item.isDirectory()) {
      return hardlinkDir(srcPath, dstPath);
    }
    return fs.promises.link(srcPath, dstPath);
  }));
}

// --- Async parallel (concurrency=5) ---
const dst = path.join(tmpBase, 'hardlink');
fs.mkdirSync(dst);

const start = performance.now();
const concurrency = 5;
let idx = 0;
async function worker() {
  while (idx < entries.length) {
    const i = idx++;
    const entry = entries[i];
    const src = path.join(GLOBAL_STORE, entry.name, 'package');
    if (!fs.existsSync(src)) continue;
    await hardlinkDir(src, path.join(dst, entry.name));
  }
}
await Promise.all(Array.from({ length: concurrency }, () => worker()));
const ms = performance.now() - start;
console.log(`Hardlink parallel (5):  ${ms.toFixed(1)}ms`);

console.log(`\nCleanup...`);
fs.rmSync(tmpBase, { recursive: true });
console.log('Done.');
