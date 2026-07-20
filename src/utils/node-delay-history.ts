import type { DelayStatus } from "./node-delay";

export type NodeDelayHistoryEntry = {
  delay: DelayStatus;
  measuredAt: number;
};

export type NodeDelayHistory = Record<string, NodeDelayHistoryEntry>;

function isDelayStatus(value: unknown): value is DelayStatus {
  return value === "-"
    || (typeof value === "number" && Number.isFinite(value) && value >= 0);
}

/** Accepts both native JSON values and the string format used by older stores. */
export function parseNodeDelayHistory(raw: unknown): NodeDelayHistory {
  let value = raw;
  if (typeof value === "string") {
    try {
      value = JSON.parse(value);
    } catch {
      return {};
    }
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};

  const history: NodeDelayHistory = {};
  for (const [node, entry] of Object.entries(value)) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) continue;
    const candidate = entry as Partial<NodeDelayHistoryEntry>;
    if (!isDelayStatus(candidate.delay)) continue;
    if (typeof candidate.measuredAt !== "number" || !Number.isFinite(candidate.measuredAt)) {
      continue;
    }
    history[node] = {
      delay: candidate.delay,
      measuredAt: candidate.measuredAt,
    };
  }
  return history;
}

export function retainNodeDelayHistory(
  history: NodeDelayHistory,
  nodeNames: readonly string[],
): NodeDelayHistory {
  const allowed = new Set(nodeNames);
  return Object.fromEntries(
    Object.entries(history).filter(([node]) => allowed.has(node)),
  );
}

export function delaysFromHistory(
  history: NodeDelayHistory,
  nodeNames: readonly string[],
): Record<string, DelayStatus> {
  const delays: Record<string, DelayStatus> = {};
  for (const node of nodeNames) {
    const entry = history[node];
    if (entry) delays[node] = entry.delay;
  }
  return delays;
}

export function updateNodeDelayHistory(
  history: NodeDelayHistory,
  node: string,
  delay: DelayStatus,
  measuredAt = Date.now(),
): NodeDelayHistory {
  return {
    ...history,
    [node]: { delay, measuredAt },
  };
}
