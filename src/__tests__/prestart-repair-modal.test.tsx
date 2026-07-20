// @vitest-environment happy-dom

import { invoke } from "@tauri-apps/api/core";
import { act, StrictMode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { PrestartRepairModal } from "../components/home/prestart-repair-modal";
import { getProxyPort } from "../single/store";

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn() }));
vi.mock("../single/store", () => ({ getProxyPort: vi.fn() }));
vi.mock("../utils/helper", () => ({
  t: (key: string, fallback?: unknown) =>
    typeof fallback === "string" ? fallback : key,
}));

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

let root: Root;

beforeEach(() => {
  vi.useFakeTimers();
  document.body.innerHTML = '<div id="root"></div>';
  root = createRoot(document.getElementById("root") as HTMLDivElement);
  vi.mocked(getProxyPort).mockResolvedValue(7890);
  vi.mocked(invoke).mockResolvedValue({ success: false, port_released: false });
});

afterEach(async () => {
  await act(async () => root.unmount());
  vi.clearAllTimers();
  vi.useRealTimers();
  document.getElementById("onebox-overlay-root")?.remove();
  document.body.innerHTML = "";
  vi.clearAllMocks();
});

describe("PrestartRepairModal", () => {
  it("starts exactly one live repair run under React StrictMode", async () => {
    await act(async () => {
      root.render(
        <StrictMode>
          <PrestartRepairModal
            visible
            orphanPids={[123]}
            onSuccess={() => undefined}
            onClose={() => undefined}
          />
        </StrictMode>,
      );
    });

    await act(async () => {
      await vi.advanceTimersByTimeAsync(650);
    });

    expect(getProxyPort).toHaveBeenCalledOnce();
    expect(invoke).toHaveBeenCalledOnce();
    expect(invoke).toHaveBeenCalledWith("kill_orphans", { port: 7890 });
  });
});
