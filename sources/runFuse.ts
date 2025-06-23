import * as path from 'path';
import * as fs from 'fs';
import * as crypto from 'crypto';
import { spawn, spawnSync } from 'child_process';
import { pipeline } from 'stream/promises';
import { setInterval } from 'timers/promises';
import { xfs, ppath, PortablePath } from '@yarnpkg/fslib';
import { getExecFileName } from '../utils.mjs';
// import metadata from '../fuse/output/metadata.json';
import { fileURLToPath } from 'url';
import * as os from 'os';
import * as https from 'https';

async function checkChecksum(p: string, checksum: string) {
  const hash = crypto.createHash('sha512');
  const stream = fs.createReadStream(p);
  await pipeline(stream, hash);
  const hashRes = hash.digest('hex');
  if (hashRes !== checksum) {
    throw new Error(`Checksum mismatch for ${p}`);
  }
}





function downloadFile(url: string, dest: string) {
  const tmpPath = path.join(os.tmpdir(), crypto.randomUUID());
  return new Promise<void>((resolve, reject) => {
    const file = fs.createWriteStream(tmpPath);
    const req = https.get(url, (res) => {
      res.pipe(file);
      file.on('finish', () => {
        file.close();
        fs.rename(tmpPath, dest, (err) => {
          if (err) {
            reject(err);
          } else {
            resolve();
          }
        });
      });
    });
    req.on('error', (err) => {
      reject(err);
    });
    req.end();
  });
}

async function downloadFileOrCache(url: string): Promise<string> {
  throw new Error('Not implemented');
}

async function unmountFuse(mountRoot: PortablePath) {
  // df -h /tmp/Volume
  
}

export async function mountFuse(mountRoot: PortablePath, confPath: string) {
  if (await xfs.existsPromise(mountRoot)) {
    await unmountFuse(mountRoot); //todo run sooner
  } else {
    await xfs.mkdirpPromise(mountRoot);
  }
  const result = spawnSync(
    'mount',
    ['-F', '-t', 'MyFS', '-o', `-m=${confPath}`, '/dev/disk5', mountRoot],
    {
      // detached: true,
      stdio: 'inherit',
    },
  );
  console.log(result);
  // if (result.status !== 0) { //does not work on macos
  //   throw new Error(`Failed to mount fuse: ${result.stderr}`);
  // }
  return;
  // const name = getExecFileName() as keyof typeof metadata;
  // const meta = metadata[name];
  // if (!meta) {
  //   throw new Error(`No checksum found for ${name}`);
  // }
  // const filePath = new URL(meta.path);
  // let realFilePath: string;
  // if (filePath.protocol === 'file:') {
  //   realFilePath = fileURLToPath(filePath);
  // } else {
  //   realFilePath = await downloadFileOrCache(filePath.href);
  // }
  // await checkChecksum(realFilePath, meta.checksum);
  // const child = spawn(realFilePath, [confPath], {
  //   detached: true,
  //   stdio: 'inherit',
  // });
  // child.unref();

  // await waitToMount(nmPath);

  // await api.waitToInit();
}
