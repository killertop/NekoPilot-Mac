import { invoke } from "@tauri-apps/api/core";
import { getStoreValue, setStoreValue } from "../../single/store";

import { configType, getConfigTemplateCacheKey } from "../common";
import { getBuiltInTemplate } from "../templates";

// Cache is the single intermediary. Reads are non-blocking and may return
// stale content — the periodic prime (see hooks/useSwr.ts) refreshes the
// cache in the background. If the cache is empty (first launch, offline),
// fall back to the build-time template snapshot (see src/config/templates)
// and seed the cache so subsequent reads stay fast. No network I/O here.
async function getConfigTemplate(mode: configType): Promise<any> {
  const cacheKey = await getConfigTemplateCacheKey(mode);
  let config = await getStoreValue(cacheKey, "");
  if (!config) {
    config = getBuiltInTemplate(mode);
    await setStoreValue(cacheKey, config);
    console.info(
      `[template] cache empty for mode=${mode}, seeded built-in snapshot`,
    );
  }
  return JSON.parse(config);
}

async function buildAndWriteConfig(
  newConfig: any,
  selectedIdentifier: string,
  mode: configType,
  reloadIfRunning = false,
) {
  await invoke("prepare_write_and_reload_config", {
    fileName: "config.json",
    templateConfig: newConfig,
    selectedIdentifier,
    mode,
    reloadIfRunning,
  });
}

export async function setMixedConfig(identifier: string, reloadIfRunning = false) {
  // 一定要优先深拷贝配置文件，否则会修改原始配置文件对象，导致后续使用时出错。
  const newConfig = await getConfigTemplate("mixed");

  console.log("写入[规则]系统代理配置文件");
  await buildAndWriteConfig(
    newConfig,
    identifier,
    "mixed",
    reloadIfRunning,
  );
}
