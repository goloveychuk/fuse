import { reflinkFileSync, reflinkFile } from '@reflink/reflink';
import fs from 'fs';
import path from 'path';
import os from 'os';

const GLOBAL_STORE = path.join(os.homedir(), '.yarn', 'berry', 'store-pnpm');

const entries = fs.readdirSync(GLOBAL_STORE, { withFileTypes: true })
  .filter(e => e.isDirectory() && !e.name.startsWith('.'));

console.log(`Found ${entries.length} packages in global store\n`);

const tmpBase = fs.mkdtempSync(path.join(os.tmpdir(), 'reflink-bench-'));

// --- Sync benchmark ---
const syncDst = path.join(tmpBase, 'sync');
fs.mkdirSync(syncDst);

const syncStart = performance.now();
for (const entry of entries) {
  const src = path.join(GLOBAL_STORE, entry.name, 'package');
  const dst = path.join(syncDst, entry.name);
  if (!fs.existsSync(src)) continue;
  reflinkFileSync(src, dst);
}
const syncMs = performance.now() - syncStart;
console.log(`Sync:  ${syncMs.toFixed(1)}ms`);

// --- Async sequential benchmark ---
const seqDst = path.join(tmpBase, 'async-seq');
fs.mkdirSync(seqDst);

const seqStart = performance.now();
for (const entry of entries) {
  const src = path.join(GLOBAL_STORE, entry.name, 'package');
  const dst = path.join(seqDst, entry.name);
  if (!fs.existsSync(src)) continue;
  await reflinkFile(src, dst);
}
const seqMs = performance.now() - seqStart;
console.log(`Async sequential:  ${seqMs.toFixed(1)}ms`);

// --- Async parallel (unbounded) benchmark ---
const parDst = path.join(tmpBase, 'async-par');
fs.mkdirSync(parDst);

const parStart = performance.now();
await Promise.all(entries.map(entry => {
  const src = path.join(GLOBAL_STORE, entry.name, 'package');
  const dst = path.join(parDst, entry.name);
  if (!fs.existsSync(src)) return;
  return reflinkFile(src, dst);
}));
const parMs = performance.now() - parStart;
console.log(`Async parallel (all):  ${parMs.toFixed(1)}ms`);

// --- Async parallel (batched, concurrency=5) benchmark ---
const bat5Dst = path.join(tmpBase, 'async-bat5');
fs.mkdirSync(bat5Dst);

const bat5Start = performance.now();
const concurrency = 5;
let idx = 0;
async function worker5() {
  while (idx < entries.length) {
    const i = idx++;
    const entry = entries[i];
    const src = path.join(GLOBAL_STORE, entry.name, 'package');
    const dst = path.join(bat5Dst, entry.name);
    if (!fs.existsSync(src)) continue;
    await reflinkFile(src, dst);
  }
}
await Promise.all(Array.from({ length: concurrency }, () => worker5()));
const bat5Ms = performance.now() - bat5Start;
console.log(`Async parallel (5):  ${bat5Ms.toFixed(1)}ms`);

console.log(`\nCleanup...`);
fs.rmSync(tmpBase, { recursive: true });
console.log('Done.');
