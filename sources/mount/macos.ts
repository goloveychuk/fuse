// import { spawn as spawn2 } from 'child_process';
import { execUtils } from '@yarnpkg/core';
import { parse } from 'fast-plist';
import path from 'path';
import os from 'os';
import fs from 'fs';
import type { Mounter } from '.';
import { PortablePath } from '@yarnpkg/fslib';

const CONSTANTS = {
  extensionId: 'app.badim.FSKitExpExtension',
  fsName: 'MyFS',
};


export class MacosMounter implements Mounter {
    async mount(
    mountRoot: PortablePath,
    confPath: string,
    upperDir: PortablePath,
  ) {

    const started = Date.now();
    const res = await execUtils.execvp(
      'mount',
      [
        '-F',
        '-t',
        CONSTANTS.fsName,
        // '-o',
        // `-U=${upperDir}`,
        confPath,
        mountRoot,
      ],
      {
        encoding: 'utf8',
        cwd: process.cwd() as PortablePath,
      },
    );
    if (res.code !== 0) {
      throw new Error(`Failed to mount fuse\n: ${res.stdout}\n${res.stderr}`);
    }
    const elapsed = Date.now() - started;
    // console.log(`Mounted fuse in ${elapsed}ms`);
  }
  async unmount(mountRoot: PortablePath) {
    const res = await execUtils.execvp('umount', ['-f', mountRoot], {
      encoding: 'utf8',
      cwd: process.cwd() as PortablePath,
    });
    if (res.code !== 0) {
      if (res.stderr.includes('not currently mounted')) {
        return;
      }
      const lsof = await execUtils.execvp('lsof', ['+D', mountRoot], {
        encoding: 'utf8',
        cwd: process.cwd() as PortablePath,
      });
      throw new Error(
        `Failed to unmount fuse: ${res.stdout}\n${mountRoot} is used by processes:\n${lsof.stdout}`,
      );
    }
  }
  async supportsFuse() {
    const enabledModules = path.join(
      os.homedir(),
      'Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist',
    );

    if (!fs.existsSync(enabledModules)) {
      return false;
    }

    const enabledModulesPlist = parse(fs.readFileSync(enabledModules, 'utf8'));

    return enabledModulesPlist.includes(CONSTANTS.extensionId);
  }
}
