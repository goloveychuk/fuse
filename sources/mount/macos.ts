// import { spawn as spawn2 } from 'child_process';
import { execUtils } from '@yarnpkg/core';
import { parse } from 'fast-plist';
import path from 'path';
import { fileURLToPath } from 'url';
import os from 'os';
import fs from 'fs';
import type { Mounter } from '.';
import { PortablePath } from '@yarnpkg/fslib';

const CONSTANTS = {
  extensionId: 'app.badim.FSKitExpExtension',
  fsName: 'MyFS',
  imagePath: path.join(os.homedir(), '.yarn/berry/fuse.img'),
};

async function findExistingDevice() {
  const res = await execUtils.execvp('hdiutil', ['info', '-plist'], {
    encoding: 'utf8',
    cwd: process.cwd() as PortablePath,
  });
  const output = res.stdout.toString();
  const plist = parse(output);
  for (const image of plist.images) {
    if (image['image-path'] == CONSTANTS.imagePath) {
      return image['system-entities'][0]['dev-entry'];
    }
  }
  return null;
}

export class MacosMounter implements Mounter {
  private async getDevice() {
    const dev = await findExistingDevice();
    if (dev) {
      return dev;
    }
    if (!fs.existsSync(CONSTANTS.imagePath)) {
      fs.writeFileSync(CONSTANTS.imagePath, Buffer.alloc(1024 * 1024 * 1));
    }
    const res = await execUtils.execvp(
      'hdiutil',
      [
        'attach',
        '-nomount',
        '-imagekey',
        'diskimage-class=CRawDiskImage',
        CONSTANTS.imagePath,
      ],
      {
        encoding: 'utf8',
        cwd: process.cwd() as PortablePath,
      },
    );
    if (res.code !== 0) {
      throw new Error(`Failed to attach image\n: ${res.stdout}\n${res.stderr}`);
    }
    const dev2 = findExistingDevice();
    if (!dev2) {
      throw new Error(`Failed to find attached device`);
    }
    return dev2;
  }
  async mount(
    mountRoot: PortablePath,
    confPath: string,
    upperDir: PortablePath,
  ) {
    const dev = await this.getDevice();

    const res = await execUtils.execvp(
      'mount',
      [
        '-F',
        '-t',
        CONSTANTS.fsName,
        '-o',
        `-m=${confPath},-u=${upperDir}`,
        dev,
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

    const enabledModulesPlist = parse(fs.readFileSync(enabledModules, 'utf8'));

    return enabledModulesPlist.includes(CONSTANTS.extensionId);
  }
}
