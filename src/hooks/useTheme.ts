import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { useEffect } from "react";

function applySystemTheme(): void {
  document.documentElement.dataset.theme = "system";

  void getCurrentWindow().setTheme(null).catch((error) => {
    console.warn("[theme] window.setTheme(system) failed:", error);
  });
  void invoke("set_native_window_theme", { theme: null }).catch((error) => {
    console.warn("[theme] set_native_window_theme(system) failed:", error);
  });
}

// Keep web content and native title-bar chrome tied to macOS. There is no
// app-level appearance preference: any saved explicit theme is removed by
// cleanupRemovedDeveloperSettings during startup.
document.documentElement.dataset.theme = "system";

export function useTheme() {
  useEffect(() => {
    const mediaQuery = window.matchMedia("(prefers-color-scheme: dark)");
    const handleSystemThemeChange = () => applySystemTheme();

    applySystemTheme();
    mediaQuery.addEventListener("change", handleSystemThemeChange);
    return () => mediaQuery.removeEventListener("change", handleSystemThemeChange);
  }, []);
}
