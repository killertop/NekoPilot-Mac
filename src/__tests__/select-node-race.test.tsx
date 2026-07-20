// @vitest-environment happy-dom

import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { NodeList } from "../components/home/select-node";
import { getStoreValue, setStoreValue } from "../single/store";
import { selectExitGatewayNode } from "../utils/node-pool";

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn() }));
vi.mock("../single/store", () => ({
  getShowNodeProtocol: vi.fn(),
  getStoreValue: vi.fn(),
  setStoreValue: vi.fn(),
}));
vi.mock("../utils/clash-api", () => ({ clashApiFetch: vi.fn() }));
vi.mock("../utils/helper", () => ({ t: (key: string) => key }));
vi.mock("../utils/node-delay", () => ({
  measureNodeDelays: vi.fn(),
  measureOfflineNodeDelay: vi.fn(),
}));
vi.mock("../utils/node-pool", () => ({
  displayNodeTag: (node: string) => node,
  selectExitGatewayNode: vi.fn(),
  subscriptionIdentifierForNode: vi.fn(() => undefined),
}));

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

let root: Root;
let consoleError: ReturnType<typeof vi.spyOn>;

function Harness() {
  const [currentNode, setCurrentNode] = useState("A");
  return (
    <NodeList
      currentNode={currentNode}
      nodeList={["A", "B", "C"]}
      nodeProtocols={{}}
      showProtocol={false}
      isRunning
      subscriptionNames={{}}
      urlTestRequest={0}
      onUrlTestStateChange={() => undefined}
      onUpdate={(node) => {
        if (node) setCurrentNode(node);
      }}
    />
  );
}

function buttonFor(label: string): HTMLButtonElement {
  const button = Array.from(document.querySelectorAll("button")).find(
    (candidate) => candidate.textContent?.includes(label),
  );
  if (!button) throw new Error(`Missing node button: ${label}`);
  return button;
}

beforeEach(async () => {
  document.body.innerHTML = '<div id="root"></div>';
  root = createRoot(document.getElementById("root") as HTMLDivElement);
  vi.mocked(getStoreValue).mockResolvedValue(undefined);
  vi.mocked(setStoreValue).mockResolvedValue();
  vi.mocked(selectExitGatewayNode).mockImplementation((node: string) =>
    node === "C" ? Promise.reject(new Error("switch failed")) : Promise.resolve()
  );
  consoleError = vi.spyOn(console, "error").mockImplementation(() => undefined);
  await act(async () => root.render(<Harness />));
});

afterEach(async () => {
  await act(async () => root.unmount());
  consoleError.mockRestore();
  document.body.innerHTML = "";
  vi.clearAllMocks();
});

describe("NodeList selection queue", () => {
  it("rolls a failed rapid selection back to the last confirmed node", async () => {
    await act(async () => {
      buttonFor("B").click();
      buttonFor("C").click();
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(selectExitGatewayNode).toHaveBeenNthCalledWith(1, "C");
    expect(selectExitGatewayNode).toHaveBeenNthCalledWith(2, "A");
    expect(setStoreValue).not.toHaveBeenCalled();
    expect(buttonFor("A").getAttribute("aria-pressed")).toBe("true");
    expect(buttonFor("B").getAttribute("aria-pressed")).toBe("false");
    expect(buttonFor("C").getAttribute("aria-pressed")).toBe("false");
  });
});
