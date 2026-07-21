#!/usr/bin/env -S deno run -A

import { createHash } from "node:crypto";
import {
  createReadStream,
  createWriteStream,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
} from "node:fs";
import path from "node:path";
import { pipeline } from "node:stream/promises";
import { fileURLToPath } from "node:url";
import { x as extractTar } from "tar";
import unzipper from "unzipper";
import { SING_BOX_VERSION } from "../src/types/definition.ts";
import {
  cleanupReplacementWorkspace,
  createReplacementWorkspace,
  replaceFileSafely,
  type ReplacementWorkspace,
} from "./safe-file-replacement.ts";

const BINARY_NAME = "sing-box";
const RELEASE_BASE_URL =
  "https://github.com/SagerNet/sing-box/releases/download";
const DOWNLOAD_TIMEOUT_MS = 180_000;
const forceDownload = Deno.env.get("FORCE_SIDECAR_DOWNLOAD") === "1";
const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(scriptDirectory, "..");

const SKIP_VERSION_LIST = new Set([
  "v1.12.5", // This sing-box version has known DNS issues.
]);

const TARGETS = [
  {
    platform: "darwin",
    arch: "arm64",
    triple: "aarch64-apple-darwin",
    extension: "",
  },
  {
    platform: "darwin",
    arch: "amd64",
    triple: "x86_64-apple-darwin",
    extension: "",
  },
  {
    platform: "linux",
    arch: "amd64",
    triple: "x86_64-unknown-linux-gnu",
    extension: "",
  },
  {
    platform: "linux",
    arch: "arm64",
    triple: "aarch64-unknown-linux-gnu",
    extension: "",
  },
  {
    platform: "windows",
    arch: "amd64",
    triple: "x86_64-pc-windows-msvc",
    extension: ".exe",
  },
] as const;

type Target = (typeof TARGETS)[number];

// Pin both GitHub's release-asset digest and the extracted executable bytes so
// a compromised CDN response cannot silently enter a NekoPilot package.
// Updating SING_BOX_VERSION must include a reviewed pair of hash sets.
const EXPECTED_ARCHIVE_SHA256: Record<string, Record<string, string>> = {
  "v1.13.14": {
    "darwin-arm64":
      "73e8967b0fc08e17bce4263ca56ebc394822401a16497a1c4e02316c888202ab",
    "darwin-amd64":
      "5245d645e847f90bb708da74bc020ae078c28489690756419685c04f56b4e3bb",
    "linux-amd64":
      "f48703461a15476951ac4967cdad339d986f4b8096b4eb3ff0829a500502d697",
    "linux-arm64":
      "4742df6a4314e8ecc41736849fca6d73b8f9e91b6e8b06ee794ff17ba180579e",
    "windows-amd64":
      "f580782c6dd10f7691c66cea1d7c421813c5fbf7e305d1ee7ce0c3a40d196341",
  },
};

const EXPECTED_BINARY_SHA256: Record<string, Record<string, string>> = {
  "v1.13.14": {
    "darwin-arm64":
      "813d8effd02a19572a8d75aef29fc073101404ca535b2496be86f21827c7684d",
    "darwin-amd64":
      "9e550c4cc3bdb8a6f3525bbaaf97624f517d1e37e0d5c76a439988483a5b27a6",
    "linux-amd64":
      "68aeab83cc4ab2659a5b92232261a20746ccdafc3b3d1e19b2d63247eec3bbf7",
    "linux-arm64":
      "85f570b96754cd7c354d28e50f66e9340b374e06b5d77ec9e15e8d04f0c87a25",
    "windows-amd64":
      "db0d779948214cf761011d154c3a5da36df20394fa01a9fc798f1dc39fe9d183",
  },
};

function sha256(filePath: string): string {
  return createHash("sha256").update(readFileSync(filePath)).digest("hex");
}

async function downloadFile(
  url: string,
  destination: string,
  maxAttempts = 3,
): Promise<void> {
  let lastError: Error | undefined;

  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), DOWNLOAD_TIMEOUT_MS);
    try {
      const response = await fetch(url, {
        signal: controller.signal,
        headers: { "User-Agent": "NekoPilot-binary-fetcher" },
        redirect: "follow",
      });
      if (!response.ok) {
        throw new Error(`HTTP ${response.status} while downloading ${url}`);
      }
      if (!response.body) throw new Error(`Empty response body from ${url}`);

      await pipeline(response.body, createWriteStream(destination));
      return;
    } catch (error) {
      lastError = error instanceof Error ? error : new Error(String(error));
      rmSync(destination, { force: true });
      if (attempt < maxAttempts) {
        const delay = attempt * 1_000;
        console.warn(
          `Download attempt ${attempt}/${maxAttempts} failed: ${lastError.message}; retrying in ${delay}ms`,
        );
        await new Promise((resolve) => setTimeout(resolve, delay));
      }
    } finally {
      clearTimeout(timeout);
    }
  }

  throw new Error(
    `Download failed after ${maxAttempts} attempts: ${
      lastError?.message ?? url
    }`,
  );
}

async function extractArchive(
  archivePath: string,
  format: "zip" | "tar.gz",
  destination: string,
): Promise<void> {
  if (format === "zip") {
    await createReadStream(archivePath)
      .pipe(unzipper.Extract({ path: destination }))
      .promise();
    return;
  }
  await extractTar({
    file: archivePath,
    cwd: destination,
    preservePaths: false,
  });
}

function verifyBinaryChecksum(filePath: string, target: Target): void {
  const key = `${target.platform}-${target.arch}`;
  const expected = EXPECTED_BINARY_SHA256[SING_BOX_VERSION]?.[key];
  if (!expected) {
    throw new Error(
      `No reviewed SHA-256 is pinned for sing-box ${SING_BOX_VERSION} (${key})`,
    );
  }

  const actual = sha256(filePath);
  if (actual !== expected) {
    throw new Error(
      `SHA-256 mismatch for ${key}: expected ${expected}, received ${actual}`,
    );
  }
  console.log(`Verified SHA-256 for ${key}: ${actual}`);
}

function verifyArchiveChecksum(filePath: string, target: Target): void {
  const key = `${target.platform}-${target.arch}`;
  const expected = EXPECTED_ARCHIVE_SHA256[SING_BOX_VERSION]?.[key];
  if (!expected) {
    throw new Error(
      `No reviewed archive SHA-256 is pinned for sing-box ${SING_BOX_VERSION} (${key})`,
    );
  }
  const actual = sha256(filePath);
  if (actual !== expected) {
    throw new Error(
      `Archive SHA-256 mismatch for ${key}: expected ${expected}, received ${actual}`,
    );
  }
  console.log(`Verified archive SHA-256 for ${key}: ${actual}`);
}

async function stageTarget(target: Target): Promise<void> {
  const startedAt = Date.now();
  const format = target.platform === "windows" ? "zip" : "tar.gz";
  const version = SING_BOX_VERSION.slice(1);
  const releaseName =
    `${BINARY_NAME}-${version}-${target.platform}-${target.arch}`;
  const archiveName = `${releaseName}.${format}`;
  const downloadUrl = `${RELEASE_BASE_URL}/${SING_BOX_VERSION}/${archiveName}`;
  const temporaryDirectory = path.join(
    scriptDirectory,
    "tmp",
    `${target.platform}-${target.arch}-${crypto.randomUUID()}`,
  );
  const archivePath = path.join(temporaryDirectory, archiveName);
  const extractedPath = path.join(
    temporaryDirectory,
    releaseName,
    `${BINARY_NAME}${target.extension}`,
  );
  const targetPath = path.join(
    repositoryRoot,
    "src-tauri",
    "binaries",
    `${BINARY_NAME}-${target.triple}${target.extension}`,
  );
  let replacementWorkspace: ReplacementWorkspace | undefined;

  if (!forceDownload && existsSync(targetPath)) {
    try {
      verifyBinaryChecksum(targetPath, target);
      console.log(
        `Using verified existing ${path.relative(repositoryRoot, targetPath)}`,
      );
      return;
    } catch (error) {
      console.warn(
        `Existing sidecar will be replaced: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
    }
  }

  mkdirSync(temporaryDirectory, { recursive: true });
  try {
    console.log(
      `Downloading ${BINARY_NAME} ${SING_BOX_VERSION} for ${target.platform}-${target.arch}`,
    );
    await downloadFile(downloadUrl, archivePath);
    verifyArchiveChecksum(archivePath, target);
    await extractArchive(archivePath, format, temporaryDirectory);
    if (!existsSync(extractedPath)) {
      throw new Error(`Expected executable is missing: ${extractedPath}`);
    }
    verifyBinaryChecksum(extractedPath, target);

    const targetDirectory = path.dirname(targetPath);
    mkdirSync(targetDirectory, { recursive: true });
    // mkdtemp creates the private transaction directory atomically, avoiding
    // staged/backup collisions even across concurrent downloader processes.
    // Keeping it inside the target directory also guarantees the final rename
    // stays on one filesystem.
    replacementWorkspace = createReplacementWorkspace(targetPath);
    const { stagedPath, backupPath } = replacementWorkspace;
    renameSync(extractedPath, stagedPath);
    verifyBinaryChecksum(stagedPath, target);
    replaceFileSafely({ stagedPath, targetPath, backupPath });
    const elapsed = ((Date.now() - startedAt) / 1_000).toFixed(2);
    console.log(
      `Staged ${path.relative(repositoryRoot, targetPath)} (${elapsed}s)`,
    );
  } finally {
    if (replacementWorkspace) {
      try {
        const recoveryArtifacts = cleanupReplacementWorkspace(
          replacementWorkspace,
        );
        if (recoveryArtifacts.length > 0) {
          console.warn(
            `[download-binaries] Preserved replacement recovery files: ${
              recoveryArtifacts.join(", ")
            }`,
          );
        }
      } catch (error) {
        console.warn(
          `[download-binaries] Could not remove empty replacement directory ${replacementWorkspace.directory}: ${
            error instanceof Error ? error.message : String(error)
          }`,
        );
      }
    }
    try {
      rmSync(temporaryDirectory, { recursive: true, force: true });
    } catch (error) {
      // Cleanup must not hide the original download/replacement result.
      console.warn(
        `[download-binaries] Could not remove temporary directory ${temporaryDirectory}: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
    }
  }
}

async function main(): Promise<void> {
  if (SKIP_VERSION_LIST.has(SING_BOX_VERSION)) {
    throw new Error(`sing-box ${SING_BOX_VERSION} is blocked by the skip list`);
  }
  if (
    !EXPECTED_ARCHIVE_SHA256[SING_BOX_VERSION] ||
    !EXPECTED_BINARY_SHA256[SING_BOX_VERSION]
  ) {
    throw new Error(
      `sing-box ${SING_BOX_VERSION} has no complete reviewed checksum set`,
    );
  }

  const requestedKeys = Deno.args
    .filter((argument) => argument.startsWith("--target="))
    .map((argument) => argument.slice("--target=".length));
  const availableKeys = new Set(
    TARGETS.map((target) => `${target.platform}-${target.arch}`),
  );
  for (const key of requestedKeys) {
    if (!availableKeys.has(key)) {
      throw new Error(
        `Unknown sidecar target "${key}"; expected one of ${
          [...availableKeys].join(", ")
        }`,
      );
    }
  }
  const selectedTargets = requestedKeys.length === 0
    ? TARGETS
    : TARGETS.filter((target) =>
      requestedKeys.includes(`${target.platform}-${target.arch}`)
    );

  const startedAt = Date.now();
  // GitHub/CDN connections are markedly less reliable when all five large
  // archives compete through the same corporate/VPS proxy. Sequential
  // downloads trade a few seconds of ideal-path speed for deterministic CI.
  for (const target of selectedTargets) await stageTarget(target);
  const elapsed = ((Date.now() - startedAt) / 1_000).toFixed(2);
  console.log(
    `${selectedTargets.length} sidecar target(s) downloaded and verified (${elapsed}s)`,
  );
}

try {
  await main();
} catch (error) {
  console.error(
    `[download-binaries] ${
      error instanceof Error ? error.message : String(error)
    }`,
  );
  Deno.exit(1);
}
