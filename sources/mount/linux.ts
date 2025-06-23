import { Mounter } from ".";
import { PortablePath } from "@yarnpkg/fslib";


export class LinuxMounter implements Mounter {
    async mount(mountRoot: PortablePath, confPath: string, upperDir: PortablePath) {
      throw new Error('Not implemented');
    }
    async unmount(mountRoot: PortablePath) {
      throw new Error('Not implemented');
    }
    async supportsFuse() {
      return false;
    }
  }