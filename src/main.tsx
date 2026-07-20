import { getCurrentWindow } from "@tauri-apps/api/window";
import React from "react";
import ReactDOM from "react-dom/client";
import {
  setupStatusListener,
  setupTauriLogListener,
  setupTrayIcon,
} from "./tray";
import { scheduleGitHubReleaseUpdateCheck } from "./utils/github-release-update";
import WindowManger from "./window-manger";

const appWindow = getCurrentWindow();

if (appWindow.label === "main") {
  void setupTrayIcon().catch((error) => {
    console.error("Failed to initialize tray icon:", error);
  });
  void setupStatusListener().catch((error) => {
    console.error("Failed to initialize engine status listener:", error);
  });
  void setupTauriLogListener().catch((error) => {
    console.error("Failed to initialize native log listener:", error);
  });
  scheduleGitHubReleaseUpdateCheck();
}

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>
    <WindowManger />
  </React.StrictMode>,
);
