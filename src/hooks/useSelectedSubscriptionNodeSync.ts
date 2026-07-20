import { useEffect } from "react";
import { NODE_SELECTOR_REFRESH_EVENT } from "../components/home/events";
import { getStoreValue } from "../single/store";
import { SSI_STORE_KEY } from "../types/definition";
import { switchToSubscriptionNode } from "../utils/node-pool";

/** Ensures a fresh engine honors the configuration selected while offline. */
export function useSelectedSubscriptionNodeSync(isRunning: boolean): void {
  useEffect(() => {
    if (!isRunning) return;
    let cancelled = false;
    const sync = async () => {
      const identifier = await getStoreValue(SSI_STORE_KEY) as string | undefined;
      if (!identifier || cancelled) return;
      try {
        if (await switchToSubscriptionNode(identifier)) {
          window.dispatchEvent(new Event(NODE_SELECTOR_REFRESH_EVENT));
        }
      } catch (error) {
        if (!cancelled) console.warn("Failed to restore selected node pool", error);
      }
    };
    void sync();
    return () => {
      cancelled = true;
    };
  }, [isRunning]);
}
