// @vitest-environment happy-dom

import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { AppDialog } from "../components/common/app-dialog";
import { OperationProgressDialog } from "../components/common/operation-progress-dialog";

vi.mock("../utils/helper", () => ({
  t: (key: string, fallback?: unknown) =>
    typeof fallback === "string" ? fallback : key,
}));

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

let host: HTMLDivElement;
let root: Root;

async function render(children: ReactNode) {
  await act(async () => root.render(children));
}

async function waitForExit() {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 350));
  });
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

beforeEach(() => {
  document.body.innerHTML = `
    <div id="root">
      <main id="onebox-app-main"></main>
      <div id="toast-live-region" role="status" aria-live="polite"></div>
    </div>
  `;
  host = document.getElementById("onebox-app-main") as HTMLDivElement;
  root = createRoot(host);
});

afterEach(async () => {
  await act(async () => root.unmount());
  document.getElementById("onebox-overlay-root")?.remove();
  document.body.innerHTML = "";
});

describe("AppDialog", () => {
  it("focuses the first control and does not steal focus after a parent rerender", async () => {
    await render(
      <AppDialog open ariaLabel="Example" onClose={() => undefined}>
        <button type="button">First</button>
        <input aria-label="Second" />
      </AppDialog>,
    );

    const first = document.querySelector("button") as HTMLButtonElement;
    const second = document.querySelector("input") as HTMLInputElement;
    expect(document.activeElement).toBe(first);
    second.focus();

    await render(
      <AppDialog open ariaLabel="Example" onClose={() => undefined}>
        <button type="button">First changed</button>
        <input aria-label="Second" />
      </AppDialog>,
    );

    expect(document.activeElement).toBe(second);
  });

  it("honours an explicitly requested initial focus target", async () => {
    await render(
      <AppDialog open ariaLabel="Initial focus">
        <button type="button">First</button>
        <input aria-label="Preferred" data-autofocus="true" />
      </AppDialog>,
    );

    expect(document.activeElement?.getAttribute("aria-label")).toBe(
      "Preferred",
    );
  });

  it("keeps Tab inside the top dialog and only lets the top dialog handle Escape", async () => {
    const closeFirst = vi.fn();
    const closeSecond = vi.fn();
    await render(
      <>
        <AppDialog open ariaLabel="First dialog" onClose={closeFirst}>
          <button type="button">First dialog action</button>
        </AppDialog>
        <AppDialog open ariaLabel="Second dialog" onClose={closeSecond}>
          <button type="button">Second first</button>
          <button type="button">Second last</button>
        </AppDialog>
      </>,
    );

    const dialogs = document.querySelectorAll<HTMLElement>('[role="dialog"]');
    const secondButtons = dialogs[1].querySelectorAll<HTMLButtonElement>(
      "button",
    );
    expect(Number(dialogs[1].parentElement?.style.zIndex)).toBeGreaterThan(
      Number(dialogs[0].parentElement?.style.zIndex),
    );
    secondButtons[1].focus();
    document.dispatchEvent(
      new KeyboardEvent("keydown", { key: "Tab", bubbles: true }),
    );
    expect(document.activeElement).toBe(secondButtons[0]);

    document.dispatchEvent(
      new KeyboardEvent("keydown", { key: "Escape", bubbles: true }),
    );
    expect(closeSecond).toHaveBeenCalledOnce();
    expect(closeFirst).not.toHaveBeenCalled();
  });

  it("restores the parent trigger after a nested dialog finishes closing", async () => {
    await render(
      <AppDialog open ariaLabel="Parent">
        <button type="button">Open details</button>
      </AppDialog>,
    );
    const parentTrigger = document.querySelector(
      '[role="dialog"] button',
    ) as HTMLButtonElement;
    parentTrigger.focus();

    await render(
      <>
        <AppDialog open ariaLabel="Parent">
          <button type="button">Open details</button>
        </AppDialog>
        <AppDialog open ariaLabel="Details">
          <button type="button">Close details</button>
        </AppDialog>
      </>,
    );
    const dialogs = document.querySelectorAll<HTMLElement>('[role="dialog"]');
    expect(dialogs[0].inert).toBe(true);

    await render(
      <>
        <AppDialog open ariaLabel="Parent">
          <button type="button">Open details</button>
        </AppDialog>
        <AppDialog open={false} ariaLabel="Details">
          <button type="button">Close details</button>
        </AppDialog>
      </>,
    );
    await waitForExit();

    const parent = document.querySelector('[role="dialog"]') as HTMLElement;
    expect(parent.inert).toBe(false);
    expect(parent.hasAttribute("aria-hidden")).toBe(false);
    expect(document.activeElement?.textContent).toBe("Open details");
  });

  it("keeps the app inert through exit and restores the opener focus", async () => {
    await render(<button type="button">Open</button>);
    const opener = host.querySelector("button") as HTMLButtonElement;
    opener.focus();

    await render(
      <>
        <button type="button">Open</button>
        <AppDialog open ariaLabel="Exit test" onClose={() => undefined}>
          <button type="button">Inside</button>
        </AppDialog>
      </>,
    );
    expect(host.inert).toBe(true);
    expect(host.getAttribute("aria-hidden")).toBe("true");
    expect(document.getElementById("root")?.inert).toBe(false);
    expect(
      document.getElementById("toast-live-region")?.hasAttribute(
        "aria-hidden",
      ),
    ).toBe(false);

    await render(
      <>
        <button type="button">Open</button>
        <AppDialog open={false} ariaLabel="Exit test" onClose={() => undefined}>
          <button type="button">Inside</button>
        </AppDialog>
      </>,
    );
    expect(host.inert).toBe(true);

    await waitForExit();
    expect(host.inert).toBe(false);
    expect(host.hasAttribute("aria-hidden")).toBe(false);
    expect(document.activeElement?.textContent).toBe("Open");
  });

  it("ignores Escape and backdrop dismissal while busy", async () => {
    const onClose = vi.fn();
    await render(
      <AppDialog
        open
        ariaLabel="Busy"
        onClose={onClose}
        closeOnEscape={false}
        dismissOnBackdrop={false}
        busy
      >
        <button type="button">Working</button>
      </AppDialog>,
    );

    document.dispatchEvent(
      new KeyboardEvent("keydown", { key: "Escape", bubbles: true }),
    );
    (document.querySelector(".onebox-dialog-backdrop") as HTMLElement).click();
    expect(onClose).not.toHaveBeenCalled();
    expect(document.querySelector('[role="dialog"]')?.getAttribute("aria-busy"))
      .toBe("true");
  });
});

describe("OperationProgressDialog", () => {
  const steps = [{
    key: "one",
    label: "First step",
    state: "done" as const,
    railFillPercent: 1,
  }];

  it("only renders a terminal close action when it has a real handler", async () => {
    await render(
      <OperationProgressDialog
        open
        title="Complete"
        titleId="operation-title"
        steps={steps}
        running={false}
        terminalState="success"
      />,
    );
    expect(document.querySelector('[role="dialog"] button')).toBeNull();

    const onClose = vi.fn();
    await render(
      <OperationProgressDialog
        open
        title="Complete"
        titleId="operation-title"
        steps={steps}
        running={false}
        terminalState="success"
        onClose={onClose}
      />,
    );
    const close = document.querySelector(
      '[role="dialog"] button',
    ) as HTMLButtonElement;
    expect(document.activeElement).toBe(close);
    close.click();
    expect(onClose).toHaveBeenCalledOnce();
  });
});
