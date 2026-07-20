import { describe, expect, it } from "vitest";
import { externalFaviconUrl, safeExternalHttpUrl } from "../utils/external-url";

describe("external URL validation", () => {
  it("accepts normalized HTTP URLs", () => {
    expect(safeExternalHttpUrl(" https://example.com/path ")).toBe(
      "https://example.com/path",
    );
    expect(safeExternalHttpUrl("http://127.0.0.1:8080")).toBe(
      "http://127.0.0.1:8080/",
    );
  });

  it("rejects custom schemes and malformed URLs", () => {
    expect(safeExternalHttpUrl("javascript:alert(1)")).toBeUndefined();
    expect(safeExternalHttpUrl("file:///tmp/page.html")).toBeUndefined();
    expect(safeExternalHttpUrl("https-not-a-url")).toBeUndefined();
  });

  it("constructs a root favicon URL without string concatenation", () => {
    expect(externalFaviconUrl("https://example.com/sub/path")).toBe(
      "https://example.com/favicon.ico",
    );
  });
});
