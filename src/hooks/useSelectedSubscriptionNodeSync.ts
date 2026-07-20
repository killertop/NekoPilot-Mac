import { useEffect } from "react";
import { NODE_SELECTOR_REFRESH_EVENT } from "../components/home/events";
import { getStoreValue } from "../single/store";
import { SELECTED_NODE_STORE_KEY, SSI_STORE_KEY } from "../types/definition";
import {
  getExitGatewaySelector,
  selectExitGatewayNode,
  switchToSubscriptionNode,
} from "../utils/node-pool";

/** Restores the exact unified-pool node, with the old source preference as fallback. */
export function useSelectedSubscriptionNodeSync(isRunning: boolean): void {
  useEffect(() => {
    if (!isRunning) return;
    let cancelled = false;
    const sync = async () => {
      const [nodeTag, identifier] = await Promise.all([
        getStoreValue(SELECTED_NODE_STORE_KEY) as Promise<string | undefined>,
        getStoreValue(SSI_STORE_KEY) as Promise<string | undefined>,
      ]);
      if (cancelled) return;
      try {
        let switched = false;
        if (nodeTag) {
          const selector = await getExitGatewaySelector();
          if (cancelled) return;
          if (selector.all.includes(nodeTag)) {
            if (selector.now !== nodeTag) await selectExitGatewayNode(nodeTag);
            if (cancelled) return;
            switched = true;
          }
        }
        if (!switched && identifier) {
          switched = await switchToSubscriptionNode(identifier, {
            isCancelled: () => cancelled,
          });
        }
        if (!cancelled && switched) {
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
