import { invoke } from "@tauri-apps/api/core";
import { confirm } from "@tauri-apps/plugin-dialog";
import { fetch as httpFetch } from "@tauri-apps/plugin-http";
import { openUrl } from "@tauri-apps/plugin-opener";
import en from "../../lang/en.json";
import zh from "../../lang/zh.json";
import { getLanguage, getStoreValue, setStoreValue } from "../single/store";

const GITHUB_LATEST_RELEASE_URL =
  "https://api.github.com/repos/killertop/NekoPilot-Mac/releases/latest";
const LAST_UPDATE_CHECK_KEY = "github_release_update_last_check_ms";
const UPDATE_CHECK_INTERVAL_MS = 24 * 60 * 60 * 1000;
const STARTUP_CHECK_DELAY_MS = 5_000;

type GitHubRelease = {
  tag_name?: unknown;
  html_url?: unknown;
  draft?: unknown;
  prerelease?: unknown;
};

type ValidGitHubRelease = GitHubRelease & {
  tag_name: string;
  html_url: string;
};

let scheduled = false;

async function updateText(
  id: keyof typeof en,
  params?: Record<string, string>,
): Promise<string> {
  const translations = (await getLanguage()) === "zh" ? zh : en;
  let text = translations[id] ?? id;
  for (const [key, value] of Object.entries(params ?? {})) {
    text = text.replace(new RegExp(`{{\\s*${key}\\s*}}`, "g"), value);
  }
  return text;
}

function parseVersion(value: string): number[] | undefined {
  const match = value.trim().match(
    /^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:[-+].*)?$/i,
  );
  if (!match) return undefined;
  return [
    Number(match[1]),
    Number(match[2] ?? 0),
    Number(match[3] ?? 0),
  ];
}

/** Returns true only when the published stable version is newer than local. */
export function isVersionNewer(published: string, current: string): boolean {
  const remote = parseVersion(published);
  const local = parseVersion(current);
  if (!remote || !local) return false;

  for (let index = 0; index < remote.length; index += 1) {
    if (remote[index] !== local[index]) return remote[index] > local[index];
  }
  return false;
}

function checkDue(lastCheck: unknown, now: number): boolean {
  const last = typeof lastCheck === "number" ? lastCheck : Number(lastCheck);
  return !Number.isFinite(last) || now - last >= UPDATE_CHECK_INTERVAL_MS;
}

function validRelease(value: GitHubRelease): value is ValidGitHubRelease {
  return typeof value.tag_name === "string" &&
    typeof value.html_url === "string";
}

export async function checkForGitHubReleaseUpdate(): Promise<void> {
  const now = Date.now();
  const lastCheck = await getStoreValue(LAST_UPDATE_CHECK_KEY, 0);
  if (!checkDue(lastCheck, now)) return;

  // Count unsuccessful attempts too: an offline launch must not repeatedly
  // generate GitHub requests while the user is working without a network.
  await setStoreValue(LAST_UPDATE_CHECK_KEY, now);

  try {
    const response = await httpFetch(GITHUB_LATEST_RELEASE_URL, {
      headers: {
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2026-03-10",
      },
    });
    if (!response.ok) {
      console.info("GitHub update check skipped:", response.status);
      return;
    }

    const release = (await response.json()) as GitHubRelease;
    if (!validRelease(release) || release.draft || release.prerelease) return;

    const currentVersion = await invoke<string>("get_app_version");
    if (!isVersionNewer(release.tag_name, currentVersion)) return;

    const [title, message, okLabel, cancelLabel] = await Promise.all([
      updateText("github_update_title"),
      updateText("github_update_message", { version: release.tag_name }),
      updateText("github_update_download"),
      updateText("github_update_later"),
    ]);
    const download = await confirm(
      message,
      {
        title,
        kind: "info",
        okLabel,
        cancelLabel,
      },
    );
    if (download) await openUrl(release.html_url);
  } catch (error) {
    // Update discovery is opportunistic and must never disturb startup or
    // show an error dialog when GitHub is unavailable.
    console.info("GitHub update check failed:", error);
  }
}

/** Start once per renderer lifetime, after the main UI is already visible. */
export function scheduleGitHubReleaseUpdateCheck(): void {
  if (scheduled) return;
  scheduled = true;
  window.setTimeout(() => {
    void checkForGitHubReleaseUpdate();
  }, STARTUP_CHECK_DELAY_MS);
}
