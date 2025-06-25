import { Mounter } from '.';
import { PortablePath } from '@yarnpkg/fslib';
import { PackageInfo } from '../types';
import { execUtils, MessageName, Report } from '@yarnpkg/core';
import { fetchArtifact, getPackageInfoForPlatform } from '../fetchBinary';
import path from 'path';
import fs from 'fs';

export class LinuxMounter implements Mounter {
  packageInfo: PackageInfo | null;
  constructor(private report: Report) {
    this.packageInfo = getPackageInfoForPlatform();
  }
  async mount(
    mountRoot: PortablePath,
    confPath: string,
    upperDir: PortablePath,
  ) {
    if (!this.packageInfo) {
      throw new Error('Should not be called');
    }
    const dirPath = await fetchArtifact(this.packageInfo);
    const fuseExecPath = path.join(dirPath, 'Fuse');
    fs.chmodSync(fuseExecPath, '755');
    if (!await this.hasFusermount3()) {
        const fusermount3Path = '/usr/bin/fusermount3'
        fs.chmodSync(fusermount3Path, '755');
        if ((await execUtils.execvp('sudo', ['chown', 'root:root', fusermount3Path], {
            cwd: process.cwd() as PortablePath,
        })).code !== 0) {
            throw new Error(`Failed to chown fusermount3`);
        }
        if ((await execUtils.execvp('sudo', ['chmod', 'u+s', fusermount3Path], {
            cwd: process.cwd() as PortablePath,
        })).code !== 0) {
            throw new Error(`Failed to chmod fusermount3`);
        }

    }
    const res = await execUtils.execvp(
      fuseExecPath,
      ['--manifest', confPath, '--detach', mountRoot],
      {
        cwd: process.cwd() as PortablePath,
      },
    );
    if (res.code !== 0) {
      throw new Error(`Failed to mount Fuse: ${res.stderr}`);
    }
  }
  async unmount(mountRoot: PortablePath) {
    const res = await execUtils.execvp('umount', ['-f', mountRoot], {
      encoding: 'utf8',
      cwd: process.cwd() as PortablePath,
    });
    if (res.code !== 0) {
      if (res.stderr.includes('not mounted')) {
        return;
      }
      throw new Error(`Failed to unmount Fuse: ${res.stderr}`);
    }
  }
  private async hasFusermount3() {
    const res = await execUtils.execvp('fusermount3', ['-V'], {
      encoding: 'utf8',
      cwd: process.cwd() as PortablePath,
    });
    return res.code === 0;
  }
  private async hasSudo() {
    const res = await execUtils.execvp('sudo', ['-V'], {
      encoding: 'utf8',
      cwd: process.cwd() as PortablePath,
    });
    return res.code === 0;
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
