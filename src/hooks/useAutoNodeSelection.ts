import { useEffect, useState } from "react";
import { NODE_SELECTOR_REFRESH_EVENT } from "../components/home/events";
import { getAutoSelectFastestNode } from "../single/store";
import { AUTO_SELECT_FASTEST_NODE_CHANGED_EVENT } from "../types/definition";
import { clashApiFetch } from "../utils/clash-api";
import { measureNodeDelays, type DelayStatus } from "../utils/node-delay";
import {
  getExitGatewaySelector,
  selectExitGatewayNode,
} from "../utils/node-pool";

const INITIAL_TEST_DELAY_MS = 5_000;
export const AUTO_SELECT_INTERVAL_MS = 10 * 60_000;
const LONG_CONNECTION_AGE_MS = 60_000;
const LONG_CONNECTION_RECHECK_MS = 30_000;

type ConnectionRecord = {
  start?: unknown;
};

type ConnectionsPayload = {
  connections?: unknown;
};

export function connectionAgeMs(start: unknown, nowMs: number): number | undefined {
  if (typeof start === "number" && Number.isFinite(start)) {
    const timestamp = start < 10_000_000_000 ? start * 1_000 : start;
    return Math.max(0, nowMs - timestamp);
  }
  if (typeof start !== "string") return undefined;
  const timestamp = Date.parse(start);
  return Number.isFinite(timestamp) ? Math.max(0, nowMs - timestamp) : undefined;
}

export function hasLongLivedConnection(
  payload: ConnectionsPayload,
  nowMs = Date.now(),
  minimumAgeMs = LONG_CONNECTION_AGE_MS,
): boolean {
  if (!Array.isArray(payload.connections)) return false;
  return payload.connections.some((value) => {
    if (!value || typeof value !== "object") return false;
    const age = connectionAgeMs((value as ConnectionRecord).start, nowMs);
    return age !== undefined && age >= minimumAgeMs;
  });
}

export function pickFastestNode(
  delays: Record<string, DelayStatus>,
): { node: string; delay: number } | undefined {
  let fastest: { node: string; delay: number } | undefined;
  for (const [node, delay] of Object.entries(delays)) {
    if (typeof delay !== "number" || !Number.isFinite(delay)) continue;
    if (!fastest || delay < fastest.delay) fastest = { node, delay };
  }
  return fastest;
}

async function fetchConnections(): Promise<ConnectionsPayload> {
  const response = await clashApiFetch("/connections");
  if (!response.ok) throw new Error(`connections_http_${response.status}`);
  return await response.json() as ConnectionsPayload;
}

function wait(ms: number): Promise<void> {
  return new Promise((resolve) => window.setTimeout(resolve, ms));
}

/**
 * App-wide, low-frequency automatic node optimizer.
 *
 * The hook owns one timer, tests at most three nodes concurrently, never lets
 * cycles overlap, and pauses a pending switch while a connection older than
 * one minute is still alive. It remains mounted when the user leaves Home.
 */
export function useAutoNodeSelection(isRunning: boolean): void {
  const [isEnabled, setIsEnabled] = useState<boolean>();

  useEffect(() => {
    let cancelled = false;
    void getAutoSelectFastestNode()
      .then((value) => {
        if (!cancelled) setIsEnabled(value);
      })
      .catch((error) => {
        console.warn("Failed to load automatic node selection setting", error);
        if (!cancelled) setIsEnabled(true);
      });

    const handleSettingChanged = (event: Event) => {
      setIsEnabled((event as CustomEvent<boolean>).detail);
    };
    window.addEventListener(
      AUTO_SELECT_FASTEST_NODE_CHANGED_EVENT,
      handleSettingChanged,
    );
    return () => {
      cancelled = true;
      window.removeEventListener(
        AUTO_SELECT_FASTEST_NODE_CHANGED_EVENT,
        handleSettingChanged,
      );
    };
  }, []);

  useEffect(() => {
    if (!isRunning || isEnabled !== true) return;
    let cancelled = false;
    let timer: number | undefined;

    const schedule = (delayMs: number) => {
      if (cancelled) return;
      timer = window.setTimeout(() => void runCycle(), delayMs);
    };

    const waitUntilSafeAndSwitch = async (candidate: string) => {
      while (!cancelled) {
        const selector = await getExitGatewaySelector();
        if (!selector.all.includes(candidate) || selector.now === candidate) return;

        let connections: ConnectionsPayload;
        try {
          connections = await fetchConnections();
        } catch (error) {
          // If connection state is unavailable, preserve existing traffic and
          // defer the switch instead of guessing that it is safe.
          console.warn("Automatic node switch deferred: connection state unavailable", error);
          return;
        }
        if (!hasLongLivedConnection(connections)) {
          await selectExitGatewayNode(candidate);
          window.dispatchEvent(new Event(NODE_SELECTOR_REFRESH_EVENT));
          console.info(`[auto-node] switched to ${candidate}`);
          return;
        }
        console.info("[auto-node] waiting for long-lived connections to finish");
        await wait(LONG_CONNECTION_RECHECK_MS);
      }
    };

    const runCycle = async () => {
      if (cancelled) return;
      try {
        const selector = await getExitGatewaySelector();
        if (selector.all.length > 1) {
          const delays = await measureNodeDelays(selector.all, {
            isCancelled: () => cancelled,
          });
          const fastest = pickFastestNode(delays);
          if (!cancelled && fastest && fastest.node !== selector.now) {
            await waitUntilSafeAndSwitch(fastest.node);
          }
        }
      } catch (error) {
        if (!cancelled) console.warn("Automatic node selection failed", error);
      } finally {
        schedule(AUTO_SELECT_INTERVAL_MS);
      }
    };

    schedule(INITIAL_TEST_DELAY_MS);
    return () => {
      cancelled = true;
      if (timer !== undefined) window.clearTimeout(timer);
    };
  }, [isEnabled, isRunning]);
}
