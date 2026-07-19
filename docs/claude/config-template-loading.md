# Config Template Loading Flow

> **Claude-facing, not human-facing.** Read before editing `scripts/sync-templates.ts`, `src/config/templates/*`, `src/config/merger/*`, `src/hooks/useSwr.ts`, or `src/single/store.ts`, and when changing the sing-box version or template-cache schema. Paths are repo-relative. If this note disagrees with the code, trust the code and update this note.

## Rules

- Treat `src/config/templates/generated.ts` as the single committed config-template snapshot for this repository.
- Keep `scripts/sync-templates.ts` offline and validation-only. It retains its name for build-task compatibility; it must not fetch a separate repository or delete the snapshot.
- Keep the read path non-blocking. `getConfigTemplate` reads the cache and falls back to `getBuiltInTemplate`; it must not add network I/O.
- Keep the cache boundary as a JSON string. Native store readers and writers already depend on that shape.
- Treat external libraries and public rule-set URLs as third-party dependencies. Do not relabel them as NekoPilot-owned code without a separate fork or vendoring decision.

## Build-time path

The generated module is versioned in this repository and is checked by `deno task sync-templates`. The task validates the file, its required exports, its sing-box version metadata, and its repository metadata. It does not modify the file or require network access.

The Tauri build chain may still invoke the task through the existing Deno build tasks. CI must validate the committed snapshot in place; it must not remove `generated.ts` and regenerate it from an external source.

The generated module contains real TypeScript object literals and exports:

- `MIXED_TEMPLATE` and the other mode-specific template objects.
- `BUILT_IN_TEMPLATE_OBJECTS`, keyed by `configType`.
- `BUILD_TIME_TEMPLATE_SOURCE`, identifying the local repository snapshot.

Do not convert the objects back into JSON strings embedded in TypeScript. Stringification belongs at the cache-write boundary in `getBuiltInTemplate`.

## Runtime read path

`src/config/merger/main.ts::getConfigTemplate(mode)`:

1. Reads the current-schema key from the `tauri-plugin-store` cache.
2. Returns the cached JSON string when present.
3. On a cache miss, calls `src/config/templates/index.ts::getBuiltInTemplate`.
4. Seeds the cache with the local snapshot and returns the same JSON-string form.

The merger read path must remain independent of network availability.

## Runtime write path

`src/hooks/useSwr.ts::primeAllConfigTemplateCaches` may refresh the cache in the background according to the app's existing runtime policy. If its external fetch path is changed, preserve HTTPS validation, parsing, error fallback, cache-schema handling, and the local built-in fallback. Do not make a merge wait for that background work.

`purgeLegacyTemplateCache` runs at mount and removes stale cache keys and stale URL overrides. Keep the purge broad enough to remove historical cache shapes when the schema changes.

## What we deliberately DON'T do

- **Do not reintroduce `raw.githubusercontent.com` or another build-time fetch.** A release must be reproducible from the commit in this repository.
- **Do not delete `generated.ts` in CI.** Removing the local snapshot makes a release depend on network state and an unpinned external branch.
- **Do not hand-edit individual template values casually.** Update the committed snapshot through a reviewed change, then run the template validation and build checks.
- **Do not add network I/O to `getConfigTemplate` or the config mergers.** TUN and routing changes must not block on a remote service.
- **Do not change the cache value from a JSON string to an object.** That breaks the existing native-store boundary and merger parsing.
- **Do not mass-rename internal `onebox_*` identifiers, helper names, or protocol labels merely to remove repository references.** They are compatibility-sensitive implementation names, not active upstream remotes.
- **Do not remove `LICENSE` or `NOTICE`.** They record the legal source and attribution obligations that remain with this codebase.

## Files

- `scripts/sync-templates.ts` — offline validation of the committed snapshot.
- `src/config/templates/generated.ts` — versioned template objects and local snapshot metadata.
- `src/config/templates/index.ts` — built-in fallback dispatcher and JSON stringification boundary.
- `src/config/common.ts` — cache schema and key construction.
- `src/config/merger/main.ts` — cache read path and config mergers.
- `src/hooks/useSwr.ts` — background refresh and legacy-cache purge.
- `src/single/store.ts` — runtime template URL resolution.
- `.github/workflows/release.yml` — release-time snapshot validation.
- `docs/DEVELOPMENT.md` — local development and validation instructions.
