import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

// 获取 Tauri 版本号
function getAppVersion(): string {
  const tauriConfPath = join(process.cwd(), "src-tauri/tauri.conf.json");
  const content = readFileSync(tauriConfPath, "utf-8");
  const config = JSON.parse(content);

  if (!config.version) {
    throw new Error("Could not find version in tauri.conf.json");
  }

  return config.version;
}

// 获取当前日期 (YYYY-MM-DD 格式)
function getCurrentDate(): string {
  const now = new Date();
  const year = now.getUTCFullYear();
  const month = String(now.getUTCMonth() + 1).padStart(2, "0");
  const day = String(now.getUTCDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

// 处理 CHANGELOG
function processChangelog(): void {
  const changelogPath = join(process.cwd(), "CHANGELOG.MD");
  let content = readFileSync(changelogPath, "utf-8");

  const version = getAppVersion();
  const date = getCurrentDate();
  const replacement = `Version ${version} (${date} UTC)`;

  const placeholder = /\{\{version-tag-date\}\}/g;
  if (placeholder.test(content)) {
    content = content.replace(placeholder, replacement);
  } else {
    const escapedVersion = version.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const releasedVersionHeading = new RegExp(
      `^##\\s+${escapedVersion}\\s+-\\s+\\d{4}-\\d{2}-\\d{2}\\s*$`,
      "m",
    );
    if (!releasedVersionHeading.test(content)) {
      throw new Error(
        `CHANGELOG.MD has neither {{version-tag-date}} nor a release heading for ${version}`,
      );
    }
  }

  writeFileSync(changelogPath, content, "utf-8");

  console.log(`✓ CHANGELOG processed`);
  console.log(`  Version: ${version}`);
  console.log(`  Date: ${date}`);
  console.log(`  Replacement: ${replacement}`);
}

processChangelog();
