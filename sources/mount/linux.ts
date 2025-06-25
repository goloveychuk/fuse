import { Mounter } from '.';
import { PortablePath } from '@yarnpkg/fslib';
import { PackageInfo } from '../types';
import { execUtils } from '@yarnpkg/core';
import { fetchArtifact, getPackageInfoForPlatform } from '../fetchBinary';
import path from 'path';

export class LinuxMounter implements Mounter {
  packageInfo: PackageInfo | null;
  constructor() {
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
  async supportsFuse() {
    return this.packageInfo !== null;
  }
}
