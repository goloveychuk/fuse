import { Mounter } from '.';
import { PortablePath } from '@yarnpkg/fslib';
import { PackageInfo } from '../types';
import { execUtils, MessageName, Report } from '@yarnpkg/core';
import { fetchArtifact, getPackageInfoForPlatform } from '../fetchBinary';
import path from 'path';
import fs from 'fs';
import { spawn } from 'child_process';



function isExecutableAvailable(executable: string): Promise<boolean> {
  return new Promise(resolve => {
    const process = spawn(executable, ['--version']);
    
    process.on('error', (err) => {
      // ENOENT means the executable doesn't exist
      if ((err as any).code === 'ENOENT') {
        resolve(false);
      } else {
        // Other errors might mean permissions issues or other problems
        // but the executable likely exists
        resolve(true);
      }
    });
    
    // If we get here, the process was spawned successfully
    process.on('close', () => {
      resolve(true);
    });
  });
}

const noResult = Symbol('noResult');

async function execThrow(command: string, args: string[]) {
  const res = await execUtils.execvp(command, args, {
    cwd: process.cwd() as PortablePath,
    encoding: 'utf8',
  });
  if (res.code !== 0) {
    throw new Error(`Failed to execute ${command}: ${res.stderr}`);
  }
  return res;
}

function memo<T>(fn: () => Promise<T>) {
  let value: T | typeof noResult = noResult;
  return async () => {
    if (value === noResult) {
      value = await fn();
    }
    return value;
  }
}
export class LinuxMounter implements Mounter {
  packageInfo: PackageInfo | null;
  constructor(private report: Report) {
    this.packageInfo = getPackageInfoForPlatform();
  }
  private fetchBinaries = memo(async () => {
    if (!this.packageInfo) {
      throw new Error('Should not be called');
    }
    const dirPath = await fetchArtifact(this.packageInfo);
    const fuseExecPath = path.join(dirPath, 'Fuse');
    fs.chmodSync(fuseExecPath, '755');
    if (!await this.hasFusermount3()) {
      const fusermount3Path = '/usr/local/bin/fusermount3'
      await execThrow('sudo', ['cp', path.join(dirPath, 'fusermount3'), fusermount3Path]);
      await execThrow('sudo', ['chown', 'root:root', fusermount3Path]);
      await execThrow('sudo', ['chmod', '4755', fusermount3Path]);
    }
    return {
      fuseExecPath,
    }
  })
  async mount(
    mountRoot: PortablePath,
    confPath: string,
    upperDir: PortablePath,
  ) {
    const { fuseExecPath } = await this.fetchBinaries();
    await execThrow(fuseExecPath, ['--manifest', confPath, '--detach', mountRoot]);
  }
  async unmount(mountRoot: PortablePath) {
    await this.fetchBinaries();
    const res = await execUtils.execvp('fusermount3', ['-u', mountRoot, '-o', '-f'], {
      encoding: 'utf8',
      cwd: process.cwd() as PortablePath,
    });
    if (res.code !== 0) {
      if (res.stderr.includes('not found in /etc/mtab')) {
        return;
      }
      throw new Error(`Failed to unmount Fuse: ${res.stderr}`);
    }
  }

  private async hasFusermount3() {
    return await isExecutableAvailable('fusermount3');
  }
  private async hasSudo() {
    return await isExecutableAvailable('sudo');
  }

  async supportsFuse() {
    if (this.packageInfo === null) {
      return false;
    }
    if (await this.hasFusermount3()) {
      return true;
    }
    if (await this.hasSudo()) {
      return true
    }
    this.report.reportWarningOnce(MessageName.UNNAMED, `No fusermount3 found nor sudo available, Fuse will not be available`);

    return false
  }

}
