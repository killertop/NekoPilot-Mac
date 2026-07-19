type JsonRecord = Record<string, unknown>;

export type LocalNodeInfo = {
    protocol?: string;
    server?: string;
    tls?: {
        enabled: boolean;
        reality: boolean;
        serverName?: string;
        fingerprint?: string;
        insecure: boolean;
    };
    transport?: {
        type: string;
        detail?: string;
    };
};

function record(value: unknown): JsonRecord | undefined {
    return value && typeof value === "object" && !Array.isArray(value)
        ? value as JsonRecord
        : undefined;
}

function text(value: unknown): string | undefined {
    return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function protocolLabel(protocol: string | undefined): string | undefined {
    if (!protocol) return undefined;
    const labels: Record<string, string> = {
        anytls: "AnyTLS",
        shadowsocks: "Shadowsocks",
        ss: "Shadowsocks",
        trojan: "Trojan",
        vless: "VLESS",
        vmess: "VMess",
    };
    return labels[protocol.toLowerCase()] ?? protocol.toUpperCase();
}

function transportLabel(type: string): string {
    const labels: Record<string, string> = {
        grpc: "gRPC",
        h2: "HTTP/2",
        http: "HTTP",
        httpupgrade: "HTTP Upgrade",
        quic: "QUIC",
        ws: "WebSocket",
    };
    return labels[type.toLowerCase()] ?? type.toUpperCase();
}

/** Extracts safe, user-facing fields from an imported single-node config. */
export function extractLocalNodeInfo(config: unknown): LocalNodeInfo | undefined {
    const root = record(config);
    const outbounds = Array.isArray(root?.outbounds) ? root.outbounds : [];
    const outbound = outbounds.map(record).find(Boolean);
    if (!outbound) return undefined;

    const server = text(outbound.server);
    const port = typeof outbound.server_port === "number" ? outbound.server_port : undefined;
    const tls = record(outbound.tls);
    const utls = record(tls?.utls);
    const reality = record(tls?.reality);
    const transport = record(outbound.transport);
    const transportType = text(transport?.type);
    const transportDetail = text(transport?.path)
        ?? text(transport?.service_name)
        ?? text(record(transport?.headers)?.Host);

    return {
        protocol: protocolLabel(text(outbound.type)),
        server: server ? `${server}${port ? `:${port}` : ""}` : undefined,
        tls: tls
            ? {
                enabled: tls.enabled === true,
                reality: reality?.enabled === true,
                serverName: text(tls.server_name),
                fingerprint: text(utls?.fingerprint),
                insecure: tls.insecure === true,
            }
            : undefined,
        transport: transportType
            ? { type: transportLabel(transportType), detail: transportDetail }
            : undefined,
    };
}
