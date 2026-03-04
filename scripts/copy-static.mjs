import { cp, mkdir, rm, copyFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const target = process.argv[2];
if (!['chrome', 'firefox'].includes(target)) {
  throw new Error('Usage: node scripts/copy-static.mjs <chrome|firefox>');
}

const outDir = resolve('dist', target);
const publicDir = resolve('public');

await mkdir(outDir, { recursive: true });
await cp(publicDir, outDir, { recursive: true });

await Promise.all([
  rm(resolve(outDir, 'manifest.json'), { force: true }),
  rm(resolve(outDir, 'manifest.chrome.json'), { force: true }),
  rm(resolve(outDir, 'manifest.firefox.json'), { force: true }),
]);

await copyFile(resolve(publicDir, `manifest.${target}.json`), resolve(outDir, 'manifest.json'));

console.log(`Copied public/ -> dist/${target} and generated manifest.json for ${target}.`);
