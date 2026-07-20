import { clashApiFetch } from "./clash-api";

export type DelayStatus = "-" | number;

const DELAY_TEST_URL = "https://www.google.com/generate_204";
const DELAY_TEST_TIMEOUT_MS = 5_000;
export const DELAY_TEST_CONCURRENCY = 3;
const DELAY_CACHE_TTL_MS = 60_000;

const delayCache = new Map<string, { measuredAt: number; value: DelayStatus }>();
const inFlight = new Map<string, Promise<DelayStatus>>();

export async function measureNodeDelay(
  nodeName: string,
  options: { force?: boolean } = {},
): Promise<DelayStatus> {
  const cached = delayCache.get(nodeName);
  if (!options.force && cached && Date.now() - cached.measuredAt < DELAY_CACHE_TTL_MS) {
    return cached.value;
  }
  const existing = inFlight.get(nodeName);
  if (existing) return existing;

  const request = (async (): Promise<DelayStatus> => {
    try {
      const response = await clashApiFetch(
        `/proxies/${encodeURIComponent(nodeName)}/delay?url=${encodeURIComponent(DELAY_TEST_URL)}&timeout=${DELAY_TEST_TIMEOUT_MS}`,
      );
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const payload = await response.json() as { delay?: unknown };
      const value = typeof payload.delay === "number" && Number.isFinite(payload.delay)
        ? payload.delay
        : "-";
      delayCache.set(nodeName, { measuredAt: Date.now(), value });
      return value;
    } catch (error) {
      console.warn(`Failed to fetch proxy delay for ${nodeName}:`, error);
      delayCache.set(nodeName, { measuredAt: Date.now(), value: "-" });
      return "-";
    } finally {
      inFlight.delete(nodeName);
    }
  })();
  inFlight.set(nodeName, request);
  return request;
}

export async function measureNodeDelays(
  nodeNames: readonly string[],
  options: {
    force?: boolean;
    concurrency?: number;
    onResult?: (nodeName: string, delay: DelayStatus) => void;
    isCancelled?: () => boolean;
  } = {},
): Promise<Record<string, DelayStatus>> {
  const uniqueNodes = Array.from(new Set(nodeNames.filter(Boolean)));
  const results: Record<string, DelayStatus> = {};
  let nextIndex = 0;
  const worker = async () => {
    while (!options.isCancelled?.()) {
      const nodeName = uniqueNodes[nextIndex++];
      if (!nodeName) return;
      const delay = await measureNodeDelay(nodeName, { force: options.force });
      if (options.isCancelled?.()) return;
      results[nodeName] = delay;
      options.onResult?.(nodeName, delay);
    }
  };
  await Promise.all(
    Array.from(
      { length: Math.min(options.concurrency ?? DELAY_TEST_CONCURRENCY, uniqueNodes.length) },
      () => worker(),
    ),
  );
  return results;
}
