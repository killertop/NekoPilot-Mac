import { invoke } from "@tauri-apps/api/core";
import { getSingBoxUserAgent } from "../utils/helper";

export async function refreshSubscription(identifier: string): Promise<void> {
    await invoke('refresh_subscription', {
        identifier,
        userAgent: await getSingBoxUserAgent(),
    });
}
