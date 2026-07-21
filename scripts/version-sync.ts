#!/usr/bin/env -S deno run -A

import { readFileSync, renameSync, statSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const paths = {
  packageJson: resolve(root, "package.json"),
  tauriConfig: resolve(root, "src-tauri/tauri.conf.json"),
  cargoToml: resolve(root, "src-tauri/Cargo.toml"),
  cargoLock: resolve(root, "src-tauri/Cargo.lock"),
  nativeVersion: resolve(root, "native/VERSION"),
};

const SEMVER = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;

function readJsonVersion(path: string, label: string): string {
  const value = JSON.parse(readFileSync(path, "utf8")).version;
  if (typeof value !== "string" || !SEMVER.test(value)) {
    throw new Error(`${label} has an invalid version: ${String(value)}`);
  }
  return value;
}

function readTextVersion(path: string, label: string): string {
  const value = readFileSync(path, "utf8").trim();
  if (!SEMVER.test(value)) {
    throw new Error(`${label} has an invalid version: ${value}`);
  }
  return value;
}

function packageSection(source: string): string {
  const start = source.search(/^\[package\]\s*$/m);
  if (start < 0) throw new Error("Cargo.toml is missing [package]");
  const nextSection = source.slice(start + 1).search(/^\[/m);
  return nextSection < 0
    ? source.slice(start)
    : source.slice(start, start + 1 + nextSection);
}

function readCargoTomlVersion(source: string): string {
  const match = packageSection(source).match(/^version\s*=\s*"([^"]+)"\s*$/m);
  if (!match || !SEMVER.test(match[1])) {
    throw new Error(
      `Cargo.toml has an invalid package version: ${match?.[1] ?? "missing"}`,
    );
  }
  return match[1];
}

function lockPackageBlock(source: string): string {
  const block = source
    .split(/(?=^\[\[package\]\]\s*$)/m)
    .find((candidate) => /^name\s*=\s*"nekopilot"\s*$/m.test(candidate));
  if (!block) throw new Error("Cargo.lock is missing the nekopilot package");
  return block;
}

function readCargoLockVersion(source: string): string {
  const match = lockPackageBlock(source).match(/^version\s*=\s*"([^"]+)"\s*$/m);
  if (!match || !SEMVER.test(match[1])) {
    throw new Error(
      `Cargo.lock has an invalid nekopilot version: ${match?.[1] ?? "missing"}`,
    );
  }
  return match[1];
}

function readVersions() {
  const cargoToml = readFileSync(paths.cargoToml, "utf8");
  const cargoLock = readFileSync(paths.cargoLock, "utf8");
  return {
    packageJson: readJsonVersion(paths.packageJson, "package.json"),
    tauriConfig: readJsonVersion(paths.tauriConfig, "tauri.conf.json"),
    cargoToml: readCargoTomlVersion(cargoToml),
    cargoLock: readCargoLockVersion(cargoLock),
    nativeVersion: readTextVersion(paths.nativeVersion, "native/VERSION"),
    cargoTomlSource: cargoToml,
    cargoLockSource: cargoLock,
  };
}

function requireSynchronized(
  versions: ReturnType<typeof readVersions>,
): string {
  const entries = Object.entries(versions).filter(([key]) =>
    !key.endsWith("Source")
  );
  const unique = new Set(entries.map(([, value]) => value));
  if (unique.size !== 1) {
    throw new Error(
      "application versions are out of sync:\n" +
        entries.map(([name, value]) => `  ${name}: ${value}`).join("\n"),
    );
  }
  return entries[0][1];
}

function replaceSingle(
  source: string,
  pattern: RegExp,
  replacement: string,
  label: string,
): string {
  const matches = source.match(
    new RegExp(
      pattern.source,
      pattern.flags.includes("g") ? pattern.flags : pattern.flags + "g",
    ),
  );
  if (matches?.length !== 1) {
    throw new Error(
      `${label}: expected exactly one version field, found ${
        matches?.length ?? 0
      }`,
    );
  }
  return source.replace(pattern, replacement);
}

function updateCargoToml(
  source: string,
  current: string,
  next: string,
): string {
  const section = packageSection(source);
  const updated = replaceSingle(
    section,
    new RegExp(
      `^version\\s*=\\s*"${current.replaceAll(".", "\\.")}"\\s*$`,
      "m",
    ),
    `version = "${next}"`,
    "Cargo.toml [package]",
  );
  return source.replace(section, updated);
}

function updateCargoLock(
  source: string,
  current: string,
  next: string,
): string {
  const block = lockPackageBlock(source);
  const updated = replaceSingle(
    block,
    new RegExp(
      `^version\\s*=\\s*"${current.replaceAll(".", "\\.")}"\\s*$`,
      "m",
    ),
    `version = "${next}"`,
    "Cargo.lock nekopilot package",
  );
  return source.replace(block, updated);
}

function updateJson(path: string, next: string): string {
  const value = JSON.parse(readFileSync(path, "utf8"));
  value.version = next;
  return JSON.stringify(value, null, 2) + "\n";
}

function writeAtomically(path: string, content: string): void {
  const temporary = `${path}.version-sync-${process.pid}`;
  writeFileSync(temporary, content, {
    encoding: "utf8",
    mode: statSync(path).mode,
  });
  renameSync(temporary, path);
}

function main(): void {
  const mode = process.argv[2] ?? "--check";
  if (mode !== "--check" && mode !== "--bump-patch") {
    throw new Error("usage: version-sync.ts [--check|--bump-patch]");
  }

  const versions = readVersions();
  const current = requireSynchronized(versions);
  if (mode === "--check") {
    console.log(`[version-sync] OK: ${current}`);
    return;
  }

  const match = SEMVER.exec(current)!;
  const next = `${match[1]}.${match[2]}.${Number(match[3]) + 1}`;
  const outputs = new Map([
    [paths.packageJson, updateJson(paths.packageJson, next)],
    [paths.tauriConfig, updateJson(paths.tauriConfig, next)],
    [paths.cargoToml, updateCargoToml(versions.cargoTomlSource, current, next)],
    [paths.cargoLock, updateCargoLock(versions.cargoLockSource, current, next)],
    [paths.nativeVersion, `${next}\n`],
  ]);

  for (const [path, content] of outputs) writeAtomically(path, content);
  console.log(`[version-sync] ${current} -> ${next}`);
  console.log(
    "Update CHANGELOG.MD, run the release preflight, then commit all synchronized version files together.",
  );
}

try {
  main();
} catch (error) {
  console.error(
    `[version-sync] ${error instanceof Error ? error.message : String(error)}`,
  );
  Deno.exit(1);
}
