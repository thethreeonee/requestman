# AGENTS.md

## Project Overview

`requestman` is a browser extension that adds a DevTools panel for intercepting and modifying network requests in Chrome and Firefox.

The project uses:

- `React 18` for the DevTools UI
- `Vite 5` for bundling
- `Ant Design` for UI components
- browser extension manifests for Chrome and Firefox

The current package version is defined in [package.json](/Users/0xE31/Projects/requestman/package.json). Extension versions must stay aligned with:

- [public/manifest.json](/Users/0xE31/Projects/requestman/public/manifest.json)
- [public/manifest.chrome.json](/Users/0xE31/Projects/requestman/public/manifest.chrome.json)
- [public/manifest.firefox.json](/Users/0xE31/Projects/requestman/public/manifest.firefox.json)

## Repository Structure

### Core source directories

- [src/components](/Users/0xE31/Projects/requestman/src/components): shared UI components and icons; all UI implementations must reuse components and icons from this directory
- [src/requestman](/Users/0xE31/Projects/requestman/src/requestman): main DevTools panel UI, rule editors, shared types, constants, i18n, and rule utilities
- [src/background](/Users/0xE31/Projects/requestman/src/background): extension background logic and rule application orchestration
- [src/devtools](/Users/0xE31/Projects/requestman/src/devtools): DevTools entrypoint that registers the panel
- [public](/Users/0xE31/Projects/requestman/public): static extension assets, browser manifests, injected scripts, and content bridge
- [scripts](/Users/0xE31/Projects/requestman/scripts): build helper scripts for copying manifests/static assets, packaging Firefox, and checking references

### Important files

- [vite.config.js](/Users/0xE31/Projects/requestman/vite.config.js): Vite config; builds from `src/` into `dist/chrome` or `dist/firefox` based on `BUILD_TARGET`
- [package.json](/Users/0xE31/Projects/requestman/package.json): npm scripts and dependency definitions
- [.github/workflows/build.yml](/Users/0xE31/Projects/requestman/.github/workflows/build.yml): CI build and GitHub release workflow triggered from `main`
- [README.md](/Users/0xE31/Projects/requestman/README.md): product usage and developer setup

## Build Outputs

Generated artifacts go into [dist](/Users/0xE31/Projects/requestman/dist):

- `dist/chrome`: unpacked Chrome extension
- `dist/firefox`: unpacked Firefox extension
- `dist/requestman-firefox.xpi`: packaged Firefox add-on

Release packaging may also create versioned zip files such as:

- `dist/requestman-chrome-<version>.zip`
- `dist/requestman-firefox-<version>.zip`

`dist/` is build output and should be treated as generated content.

## Build And Dev Commands

- `npm install`: install dependencies
- `npm run dev`: watch build
- `npm run clean`: remove `dist`
- `npm run build:chrome`: build Chrome extension into `dist/chrome`
- `npm run build:firefox`: build Firefox extension into `dist/firefox`
- `npm run build:firefox:xpi`: rebuild Firefox and package `dist/requestman-firefox.xpi`
- `npm run build`: full build for both browsers plus Firefox XPI
- `npm run check:references`: run internal reference checks

## Architecture Notes

- The Vite root is `src/`, not the repository root.
- Static assets are copied from `public/` by [scripts/copy-static.mjs](/Users/0xE31/Projects/requestman/scripts/copy-static.mjs).
- Browser-specific manifests are selected at build time and copied to `dist/<target>/manifest.json`.
- Some rule capabilities rely on `declarativeNetRequest`; others use injected scripts from [public/injected.js](/Users/0xE31/Projects/requestman/public/injected.js) and [public/content-bridge.js](/Users/0xE31/Projects/requestman/public/content-bridge.js).
- The DevTools panel UI lives under [src/requestman](/Users/0xE31/Projects/requestman/src/requestman), with rule detail editors split into separate component files.

## Change Guidelines

- When changing extension behavior, check whether the change belongs in the DevTools UI, background logic, injected script layer, or manifest permissions.
- All UI implementations must use components from [src/components](/Users/0xE31/Projects/requestman/src/components); do not build ad hoc replacement components outside that directory.
- All icons must also come from [src/components](/Users/0xE31/Projects/requestman/src/components); do not introduce custom icon implementations elsewhere.
- Do not modify any files under [src/components](/Users/0xE31/Projects/requestman/src/components). If a change would require editing that directory, stop and tell the user it is blocked by repository rules.
- If a required UI component or icon does not exist in [src/components](/Users/0xE31/Projects/requestman/src/components), stop and tell the user which dependency is missing so they can add it first.
- When adding a new rule type, expect updates across UI components, shared types/constants, and background application logic.
- Keep package version and manifest versions in sync for releases.
- Validate with `npm run build` before finalizing release-related changes.

## Release Process

Use this repository's actual branch names:

- development branch: `develop`
- release branch: `main`

Do not use `master` unless the branch layout changes in the future.

### Manual release checklist

1. Confirm the working tree is clean on `develop`.
2. Bump the version in:
   - [package.json](/Users/0xE31/Projects/requestman/package.json)
   - [public/manifest.json](/Users/0xE31/Projects/requestman/public/manifest.json)
   - [public/manifest.chrome.json](/Users/0xE31/Projects/requestman/public/manifest.chrome.json)
   - [public/manifest.firefox.json](/Users/0xE31/Projects/requestman/public/manifest.firefox.json)
3. Run `npm run build`.
4. Package release artifacts from `dist`:
   - `zip -r /absolute/path/to/dist/requestman-chrome-<version>.zip .` from inside `dist/chrome`
   - `zip -r /absolute/path/to/dist/requestman-firefox-<version>.zip .` from inside `dist/firefox`
   - Firefox XPI is already produced as `dist/requestman-firefox.xpi`
5. Commit the version bump on `develop`.
6. Run `git fetch origin`.
7. Merge `origin/develop` into local `develop` and resolve conflicts if needed.
8. Re-run `npm run build` and regenerate release zip files if the merge changed code.
9. Switch to `main`.
10. Merge `develop` into `main`, preferably with `--no-ff`.
11. Create a tag on `main` using the version, for example `git tag v0.2.1`.
12. Switch back to `develop`.
13. Push both branches and the version tag:
    - `git push origin develop main v<version>`

### Notes for this repo

- `main` is the branch watched by GitHub Actions release automation.
- The workflow in [.github/workflows/build.yml](/Users/0xE31/Projects/requestman/.github/workflows/build.yml) also creates a timestamped Git tag and GitHub Release when code is pushed to `main`.
- Manual semantic version tags such as `v0.2.1` can coexist with the CI-generated timestamp tags.
