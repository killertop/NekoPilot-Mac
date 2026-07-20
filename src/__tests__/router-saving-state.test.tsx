// @vitest-environment happy-dom

import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import RouterSettings from "../page/router";
import { getCustomRuleSet, setCustomRuleSet } from "../single/store";

vi.mock("../single/store", () => ({
  getCustomRuleSet: vi.fn(),
  setCustomRuleSet: vi.fn(),
}));
vi.mock("../utils/helper", () => ({
  t: (key: string, fallback?: unknown) =>
    typeof fallback === "string" ? fallback : key,
  vpnServiceManager: { syncAndReload: vi.fn() },
}));
vi.mock("sonner", () => ({
  toast: {
    error: vi.fn(),
    info: vi.fn(),
    success: vi.fn(),
  },
}));

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

let host: HTMLDivElement;
let root: Root;
let resolveSave: (() => void) | undefined;

function buttonWithText(
  scope: ParentNode,
  text: string,
): HTMLButtonElement {
  const button = Array.from(scope.querySelectorAll("button")).find(
    (candidate) => candidate.textContent?.trim() === text,
  );
  if (!button) throw new Error(`Missing button: ${text}`);
  return button;
}

beforeEach(async () => {
  document.body.innerHTML = '<main id="onebox-app-main"></main>';
  host = document.getElementById("onebox-app-main") as HTMLDivElement;
  root = createRoot(host);

  vi.mocked(getCustomRuleSet).mockImplementation(async (action) =>
    action === "direct"
      ? { domain: ["example.com"], domain_suffix: [], ip_cidr: [] }
      : { domain: [], domain_suffix: [], ip_cidr: [] }
  );
  const pendingSave = new Promise<void>((resolve) => {
    resolveSave = resolve;
  });
  vi.mocked(setCustomRuleSet).mockImplementation(() => pendingSave);

  await act(async () => {
    root.render(<RouterSettings />);
    await Promise.resolve();
    await Promise.resolve();
  });
});

afterEach(async () => {
  resolveSave?.();
  await act(async () => root.unmount());
  document.getElementById("onebox-overlay-root")?.remove();
  document.body.innerHTML = "";
  resolveSave = undefined;
  vi.clearAllMocks();
});

describe("RouterSettings save state", () => {
  it("disables every mutation entry point until the active save finishes", async () => {
    const editButton = host.querySelector<HTMLButtonElement>(
      'button[aria-label="edit"]',
    );
    expect(editButton).not.toBeNull();

    await act(async () => editButton?.click());
    const dialog = document.querySelector<HTMLElement>('[role="dialog"]');
    expect(dialog).not.toBeNull();

    await act(async () => buttonWithText(dialog!, "action_proxy").click());
    const saveButton = buttonWithText(dialog!, "Save");

    await act(async () => {
      saveButton.click();
      await Promise.resolve();
    });

    expect(setCustomRuleSet).toHaveBeenCalledTimes(2);
    expect(document.querySelector('[role="status"]')?.textContent).toBe(
      "Saving...",
    );
    expect(saveButton.disabled).toBe(true);
    expect(saveButton.textContent).toBe("Saving...");
    expect(dialog?.getAttribute("aria-busy")).toBe("true");

    const rowMutationButtons = host.querySelectorAll<HTMLButtonElement>(
      'button[aria-label="edit"], button[aria-label="delete"]',
    );
    expect(rowMutationButtons.length).toBeGreaterThan(0);
    expect(Array.from(rowMutationButtons).every((button) => button.disabled))
      .toBe(true);
    expect(buttonWithText(host, "Add Rule").disabled).toBe(true);
    expect(
      Array.from(dialog!.querySelectorAll<HTMLButtonElement>('[role="radio"]'))
        .every((button) => button.disabled),
    ).toBe(true);
    expect(dialog?.querySelector<HTMLInputElement>("input")?.disabled).toBe(
      true,
    );

    // A native disabled button cannot start a second write while the first
    // one is pending, so a click can no longer be silently dropped.
    saveButton.click();
    expect(setCustomRuleSet).toHaveBeenCalledTimes(2);

    await act(async () => {
      resolveSave?.();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(document.querySelector('[role="status"]')).toBeNull();
    expect(buttonWithText(host, "Add Rule").disabled).toBe(false);
  });
});
