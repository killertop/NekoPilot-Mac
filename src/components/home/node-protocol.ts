export type NodeProtocolMap = Record<string, string>;

type ProxyEntry = {
    type?: unknown;
};

type ProxiesResponse = {
    proxies?: Record<string, ProxyEntry | undefined>;
};

const NON_SERVER_PROXY_TYPES = new Set([
    "selector",
    "urltest",
    "fallback",
    "loadbalance",
    "relay",
    "direct",
    "reject",
    "block",
]);

export function formatNodeProtocol(type: unknown): string | undefined {
    if (typeof type !== "string") return undefined;

    const normalized = type.trim().toLowerCase();
    if (!normalized || NON_SERVER_PROXY_TYPES.has(normalized)) {
        return undefined;
    }

    return normalized;
}

/**
 * Imported node tags use `VLESS · Name` internally to avoid collisions with
 * sing-box's built-in tags. Keep that implementation detail out of the UI:
 * the protocol is represented by the optional badge instead.
 */
export function nodeDisplayName(nodeName: string, protocol?: string): string {
    if (!protocol) return nodeName;

    const separator = nodeName.indexOf("·");
    if (separator < 0) return nodeName;

    const prefix = nodeName.slice(0, separator).trim();
    const label = nodeName.slice(separator + 1).trim();
    return label && formatNodeProtocol(prefix) === protocol ? label : nodeName;
}

export function nodeProtocolLabel(protocol?: string): string | undefined {
    if (!protocol) return undefined;
    const labels: Record<string, string> = {
        anytls: "AnyTLS",
        shadowsocks: "Shadowsocks",
        trojan: "Trojan",
        vless: "VLESS",
        vmess: "VMess",
    };
    return labels[protocol] ?? protocol.toUpperCase();
}

export function buildNodeProtocolMap(
    nodeList: readonly string[],
    response: unknown,
): NodeProtocolMap {
    const proxies =
        typeof response === "object" && response !== null
            ? (response as ProxiesResponse).proxies
            : undefined;

    if (!proxies || typeof proxies !== "object") return {};

    return nodeList.reduce<NodeProtocolMap>((acc, nodeName) => {
        const protocol = formatNodeProtocol(proxies[nodeName]?.type);
        if (protocol) {
            acc[nodeName] = protocol;
        }
        return acc;
    }, {});
}
