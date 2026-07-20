/** Return a normalized external HTTP(S) URL, rejecting custom schemes. */
export function safeExternalHttpUrl(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  try {
    const url = new URL(value.trim());
    if ((url.protocol !== "http:" && url.protocol !== "https:") || !url.host) {
      return undefined;
    }
    return url.toString();
  } catch {
    return undefined;
  }
}

export function externalFaviconUrl(value: unknown): string | undefined {
  const website = safeExternalHttpUrl(value);
  return website ? new URL("/favicon.ico", website).toString() : undefined;
}
