# AGENTS.md

## Project Overview

`requestman` is a browser extension that adds a DevTools panel for intercepting and modifying network requests in Chrome and Firefox.

The project uses:

- `React 18` for the DevTools UI
- `Vite 5` for bundling
- Animate UI and local shadcn/Radix UI components, styled with Tailwind CSS
- browser extension manifests for Chrome and Firefox

The current package version is defined in [package.json](package.json). Extension versions must stay aligned with:

- [public/manifest.json](public/manifest.json)
- [public/manifest.chrome.json](public/manifest.chrome.json)
- [public/manifest.firefox.json](public/manifest.firefox.json)

## Repository Structure

### Core source directories

- [src/components](src/components): shared UI primitives and icons
- [src/requestman](src/requestman): main DevTools panel UI, rule editors, shared types, constants, i18n, and rule utilities
- [src/background](src/background): extension background logic and rule application orchestration
- [src/devtools](src/devtools): DevTools entrypoint that registers the panel
- [public](public): static extension assets, browser manifests, injected scripts, and content bridge
- [scripts](scripts): build helper scripts for copying manifests/static assets, packaging Firefox, and checking references

### Important files

- [vite.config.js](vite.config.js): Vite config; builds from `src/` into `dist/chrome` or `dist/firefox` based on `BUILD_TARGET`
- [package.json](package.json): npm scripts and dependency definitions
- [.github/workflows/build.yml](.github/workflows/build.yml): CI build and GitHub release workflow triggered from `main`
- [README.md](README.md): product usage and developer setup

## Build Outputs

Generated artifacts go into [dist](dist):

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
- Static assets are copied from `public/` by [scripts/copy-static.mjs](scripts/copy-static.mjs).
- Browser-specific manifests are selected at build time and copied to `dist/<target>/manifest.json`.
- Some rule capabilities rely on `declarativeNetRequest`; others use injected scripts from [public/injected.js](public/injected.js) and [public/content-bridge.js](public/content-bridge.js).
- The DevTools panel UI lives under [src/requestman](src/requestman), with rule detail editors split into separate component files.

## Change Guidelines

- When changing extension behavior, check whether the change belongs in the DevTools UI, background logic, injected script layer, or manifest permissions.
- Reuse UI primitives from `src/components/animate-ui`, then `src/components/ui`, and icons from `src/components`. Business components may compose these primitives under `src/requestman` without additional approval; do not create competing primitives or custom icon implementations there.
- Keep shared primitives under `src/components` unchanged unless the task authorizes changes to them. If existing primitives can satisfy the request through composition, continue. If completing the task requires an unauthorized primitive change or new dependency, identify the specific missing capability and ask only for that scope expansion; continue independent authorized work.
- When a button needs icon hover animation, do not change the button's own visual style just to create the effect. Keep the existing button variant/shape, and animate the icon itself using the existing animated icon pattern already used in the repo, typically `AnimateIcon animateOnHover asChild` wrapped around a colored icon container.
- When adding a new rule type, expect updates across UI components, shared types/constants, and background application logic.
- Keep package version and manifest versions in sync for releases.

## Validation And Completion

- Source, CSS, dependency, manifest, or build-configuration changes require `npm run build:chrome`; also build Firefox when Firefox-specific behavior or packaging is affected. Release-related changes require `npm run build`.
- Documentation-only changes require checking links and `git diff --check`, not an extension build.
- Complete the requested implementation, update affected documentation, and fix failures introduced by the change. Repeat affected checks after fixes; broaden validation only for new failures or unresolved concerns.
- Distinguish build success from browser runtime verification, especially for request interception and extension permissions. Report any runtime checks that remain unverified.

## Release Process

Use this repository's actual branch names:

- development branch: `develop`
- release branch: `main`

Do not use `master` unless the branch layout changes in the future.

### Manual release checklist

1. Confirm the working tree is clean on `develop`.
2. Bump the version in:
   - [package.json](package.json)
   - [public/manifest.json](public/manifest.json)
   - [public/manifest.chrome.json](public/manifest.chrome.json)
   - [public/manifest.firefox.json](public/manifest.firefox.json)
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
- The workflow in [.github/workflows/build.yml](.github/workflows/build.yml) also creates a timestamped Git tag and GitHub Release when code is pushed to `main`.
- Manual semantic version tags such as `v0.2.1` can coexist with the CI-generated timestamp tags.
