import { rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { spawn } from 'node:child_process';

const firefoxDistDir = resolve('dist/firefox');
const xpiPath = resolve('dist/requestman-firefox.xpi');

if (!existsSync(firefoxDistDir)) {
  throw new Error('dist/firefox does not exist. Run `npm run build:firefox` first.');
}

await rm(xpiPath, { force: true });

await new Promise((resolvePromise, rejectPromise) => {
  const child = spawn('zip', ['-r', xpiPath, '.'], {
    cwd: firefoxDistDir,
    stdio: 'inherit',
  });

  child.on('error', rejectPromise);
  child.on('exit', (code) => {
    if (code === 0) resolvePromise(undefined);
    else rejectPromise(new Error(`zip exited with code ${code}`));
  });
});

console.log(`Packaged Firefox extension: ${xpiPath}`);
