export type SubscriptionMetadataSource = {
    source_type: "subscription" | "local_link";
    expire_time: number;
    used_traffic: number;
    total_traffic: number;
};

const LOCAL_FILE_SENTINEL = 32_503_680_000_000;

export function isLocalConfiguration(item: SubscriptionMetadataSource): boolean {
    return item.source_type === "local_link" || item.expire_time === LOCAL_FILE_SENTINEL;
}

// Earlier builds wrote this placeholder whenever an upstream subscription did
// not expose a `subscription-userinfo` header. Treat it as absent metadata,
// rather than presenting a misleading 2 B / 1 B quota and a 1970 expiry.
function isLegacyMissingMetadata(item: SubscriptionMetadataSource): boolean {
    return item.used_traffic === 2 && item.total_traffic === 1 && item.expire_time === 1_000;
}

export function hasTrafficQuota(item: SubscriptionMetadataSource): boolean {
    return !isLocalConfiguration(item)
        && !isLegacyMissingMetadata(item)
        && Number.isFinite(item.total_traffic)
        && item.total_traffic > 0;
}

/** Older database defaults stored Unix seconds; current imports store millis. */
export function normalizeTimestampMs(value: number): number {
    if (!Number.isFinite(value)) return 0;
    return Math.abs(value) < 1_000_000_000_000 ? value * 1_000 : value;
}
