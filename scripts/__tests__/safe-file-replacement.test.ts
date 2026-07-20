import { describe, expect, it, vi } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  cleanupReplacementWorkspace,
  createReplacementWorkspace,
  type FileReplacementOperations,
  replaceFileSafely,
  replacementStrategy,
} from "../safe-file-replacement.ts";

function memoryOperations(
  initial: Record<string, string>,
  failRename?: (source: string, destination: string) => boolean,
  failRemove?: (filePath: string) => boolean,
) {
  const files = new Map(Object.entries(initial));
  const operations: FileReplacementOperations = {
    exists: (filePath) => files.has(filePath),
    rename: (source, destination) => {
      if (failRename?.(source, destination)) {
        throw new Error(`injected rename failure: ${source} -> ${destination}`);
      }
      const value = files.get(source);
      if (value === undefined) throw new Error(`missing source: ${source}`);
      files.delete(source);
      files.set(destination, value);
    },
    remove: (filePath) => {
      if (failRemove?.(filePath)) {
        throw new Error(`injected remove failure: ${filePath}`);
      }
      files.delete(filePath);
    },
  };
  return { files, operations };
}

describe("replacementStrategy", () => {
  it("uses atomic overwrite on POSIX and a backup swap on Windows", () => {
    expect(replacementStrategy("darwin", true)).toBe("atomic-overwrite");
    expect(replacementStrategy("linux", true)).toBe("atomic-overwrite");
    expect(replacementStrategy("win32", true)).toBe("backup-swap");
    expect(replacementStrategy("win32", false)).toBe("direct");
  });
});

describe("replacement workspace", () => {
  it("creates distinct private workspaces beside the target", () => {
    const root = mkdtempSync(
      path.join(tmpdir(), "nekopilot-replacement-test-"),
    );
    try {
      const targetPath = path.join(root, "sing-box");
      const first = createReplacementWorkspace(targetPath);
      const second = createReplacementWorkspace(targetPath);
      expect(first.directory).not.toBe(second.directory);
      expect(path.dirname(first.directory)).toBe(root);
      expect(path.dirname(second.directory)).toBe(root);
      expect(first.stagedPath).not.toBe(first.backupPath);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("preserves a workspace that still contains recovery files", () => {
    const removed: string[] = [];
    const recovery = cleanupReplacementWorkspace(
      {
        directory: "workspace",
        stagedPath: "workspace/staged",
        backupPath: "workspace/backup",
      },
      {
        exists: () => true,
        removeDirectory: (candidate) => removed.push(candidate),
      },
    );
    expect(recovery).toEqual(["workspace/staged", "workspace/backup"]);
    expect(removed).toEqual([]);
  });

  it("removes a workspace only when no recovery files remain", () => {
    const removed: string[] = [];
    const recovery = cleanupReplacementWorkspace(
      {
        directory: "workspace",
        stagedPath: "workspace/staged",
        backupPath: "workspace/backup",
      },
      {
        exists: () => false,
        removeDirectory: (candidate) => removed.push(candidate),
      },
    );
    expect(recovery).toEqual([]);
    expect(removed).toEqual(["workspace"]);
  });
});

describe("replaceFileSafely", () => {
  it("installs directly when no target exists", () => {
    const { files, operations } = memoryOperations({ staged: "new" });

    replaceFileSafely({
      stagedPath: "staged",
      targetPath: "target",
      backupPath: "backup",
      platform: "win32",
      operations,
    });
    expect(Object.fromEntries(files)).toEqual({ target: "new" });
  });

  it("leaves the staged file recoverable when a direct install fails", () => {
    const { files, operations } = memoryOperations(
      { staged: "new" },
      (source, destination) => source === "staged" && destination === "target",
    );

    expect(() =>
      replaceFileSafely({
        stagedPath: "staged",
        targetPath: "target",
        backupPath: "backup",
        platform: "win32",
        operations,
      })
    ).toThrow("injected rename failure");
    expect(Object.fromEntries(files)).toEqual({ staged: "new" });
  });

  it("keeps the old POSIX target when atomic rename fails", () => {
    const { files, operations } = memoryOperations(
      { staged: "new", target: "old" },
      (source, destination) => source === "staged" && destination === "target",
    );

    expect(() =>
      replaceFileSafely({
        stagedPath: "staged",
        targetPath: "target",
        backupPath: "backup",
        platform: "darwin",
        operations,
      })
    ).toThrow("injected rename failure");
    expect(Object.fromEntries(files)).toEqual({ staged: "new", target: "old" });
  });

  it("installs a Windows replacement and removes its recovery backup", () => {
    const { files, operations } = memoryOperations({
      staged: "new",
      target: "old",
    });

    replaceFileSafely({
      stagedPath: "staged",
      targetPath: "target",
      backupPath: "backup",
      platform: "win32",
      operations,
    });
    expect(Object.fromEntries(files)).toEqual({ target: "new" });
  });

  it("refuses to overwrite a colliding Windows backup path", () => {
    const { files, operations } = memoryOperations({
      staged: "new",
      target: "old",
      backup: "prior recovery",
    });

    expect(() =>
      replaceFileSafely({
        stagedPath: "staged",
        targetPath: "target",
        backupPath: "backup",
        platform: "win32",
        operations,
      })
    ).toThrow("backup path already exists");
    expect(Object.fromEntries(files)).toEqual({
      staged: "new",
      target: "old",
      backup: "prior recovery",
    });
  });

  it("retains a Windows backup when cleanup fails after installation", () => {
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});
    const { files, operations } = memoryOperations(
      { staged: "new", target: "old" },
      undefined,
      (filePath) => filePath === "backup",
    );

    replaceFileSafely({
      stagedPath: "staged",
      targetPath: "target",
      backupPath: "backup",
      platform: "win32",
      operations,
    });
    expect(Object.fromEntries(files)).toEqual({ backup: "old", target: "new" });
    expect(warning).toHaveBeenCalledWith(
      expect.stringContaining("backup cleanup failed at backup"),
    );
    warning.mockRestore();
  });

  it("restores the old Windows target when installing the staged file fails", () => {
    const { files, operations } = memoryOperations(
      { staged: "new", target: "old" },
      (source, destination) => source === "staged" && destination === "target",
    );

    expect(() =>
      replaceFileSafely({
        stagedPath: "staged",
        targetPath: "target",
        backupPath: "backup",
        platform: "win32",
        operations,
      })
    ).toThrow("injected rename failure");
    expect(Object.fromEntries(files)).toEqual({ staged: "new", target: "old" });
  });

  it("preserves the recovery backup when a Windows rollback also fails", () => {
    const { files, operations } = memoryOperations(
      { staged: "new", target: "old" },
      (source, destination) =>
        destination === "target" &&
        (source === "staged" || source === "backup"),
    );

    expect(() =>
      replaceFileSafely({
        stagedPath: "staged",
        targetPath: "target",
        backupPath: "backup",
        platform: "win32",
        operations,
      })
    ).toThrow("recovery copy remains at backup");
    expect(Object.fromEntries(files)).toEqual({ staged: "new", backup: "old" });
  });
});
