import { describe, expect, it } from "vitest";
import { extractLocalNodeInfo } from "../components/configuration/local-node-info";
import {
    hasExpiry,
    hasTrafficQuota,
    isLocalConfiguration,
} from "../components/configuration/subscription-metadata";

describe("subscription metadata visibility", () => {
    it("never treats a local node as a traffic quota or an expiring subscription", () => {
        const local = {
            source_type: "local_link" as const,
            used_traffic: 0,
            total_traffic: 1,
            expire_time: 32_503_680_000_000,
        };
        expect(isLocalConfiguration(local)).toBe(true);
        expect(hasTrafficQuota(local)).toBe(false);
        expect(hasExpiry(local)).toBe(false);
    });

    it("only shows upstream-provided subscription metadata", () => {
        const provided = {
            source_type: "subscription" as const,
            used_traffic: 100,
            total_traffic: 1_000,
            expire_time: 1_900_000_000_000,
        };
        expect(hasTrafficQuota(provided)).toBe(true);
        expect(hasExpiry(provided)).toBe(true);

        const legacyPlaceholder = {
            source_type: "subscription" as const,
            used_traffic: 2,
            total_traffic: 1,
            expire_time: 1_000,
        };
        expect(hasTrafficQuota(legacyPlaceholder)).toBe(false);
        expect(hasExpiry(legacyPlaceholder)).toBe(false);
    });
});

describe("local node details", () => {
    it("shows connection parameters without exposing credentials", () => {
        expect(extractLocalNodeInfo({
            outbounds: [{
                type: "vless",
                server: "edge.example.com",
                server_port: 443,
                tls: {
                    enabled: true,
                    server_name: "cdn.example.com",
                    reality: { enabled: true },
                    utls: { enabled: true, fingerprint: "chrome" },
                },
                transport: { type: "ws", path: "/edge" },
            }],
        })).toEqual({
            protocol: "VLESS",
            server: "edge.example.com:443",
            tls: {
                enabled: true,
                reality: true,
                serverName: "cdn.example.com",
                fingerprint: "chrome",
                insecure: false,
            },
            transport: { type: "WebSocket", detail: "/edge" },
        });
    });
});
