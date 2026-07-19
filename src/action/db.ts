
import { invoke } from '@tauri-apps/api/core';
import { toast } from 'sonner';
import { getSingBoxUserAgent, t } from '../utils/helper';
import { isUsableSubscriptionConfig } from './subscription-config';
import { isLocalProxyLink } from './proxy-link';


export interface ResponseHeaders {
    'subscription-userinfo': string;
    'official-website': string;
    'content-disposition': string;
    get?: (name: string) => string | null;
}

export interface ConfigResponse {
    data: any;
    headers: ResponseHeaders;
    status?: number;
}

export { isUsableSubscriptionConfig } from './subscription-config';

export { isLocalProxyLink } from './proxy-link';

export async function fetchConfigContent(url: string): Promise<ConfigResponse> {
    const result = await invoke<{
        data: unknown;
        headers: Record<string, string>;
        status: number;
    }>('fetch_config_with_optimal_dns', {
        url,
        userAgent: await getSingBoxUserAgent(),
    });

    return {
        data: result.data ?? null,
        headers: {
            'subscription-userinfo': result.headers['subscription-userinfo'] || '',
            'official-website': result.headers['official-website'] || 'https://sing-box.net',
            'content-disposition': result.headers['content-disposition'] || '',
        },
        status: result.status,
    };
}

export function getRemoteNameByContentDisposition(contentDisposition: string) {
    const filenameRegex = /filename[^;=\n]*=((['"]).*?\2|[^;\n]*)/;
    const matches = filenameRegex.exec(contentDisposition);
    if (matches != null && matches[1]) {
        return decodeURIComponent(matches[1].replace(/['"]/g, ''));
    }
    return null;
}


export function getRemoteInfoBySubscriptionUserinfo(subscriptionUserinfo: string) {
    try {
        const info = subscriptionUserinfo.split('; ').reduce((acc, item) => {
            const [key, value] = item.split('=');
            if (key && value) {
                acc[key.trim()] = value.trim();
            }
            return acc;
        }, {} as Record<string, string>);

        const numberOrUndefined = (value: string | undefined) => {
            const parsed = Number.parseInt(value ?? '', 10);
            return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : undefined;
        };

        return {
            upload: numberOrUndefined(info.upload),
            download: numberOrUndefined(info.download),
            total: numberOrUndefined(info.total),
            expire: numberOrUndefined(info.expire),
        };
    } catch (error) {
        console.error('Error parsing subscription userinfo:', error);
        return {
            upload: undefined,
            download: undefined,
            total: undefined,
            expire: undefined,
        };
    }
}

export function subscriptionWritePayload(
    url: string,
    name: string | undefined,
    response: ConfigResponse,
    preserveExistingName = false,
) {
    const { upload, download, total, expire } = getRemoteInfoBySubscriptionUserinfo(
        response.headers['subscription-userinfo'] || '',
    );
    return {
        url,
        name: preserveExistingName
            ? undefined
            : (!name || name === '默认配置')
            ? getRemoteNameByContentDisposition(response.headers['content-disposition'] || '') || '配置'
            : name,
        officialWebsite: response.headers['official-website'] || 'https://sing-box.net',
        usedTraffic: (upload ?? 0) + (download ?? 0),
        totalTraffic: total ?? 0,
        expireTime: (expire ?? 0) * 1000,
        lastUpdateTime: Date.now(),
        config: response.data,
    };
}


export async function updateSubscription(identifier: string) {
    try {
        await invoke('refresh_subscription', {
            identifier,
            userAgent: await getSingBoxUserAgent(),
        });
        toast.success(t('update_subscription_success'))

    } catch (error) {
        console.error('Error updating subscription:', error);
        toast.error(t('update_subscription_failed'))
    }


}



/**
 * Removes duplicate subscription rows by URL, keeping the most recently inserted entry.
 * Orphaned subscription_configs rows are removed automatically via CASCADE.
 * Intended to be called once on every app startup.
 */
export async function deduplicateSubscriptionsByUrl(): Promise<void> {
    await invoke('deduplicate_subscriptions');
}

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
    // Timings bracket each phase so the renderer log reveals whether the
    // dominant cost is the network fetch (Rust reqwest, see
    // `fetch_config_with_optimal_dns`), the DB upsert, or JSON parsing.
    const tTotal = performance.now();
    try {
        if (isLocalProxyLink(url)) {
            const identifier = await invoke<string>('import_proxy_link', { link: url, name });
            console.info(`[import] local proxy link imported identifier=${identifier}`);
            return identifier;
        }
        const tFetch = performance.now();
        const response = await fetchConfigContent(url);
        const fetchMs = Math.round(performance.now() - tFetch);
        console.info(`[import] fetch done status=${response.status} elapsed=${fetchMs}ms url=${url}`);
        if (response.status !== 200 || !isUsableSubscriptionConfig(response.data)) {
            console.warn(`[import] abort unusable response status=${response.status} url=${url}`);
            throw new Error('subscription_no_usable_nodes');
        }

        const tDb = performance.now();
        const identifier = await invoke<string>('upsert_subscription', {
            subscription: subscriptionWritePayload(url, name, response),
        });
        const dbMs = Math.round(performance.now() - tDb);
        console.info(`[import] native db upsert elapsed=${dbMs}ms total=${Math.round(performance.now() - tTotal)}ms identifier=${identifier}`);
        return identifier;
    } catch (err) {
        console.error(`[import] error total=${Math.round(performance.now() - tTotal)}ms err=${err instanceof Error ? err.message : String(err)} url=${url}`);
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
