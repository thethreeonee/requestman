import { spawnSync } from 'node:child_process';

function run(cmd, args) {
  const result = spawnSync(cmd, args, { encoding: 'utf8' });
  return {
    code: result.status ?? 1,
    output: `${result.stdout ?? ''}${result.stderr ?? ''}`,
  };
}

function collectReferenceErrors(tsOutput) {
  const lines = tsOutput.split('\n');
  return lines.filter((line) =>
    /Cannot find type definition file|Cannot find namespace|Could not find a declaration file for module/.test(line),
  );
}

console.log('> Checking bundler import references with vite build...');
const buildResult = run('npm', ['run', 'build']);
if (buildResult.code === 0) {
  console.log('✓ Vite build passed (no broken runtime import references detected).');
} else {
  console.log('✗ Vite build failed. Output:');
  console.log(buildResult.output.trim());
}

console.log('\n> Checking TypeScript type references...');
const typeResult = run('npx', ['tsc', '--noEmit']);
const referenceErrors = collectReferenceErrors(typeResult.output);

if (referenceErrors.length === 0) {
  console.log('✓ No type reference errors detected by tsc.');
} else {
  console.log(`✗ Found ${referenceErrors.length} type reference issue(s):`);
  for (const line of referenceErrors) {
    console.log(`  - ${line}`);
  }
}

if (buildResult.code !== 0 || referenceErrors.length > 0) {
  process.exitCode = 1;
}
