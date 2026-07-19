#!/usr/bin/env -S deno run -A
/**
 * Validate the committed NekoPilot config-template snapshot.
 *
 * The repository intentionally keeps the generated template module in git.
 * This task retains the historical sync-templates name for build-task
 * compatibility, but it performs no network access and never imports a
 * separate upstream repository.
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REPO = "killertop/NekoPilot-Mac";
const OUTPUT_PATH = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "../src/config/templates/generated.ts",
);

const REQUIRED_MARKERS = [
  "BUILT_IN_TEMPLATE_OBJECTS",
  "BUILD_TIME_TEMPLATE_SOURCE",
  "singBoxVersion: 'v",
  "repo: '" + REPO + "'",
];

function main(): void {
  if (!existsSync(OUTPUT_PATH)) {
    throw new Error("missing committed template snapshot: " + OUTPUT_PATH);
  }

  const content = readFileSync(OUTPUT_PATH, "utf8");
  const missing = REQUIRED_MARKERS.filter((marker) => !content.includes(marker));
  if (missing.length > 0) {
    throw new Error(
      "template snapshot is missing required markers: " + missing.join(", "),
    );
  }

  console.log("[sync-templates] validated local snapshot at " + OUTPUT_PATH);
}

try {
  main();
} catch (error) {
  console.error(
    "[sync-templates] failed: " +
      (error instanceof Error ? error.message : String(error)),
  );
  Deno.exit(1);
}
