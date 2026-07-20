import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const css = readFileSync(new URL("../App.css", import.meta.url), "utf8");

function tokens(block: string): string[] {
  return [...block.matchAll(/(--onebox-[\w-]+)\s*:/g)]
    .map((match) => match[1])
    .sort();
}

describe("UI theme contract", () => {
  it("defines the same semantic tokens for light and system dark themes", () => {
    const themeCss = css.slice(css.indexOf("Theme tokens."));
    const light = themeCss.match(/:root\s*\{([\s\S]*?)\}/)?.[1];
    const dark = css.match(
      /@media\s*\(prefers-color-scheme:\s*dark\)[\s\S]*?:root\[data-theme="system"\]\s*\{([\s\S]*?)\}/,
    )?.[1];
    expect(light).toBeTruthy();
    expect(dark).toBeTruthy();
    expect(tokens(dark ?? "")).toEqual(tokens(light ?? ""));
  });

  it("does not reintroduce a manual dark-theme branch", () => {
    expect(css).not.toMatch(/:root\[data-theme=["']dark["']\]/);
  });
});
