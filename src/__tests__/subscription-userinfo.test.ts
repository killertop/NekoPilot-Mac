import { describe, expect, it, vi } from "vitest";

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn() }));
vi.mock("sonner", () => ({ toast: { error: vi.fn(), loading: vi.fn(), success: vi.fn() } }));
vi.mock("../utils/helper", () => ({ getSingBoxUserAgent: vi.fn(), t: (key: string) => key }));

import { getRemoteInfoBySubscriptionUserinfo } from "../action/db";

describe("subscription-userinfo parsing", () => {
    it("keeps absent upstream quota metadata absent instead of inventing 1 B values", () => {
        expect(getRemoteInfoBySubscriptionUserinfo("")).toEqual({
            upload: undefined,
            download: undefined,
            total: undefined,
            expire: undefined,
        });
    });

    it("reads the quota fields when the upstream subscription provides them", () => {
        expect(getRemoteInfoBySubscriptionUserinfo("upload=100; download=200; total=1000; expire=1900000000")).toEqual({
            upload: 100,
            download: 200,
            total: 1000,
            expire: 1_900_000_000,
        });
    });
});
