import {
  ALL_CONFIG_MODES,
  configType,
  getConfigTemplateCacheKey,
  TEMPLATE_CACHE_SCHEMA_VERSION,
} from "../config/common";
import { getBuiltInTemplate } from "../config/templates";
import { setStoreValue } from "../single/store";
import { invoke } from "@tauri-apps/api/core";

// Purge all old template-path overrides now that templates are bundled and no
// longer user-editable. Enumerating the store catches every historical naming
// scheme while retaining the current-schema content cache.
export async function purgeLegacyTemplateCache(): Promise<void> {
  const currentCacheKeys = new Set(
    await Promise.all(
      ALL_CONFIG_MODES.map((m) => getConfigTemplateCacheKey(m)),
    ),
  );
  const schemaSuffix = `-v${TEMPLATE_CACHE_SCHEMA_VERSION}`;

  let allKeys: string[];
  try {
    allKeys = await invoke<string[]>("list_setting_keys");
  } catch (e) {
    console.warn("[migrate] native settings key list failed:", e);
    return;
  }

  const deletions: Promise<unknown>[] = [];
  for (const key of allKeys) {
    // 1. Any template-config-cache entry that isn't the current-schema key.
    //    Catches pre-v2 (`...-template-config-cache`), old-major (1.12),
    //    and orphan naming (`...-rules-template-config-cache`).
    if (key.includes("-template-config-cache") && !currentCacheKeys.has(key)) {
      deletions.push(
        invoke("delete_setting", { key })
          .then(() =>
            console.info(`[migrate] purged legacy template cache: ${key}`)
          )
          .catch((e) => console.warn(`[migrate] failed to purge ${key}:`, e)),
      );
      continue;
    }

    // 2. Any former template-path override. The advanced template editor has
    //    been removed, so a locally dropped or remote override must not keep
    //    influencing generated configs. Drop its matching cache as well.
    if (key.endsWith("-template-path") && !key.endsWith(schemaSuffix)) {
      deletions.push((async () => {
        try {
          await invoke("delete_setting", { key });
          console.info(`[migrate] dropped obsolete template-path override: ${key}`);
          const mode = inferModeFromPathKey(key);
          if (mode) {
            const contentKey = await getConfigTemplateCacheKey(mode);
            await invoke("delete_setting", { key: contentKey });
            console.info(
              `[migrate] dropped content cache from obsolete override: ${contentKey}`,
            );
          }
        } catch (e) {
          console.warn(`[migrate] failed to purge template-path ${key}:`, e);
        }
      })());
    }
  }

  await Promise.all(deletions);

}

// Extracts the mode segment from a `key-sing-box-{major}-{mode}-template-path`
// key. Returns null if the mode is not one of the known configType values
// (e.g. orphan shapes from earlier versions with different mode naming).
function inferModeFromPathKey(key: string): configType | null {
  const m = key.match(/-(mixed|mixed-global)-template-path$/);
  if (!m) return null;
  return m[1] as configType;
}

export async function primeConfigTemplateCache(
  mode: configType,
): Promise<void> {
  const cacheKey = await getConfigTemplateCacheKey(mode);
  await setStoreValue(cacheKey, getBuiltInTemplate(mode));
}

export async function primeAllConfigTemplateCaches(): Promise<"ok"> {
  await Promise.all(ALL_CONFIG_MODES.map(primeConfigTemplateCache));
  return "ok";
}
