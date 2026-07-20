import { invoke } from "@tauri-apps/api/core";
import { getSingBoxUserAgent } from "../utils/helper";

const inflightRefreshes = new Map<string, Promise<void>>();

export function refreshSubscription(identifier: string): Promise<void> {
    const existing = inflightRefreshes.get(identifier);
    if (existing) return existing;

    const refresh = (async () => {
        await invoke('refresh_subscription', {
            identifier,
            userAgent: await getSingBoxUserAgent(),
        });
    })().finally(() => {
        inflightRefreshes.delete(identifier);
    });
    inflightRefreshes.set(identifier, refresh);
    return refresh;
}
