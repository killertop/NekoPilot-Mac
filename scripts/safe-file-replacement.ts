import { existsSync, mkdtempSync, renameSync, rmSync } from "node:fs";
import path from "node:path";

export type ReplacementStrategy = "direct" | "atomic-overwrite" | "backup-swap";

export function replacementStrategy(
  platform: string,
  targetExists: boolean,
): ReplacementStrategy {
  if (!targetExists) return "direct";
  return platform === "win32" ? "backup-swap" : "atomic-overwrite";
}

export interface FileReplacementOperations {
  exists(path: string): boolean;
  rename(source: string, destination: string): void;
  remove(path: string): void;
}

const nodeOperations: FileReplacementOperations = {
  exists: existsSync,
  rename: renameSync,
  remove: (filePath) => rmSync(filePath, { force: true }),
};

export interface SafeReplacementOptions {
  stagedPath: string;
  targetPath: string;
  backupPath: string;
  platform?: string;
  operations?: FileReplacementOperations;
}

export interface ReplacementWorkspace {
  directory: string;
  stagedPath: string;
  backupPath: string;
}

/** Creates a collision-resistant private workspace on the target filesystem. */
export function createReplacementWorkspace(
  targetPath: string,
): ReplacementWorkspace {
  const directory = mkdtempSync(
    path.join(
      path.dirname(targetPath),
      `.${path.basename(targetPath)}.replace-`,
    ),
  );
  return {
    directory,
    stagedPath: path.join(directory, "staged"),
    backupPath: path.join(directory, "backup"),
  };
}

export interface ReplacementWorkspaceOperations {
  exists(path: string): boolean;
  removeDirectory(path: string): void;
}

const nodeWorkspaceOperations: ReplacementWorkspaceOperations = {
  exists: existsSync,
  removeDirectory: (directory) =>
    rmSync(directory, { recursive: true, force: true }),
};

/**
 * Removes an empty/successful transaction workspace, but never deletes staged
 * or backup bytes that remain useful after a failed replacement.
 */
export function cleanupReplacementWorkspace(
  workspace: ReplacementWorkspace,
  operations: ReplacementWorkspaceOperations = nodeWorkspaceOperations,
): string[] {
  const recoveryArtifacts = [workspace.stagedPath, workspace.backupPath].filter(
    (candidate) => operations.exists(candidate),
  );
  if (recoveryArtifacts.length === 0) {
    operations.removeDirectory(workspace.directory);
  }
  return recoveryArtifacts;
}

/**
 * Installs an already-verified file without deleting a working target first.
 *
 * POSIX rename-overwrite is atomic: a failed rename leaves the old target in
 * place when both paths are on the same filesystem. Windows executable
 * replacement is less dependable when the destination is open, so the old
 * target is first moved to a same-filesystem backup and restored if installing
 * the staged file fails. A failed rollback deliberately leaves that backup in
 * place and reports its exact path.
 */
export function replaceFileSafely(options: SafeReplacementOptions): void {
  const operations = options.operations ?? nodeOperations;
  const platform = options.platform ?? process.platform;
  if (
    new Set([options.stagedPath, options.targetPath, options.backupPath])
      .size !==
      3
  ) {
    throw new Error("staged, target, and backup paths must be distinct");
  }
  const strategy = replacementStrategy(
    platform,
    operations.exists(options.targetPath),
  );

  if (strategy !== "backup-swap") {
    operations.rename(options.stagedPath, options.targetPath);
    return;
  }

  // libuv may ask Windows to replace an existing rename destination. Never
  // risk overwriting a recovery artifact supplied by a caller with a colliding
  // backup path.
  if (operations.exists(options.backupPath)) {
    throw new Error(
      `Refusing replacement because the backup path already exists: ${options.backupPath}`,
    );
  }

  operations.rename(options.targetPath, options.backupPath);
  try {
    operations.rename(options.stagedPath, options.targetPath);
  } catch (installError) {
    try {
      operations.rename(options.backupPath, options.targetPath);
    } catch (rollbackError) {
      throw new AggregateError(
        [installError, rollbackError],
        `Failed to install replacement and restore the original; recovery copy remains at ${options.backupPath}`,
      );
    }
    throw installError;
  }

  try {
    operations.remove(options.backupPath);
  } catch (error) {
    // The new verified target is already installed. Retaining the old backup is
    // safer than turning a harmless cleanup failure into a destructive retry.
    console.warn(
      `[safe-file-replacement] replacement succeeded but backup cleanup failed at ${options.backupPath}: ${
        error instanceof Error ? error.message : String(error)
      }`,
    );
  }
}
