// @vitest-environment happy-dom

import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { IOSTextField } from "../components/common/ios-text-field";
import {
  InfoRow,
  RowSurface,
  ToggleListRow,
} from "../components/common/list-row";
import { RadioOptionList } from "../components/common/radio-option-list";
import { SettingsModal } from "../components/common/settings-modal";
import { PowerToggle } from "../components/home/power-toggle";

vi.mock("../utils/helper", () => ({
  t: (key: string) => key,
}));

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

let host: HTMLDivElement;
let root: Root;

beforeEach(() => {
  document.body.innerHTML = '<div id="test-root"></div>';
  host = document.getElementById("test-root") as HTMLDivElement;
  root = createRoot(host);
});

afterEach(async () => {
  await act(async () => root.unmount());
  document.getElementById("onebox-overlay-root")?.remove();
  document.body.innerHTML = "";
});

describe("UI primitives", () => {
  it("exposes selected row state and blocks disabled actions", async () => {
    const onPress = vi.fn();
    await act(async () => {
      root.render(
        <RowSurface
          onPress={onPress}
          selected
          disabled
          ariaPressed
          ariaExpanded
        >
          Node
        </RowSurface>,
      );
    });

    const row = host.querySelector("button") as HTMLButtonElement;
    expect(row.getAttribute("aria-pressed")).toBe("true");
    expect(row.getAttribute("aria-expanded")).toBe("true");
    expect(row.className).toContain("bg-[var(--onebox-blue-fill-subtle)]");
    row.click();
    expect(onPress).not.toHaveBeenCalled();
  });

  it("keeps the full toggle row associated with its native control", async () => {
    const onChange = vi.fn();
    await act(async () => {
      root.render(
        <ToggleListRow
          title="Automatic selection"
          checked={false}
          onChange={onChange}
          ariaLabel="Automatic selection"
        />,
      );
    });

    const label = host.querySelector("label") as HTMLLabelElement;
    const input = host.querySelector("input") as HTMLInputElement;
    expect(input.getAttribute("aria-label")).toBe("Automatic selection");
    await act(async () => label.click());
    expect(onChange).toHaveBeenCalledOnce();
  });

  it("connects input errors to an accessible name and description", async () => {
    await act(async () => {
      root.render(
        <IOSTextField
          value=""
          onChange={() => undefined}
          label="Subscription URL"
          placeholder="https://example.com"
          error="Invalid URL"
        />,
      );
    });

    const input = host.querySelector("input") as HTMLInputElement;
    const error = host.querySelector("p") as HTMLParagraphElement;
    expect(input.getAttribute("aria-label")).toBe("Subscription URL");
    expect(input.getAttribute("aria-invalid")).toBe("true");
    expect(input.getAttribute("aria-describedby")).toBe(error.id);
  });

  it("makes settings content inert while a save is in progress", async () => {
    const onClose = vi.fn();
    await act(async () => {
      root.render(
        <SettingsModal
          isOpen
          onClose={onClose}
          title="Proxy port"
          confirmLabel="Save"
          onConfirm={() => undefined}
          confirmLoading
        >
          <input aria-label="Port" />
        </SettingsModal>,
      );
    });

    const dialog = document.querySelector('[role="dialog"]') as HTMLElement;
    const input = dialog.querySelector("input") as HTMLInputElement;
    expect(dialog.getAttribute("aria-busy")).toBe("true");
    expect(input.closest("[inert]")).not.toBeNull();
    expect(
      [...dialog.querySelectorAll<HTMLButtonElement>("button")].every(
        (button) => button.disabled,
      ),
    ).toBe(true);
    document.dispatchEvent(
      new KeyboardEvent("keydown", { key: "Escape", bubbles: true }),
    );
    (document.querySelector(".onebox-dialog-backdrop") as HTMLElement).click();
    dialog.querySelector<HTMLButtonElement>("button")?.click();
    expect(onClose).not.toHaveBeenCalled();
  });

  it("localizes the power action for both connection states", async () => {
    await act(async () => {
      root.render(
        <PowerToggle
          isRunning={false}
          isLoading={false}
          onClick={() => undefined}
        />,
      );
    });
    expect(host.querySelector("button")?.getAttribute("aria-label")).toBe(
      "connect",
    );

    await act(async () => {
      root.render(
        <PowerToggle
          isRunning
          isLoading={false}
          onClick={() => undefined}
        />,
      );
    });
    expect(host.querySelector("button")?.getAttribute("aria-label")).toBe(
      "disconnect",
    );
  });

  it("groups radio options under one native name", async () => {
    await act(async () => {
      root.render(
        <RadioOptionList
          value="one"
          onChange={() => undefined}
          ariaLabel="User Agent"
          options={[
            { key: "one", label: "One" },
            { key: "two", label: "Two" },
          ]}
        />,
      );
    });

    const group = host.querySelector('[role="radiogroup"]') as HTMLElement;
    const radios = [...group.querySelectorAll<HTMLInputElement>("input")];
    expect(group.getAttribute("aria-label")).toBe("User Agent");
    expect(radios[0].name).not.toBe("");
    expect(radios[0].name).toBe(radios[1].name);
  });

  it("shows a keyboard focus treatment on clickable info rows", async () => {
    await act(async () => {
      root.render(
        <InfoRow label="Kernel" value="1.0" onPress={() => undefined} />,
      );
    });
    expect(host.querySelector("button")?.className).toContain(
      "focus-visible:outline-2",
    );
  });
});
