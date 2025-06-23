import { PortablePath } from '@yarnpkg/fslib';
import os from 'os';
import { MacosMounter } from './macos';
import { LinuxMounter } from './linux';

export interface Mounter {
  supportsFuse(): Promise<boolean>;
  unmount(mountRoot: PortablePath): Promise<void>;
  mount(
    mountRoot: PortablePath,
    confPath: string,
    upperDir: PortablePath,
  ): Promise<void>;
}

class NoopMounter implements Mounter {
  async supportsFuse() {
    return false;
  }
  async unmount(mountRoot: PortablePath) {
    return;
  } 
  async mount(mountRoot: PortablePath, confPath: string, upperDir: PortablePath) {
    return;
  }
}

export function getMounter(): Mounter {
  const platform = os.platform();
  switch (platform) {
    case 'darwin':
      return new MacosMounter();
    case 'linux':
      return new LinuxMounter();
    default:
      return new NoopMounter();
  }
}
