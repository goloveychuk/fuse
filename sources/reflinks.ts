// @ts-ignore - no type declarations for is-ci
import isCI from 'is-ci';
import { Configuration, tgzUtils, structUtils,Report,MessageName } from '@yarnpkg/core';
import {
  NpmSemverFetcher,
  npmHttpUtils,
  npmConfigUtils,
} from '@yarnpkg/plugin-npm';
import { PortablePath, NodeFS } from '@yarnpkg/fslib';
import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';
import * as crypto from 'crypto';
import { spawn } from 'child_process';
import Module from 'module';
import { withAtomic, MAGIC_HASH_FILE } from './common';

const DAYS_BETWEEN_CLEANUPS = 3;
const DAY_IN_MS = 24 * 60 * 60 * 1000;

interface ReflinkError {
  message: string;
  code: string;
  errno: number;
  path: string;
  dest: string;
}
type ReflinkResult = number | ReflinkError;
type RawReflinkFn = (src: string, dst: string) => Promise<ReflinkResult>;

function loadNativeAddon(absPath: string): any {
  const m = new (Module as any)(absPath);
  (process as any).dlopen(m, absPath);
  return m.exports;
}

async function callReflink(
  fn: RawReflinkFn,
  src: string,
  dst: string,
): Promise<void> {
  const result = await fn(src, dst);
  if (typeof result !== 'number') {
    const err: any = new Error(result.message);
    err.code = result.code;
    err.errno = result.errno;
    err.path = result.path;
    err.dest = result.dest;
    throw err;
  }
}

export class Reflinks {
  static readonly GLOBAL_STORE = path.join(
    os.homedir(),
    '.yarn',
    'berry',
    'store-pnpm',
  );

  private static readonly REFLINK_VERSION = '0.1.19';
  private static readonly REFLINK_BINARIES: Record<string, string> = {
    'darwin-x64': 'reflink-darwin-x64',
    'darwin-arm64': 'reflink-darwin-arm64',
  };

  private reflinkFile: RawReflinkFn | null = null;
  private _supported: Promise<true | string>;

  constructor(
    private configuration: Configuration,
    private report: Report,
    private localStoreDir: string,
  ) {
    this._supported = this.init();
  }

  async isSupported(): Promise<boolean> {
    const result = await this._supported;
    if (result === true) {
      this.report.reportInfoOnce(MessageName.UNNAMED, `Reflinks enabled`);
    } else {
      this.report.reportInfoOnce(MessageName.UNNAMED, `Reflinks disabled (${result})`);
    }
    return result === true;
  }

  private async init(): Promise<true | string> {
    if (process.platform !== 'darwin')
      return `unsupported platform: ${process.platform}`;
    if (isCI)
      return `CI environment`;

    try {
      await fs.promises.mkdir(Reflinks.GLOBAL_STORE, { recursive: true });
      await fs.promises.mkdir(this.localStoreDir, { recursive: true });
    } catch {
      return `cannot create store directories`;
    }

    this.reflinkFile = await this.fetchReflinkBinary();
    if (this.reflinkFile === null)
      return `failed to fetch native binary`;

    if (!(await this.testReflinkSupport()))
      return `clonefile not supported between store and node_modules`;

    return true;
  }

  private async testReflinkSupport(): Promise<boolean> {
    const rnd = crypto.randomUUID();
    const src = path.join(
      Reflinks.GLOBAL_STORE,
      `.reflink-test-${rnd}`,
    );
    const dst = path.join(this.localStoreDir, `.reflink-test-${rnd}`);
    try {
      await fs.promises.writeFile(src, 'test');
      await callReflink(this.reflinkFile!, src, dst);
      return true;
    } catch {
      return false;
    } finally {
      try {
        await fs.promises.unlink(src);
      } catch {}
      try {
        await fs.promises.unlink(dst);
      } catch {}
    }
  }

  private async fetchReflinkBinary(): Promise<RawReflinkFn | null> {
    const platformKey = `${process.platform}-${process.arch}`;
    const pkgShortName = Reflinks.REFLINK_BINARIES[platformKey];
    if (!pkgShortName) return null;

    const cacheDir = path.join(
      Reflinks.GLOBAL_STORE,
      '.reflink-binary',
      `${pkgShortName}-${Reflinks.REFLINK_VERSION}`,
    );
    const bindingFile = `reflink.${platformKey}.node`;
    const bindingPath = path.join(cacheDir, bindingFile);

    if (!fs.existsSync(bindingPath)) {
      const ident = structUtils.makeIdent('reflink', pkgShortName);
      const locator = structUtils.makeLocator(
        ident,
        `npm:${Reflinks.REFLINK_VERSION}`,
      );
      const tarballPath = NpmSemverFetcher.getLocatorUrl(locator);

      const registry = npmConfigUtils.getScopeRegistry('reflink', {
        configuration: this.configuration,
      });

      const buffer = await npmHttpUtils.get(tarballPath, {
        configuration: this.configuration,
        registry,
        ident,
      });

      await withAtomic(cacheDir, async (tmpDir) => {
        await tgzUtils.extractArchiveTo(buffer as Buffer, new NodeFS(), {
          stripComponents: 1,
          prefixPath: tmpDir as PortablePath,
        });
      });
    }

    try {
      const binding = loadNativeAddon(bindingPath);
      return binding.reflinkFile;
    } catch (err) {
      console.error(`Failed to load reflink binary: ${bindingPath}`);
      console.error(err);
      return null;
    }
  }

  getGlobalPackagePath(pkgKey: string): string {
    return path.join(Reflinks.GLOBAL_STORE, pkgKey);
  }

  async cloneToLocal(
    globalPkgPath: string,
    localPkgPath: PortablePath,
  ): Promise<void> {
    await fs.promises.mkdir(path.dirname(localPkgPath), { recursive: true });
    await callReflink(this.reflinkFile!, globalPkgPath, localPkgPath);

    const globalHashFile = path.join(globalPkgPath, MAGIC_HASH_FILE);
    const localHashFile = path.join(localPkgPath, MAGIC_HASH_FILE);
    fs.unlinkSync(localHashFile);
    fs.linkSync(globalHashFile, localHashFile);
  }

  async cleanup(): Promise<void> {
    const lastCleanupFile = path.join(Reflinks.GLOBAL_STORE, '.last-cleanup');
    try {
      const stat = await fs.promises.stat(lastCleanupFile);
      if (Date.now() - stat.mtimeMs < DAYS_BETWEEN_CLEANUPS * DAY_IN_MS) return;
    } catch {}

    await fs.promises.writeFile(lastCleanupFile, new Date().toISOString());

    const unused = await Reflinks.findUnusedPackages(MAGIC_HASH_FILE);
    if (unused.length > 0) {
      this.report.reportInfo(MessageName.UNNAMED, `Reflink store: cleaning ${unused.length} unused packages`);
      Reflinks.removePackages(unused);
    }
  }

  static async findUnusedPackages(hashFileName: string): Promise<string[]> {
    let entries: fs.Dirent[];
    try {
      entries = await fs.promises.readdir(Reflinks.GLOBAL_STORE, {
        withFileTypes: true,
      });
    } catch {
      return [];
    }

    const unused: string[] = [];
    for (const entry of entries) {
      if (!entry.isDirectory() || entry.name.startsWith('.')) continue;
      const hashFile = path.join(
        Reflinks.GLOBAL_STORE,
        entry.name,
        hashFileName,
      );
      try {
        const stat = await fs.promises.stat(hashFile);
        if (stat.nlink === 1) {
          unused.push(entry.name);
        }
      } catch {}
    }
    return unused;
  }

  static removePackages(names: string[]): void {
    if (names.length === 0) return;

    const trashDir = path.join(
      Reflinks.GLOBAL_STORE,
      `.trash-${crypto.randomUUID()}`,
    );
    fs.mkdirSync(trashDir);
    for (const name of names) {
      try {
        fs.renameSync(
          path.join(Reflinks.GLOBAL_STORE, name),
          path.join(trashDir, name),
        );
      } catch {}
    }

    const child = spawn('rm', ['-rf', trashDir], {
      detached: true,
      stdio: 'ignore',
    });
    child.unref();
  }
}
