import { SING_BOX_MAJOR_VERSION } from "../types/definition";

export type configType = "mixed";

// Bump when a sing-box upgrade makes prior cached templates unusable (e.g. 1.13.8
// rejecting legacy `sniff` inbound fields). New clients read a versioned key;
// purgeLegacyTemplateCache physically deletes the old entries.
export const TEMPLATE_CACHE_SCHEMA_VERSION = 2;

export const ALL_CONFIG_MODES: configType[] = ["mixed"];

export async function getConfigTemplateCacheKey(
  mode: configType,
): Promise<string> {
  const cacheKey =
    `key-sing-box-${SING_BOX_MAJOR_VERSION}-${mode}-template-config-cache-v${TEMPLATE_CACHE_SCHEMA_VERSION}`;
  return cacheKey;
}
