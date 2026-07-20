import { describe, expect, it, vi } from "vitest";
import en from "../../lang/en.json";
import zh from "../../lang/zh.json";
import { formatSubscriptionImportError } from "../action/db";

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn() }));
vi.mock("sonner", () => ({
  toast: {
    error: vi.fn(),
    loading: vi.fn(),
    success: vi.fn(),
  },
}));
vi.mock("../utils/helper", () => ({
  getSingBoxUserAgent: vi.fn(),
  t: (key: string) => key,
}));

describe("remote config import errors", () => {
  it.each([
    ["subscription_destination_not_public", "import_remote_address_blocked"],
    ["unsupported_subscription_scheme", "import_remote_scheme_unsupported"],
    ["subscription_dns_resolution_failed", "import_dns_resolution_failed"],
    ["subscription_too_many_redirects", "import_redirect_invalid"],
    ["subscription_redirect_missing_location", "import_redirect_invalid"],
    ["subscription_redirect_invalid", "import_redirect_invalid"],
    ["subscription_response_too_large", "import_response_too_large"],
    ["subscription_client_failed", "import_fetch_failed"],
    ["subscription_response_read_failed", "import_fetch_failed"],
    ["invalid_accelerated_subscription_url", "import_fetch_failed"],
    [
      "[CONFIG_LOAD] PRIMARY_FAILED: TIMEOUT, no accelerator configured",
      "import_fetch_failed",
    ],
    [
      "[CONFIG_LOAD] BOTH_FAILED: primary=CONNECT_ERROR, accelerator=REQUEST_ERROR",
      "import_fetch_failed",
    ],
    ["subscription_response_invalid_format", "import_response_invalid"],
  ])("maps %s to actionable copy", (code, expectedKey) => {
    expect(formatSubscriptionImportError(code)).toBe(expectedKey);
  });

  it("recognizes a stable error embedded in the native fallback message", () => {
    expect(
      formatSubscriptionImportError(
        new Error(
          "[CONFIG_LOAD] PRIMARY_FAILED: subscription_dns_resolution_failed, FALLBACK_FAILED: invalid_accelerated_subscription_url",
        ),
      ),
    ).toBe("import_dns_resolution_failed");
  });

  it("keeps unknown native errors on the generic invalid-link message", () => {
    expect(formatSubscriptionImportError("unrecognized_import_failure")).toBe(
      "import_invalid_link",
    );
  });
});

describe("translation coverage", () => {
  it("keeps English and Chinese translation keys in parity", () => {
    expect(Object.keys(en).sort()).toEqual(Object.keys(zh).sort());
  });

  it("explains the public-address safety boundary and node-link alternative", () => {
    expect(en.import_remote_address_blocked).toContain("public HTTP(S)");
    expect(en.import_remote_address_blocked).toContain("blocked for safety");
    expect(en.import_remote_address_blocked).toContain("VLESS");
    expect(zh.import_remote_address_blocked).toContain("公网 HTTP(S)");
    expect(zh.import_remote_address_blocked).toContain("出于安全原因");
    expect(zh.import_remote_address_blocked).toContain("VLESS");
  });
});
