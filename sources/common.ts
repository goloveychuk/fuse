import * as fs from 'fs';
import * as crypto from 'crypto';

export const MAGIC_HASH_FILE = '.yarn-content-hash';

export async function withAtomic(targetDir: string, fn: (tmpDir: string) => Promise<void>): Promise<void> {
  const tmpDir = `${targetDir}.tmp-${crypto.randomUUID()}`;
  await fs.promises.mkdir(tmpDir, { recursive: true });
  await fn(tmpDir);
  try {
    await fs.promises.rename(tmpDir, targetDir);
  } catch (err: any) {
    await fs.promises.rm(tmpDir, { recursive: true, force: true });
    if (err.code !== 'ENOTEMPTY' && err.code !== 'EEXIST') throw err;
  }
}

export class PromiseOnce {
  private inflight = new Map<string, Promise<void>>();

  call(key: string, fn: () => Promise<void>): Promise<void> {
    let p = this.inflight.get(key);
    if (!p) {
      p = fn();
      this.inflight.set(key, p);
    }
    return p;
  }
}
