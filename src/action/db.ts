
import { invoke } from '@tauri-apps/api/core';
import { toast } from 'sonner';
import { getSingBoxUserAgent, t } from '../utils/helper';
import { isLocalProxyLink } from './proxy-link';

export { isLocalProxyLink } from './proxy-link';



// Tracks in-flight insertSubscription calls by URL.
// A second call for the same URL reuses the existing Promise instead of
// racing to INSERT a duplicate record into the database.
const inflightInsertions = new Map<string, Promise<string>>();

/** Converts the stable native import error codes into actionable UI copy. */
export function formatSubscriptionImportError(error: unknown): string {
    const code = error instanceof Error ? error.message : String(error);
    if (code.includes('proxy_link_missing_reality_public_key')) {
        return t('import_missing_reality_public_key');
    }
    if (code.includes('proxy_link_missing_server') || code.includes('proxy_link_missing_port')) {
        return t('import_missing_server');
    }
    if (code.includes('proxy_link_missing_credential')) {
        return t('import_missing_credential');
    }
    if (code.includes('unsupported_proxy_link') || code.includes('unsupported_shadowsocks_plugin')) {
        return t('import_unsupported_protocol');
    }
    if (code.includes('subscription_no_usable_nodes')) {
        return t('import_subscription_no_nodes');
    }
    return t('import_invalid_link');
}

/**
 * Upserts a subscription by URL. If the URL already exists, updates config + traffic + name
 * and returns the existing identifier. If not, inserts a new row.
 * Returns the identifier on success, undefined on failure. No UI side-effects.
 *
 * Concurrent calls for the same URL are collapsed into a single operation to
 * prevent the TOCTOU race that would otherwise create duplicate DB records.
 */
export function insertSubscription(url: string, name?: string): Promise<string> {
    const inflight = inflightInsertions.get(url);
    if (inflight) return inflight;

    const promise = _insertSubscription(url, name).finally(() => {
        inflightInsertions.delete(url);
    });
    inflightInsertions.set(url, promise);
    return promise;
}

async function _insertSubscription(url: string, name?: string): Promise<string> {
    // Remote imports stay native end-to-end: fetching, validation and SQLite
    // persistence no longer serialize a potentially large node list through
    // the WebView. The renderer receives only the selected identifier.
    const tTotal = performance.now();
    try {
        if (isLocalProxyLink(url)) {
            const identifier = await invoke<string>('import_proxy_link', { link: url, name });
            console.info(`[import] local proxy link imported identifier=${identifier}`);
            return identifier;
        }
        const identifier = await invoke<string>('import_subscription', {
            url,
            name,
            userAgent: await getSingBoxUserAgent(),
        });
        console.info(`[import] native subscription import elapsed=${Math.round(performance.now() - tTotal)}ms identifier=${identifier}`);
        return identifier;
    } catch (err) {
        console.error(`[import] error total=${Math.round(performance.now() - tTotal)}ms err=${err instanceof Error ? err.message : String(err)}`);
        throw err;
    }
}

export async function addSubscription(url: string, name: string | undefined) {
    const toastId = toast.loading(t('adding_subscription'))
    try {
        await insertSubscription(url, name);
        toast.success(t('add_subscription_success'), { id: toastId })

    } catch (error) {
        console.error('Error adding subscription:', error)
        toast.error(formatSubscriptionImportError(error), {
            id: toastId,
            duration: 5000
        })
    }
}



// delete subscription by  identifier

export async function renameSubscription(identifier: string, name: string): Promise<void> {
    const trimmed = name.trim();
    if (!trimmed) return;
    await invoke('rename_subscription', { identifier, name: trimmed });
}

export async function deleteSubscription(identifier: string) {
    try {
        await invoke('delete_subscription', { identifier });
    } catch (error) {
        console.error('Error deleting subscription:', error)
        toast.error(t('delete_subscription_failed'))
    }
}


export async function getSubscriptionConfig(identifier: string) {
    try {
        return await invoke('get_subscription_config', { identifier });
    } catch (error) {
        console.error('Error getting subscription config:', error)
        // toast.error('获取订阅配置失败')
        toast.error(t('get_subscription_config_failed'))
    }

}
