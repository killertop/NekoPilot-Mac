import { invoke } from "@tauri-apps/api/core";
import { message } from "@tauri-apps/plugin-dialog";
import { useCallback, useContext, useEffect, useRef, useState } from "react";
import { mutate as swrMutate } from "swr";
import {
  formatSubscriptionImportError,
  insertSubscription,
} from "../../action/db";
import { clearEngineError, useEngineState } from "../../hooks/useEngineState";
import { NavContext } from "../../single/context";
import { getProxyPort, setStoreValue } from "../../single/store";
import {
  GET_SUBSCRIPTIONS_LIST_SWR_KEY,
  SELECTED_NODE_STORE_KEY,
  SSI_STORE_KEY,
} from "../../types/definition";
import { t, vpnServiceManager } from "../../utils/helper";
import type { DeepLinkApplyPhase } from "./deep-link-apply-progress-modal";
import { NODE_SELECTOR_REFRESH_EVENT } from "./events";

// 类型定义
export type OperationStatus = "starting" | "stopping" | "idle";

/**
 * Root-level hook. Owns the apply-pipeline state (applyPhase /
 * applyErrorMessage), the deep-link consumer effect, the engine-transition
 * watcher, the 45 s backstop, and the engine-failed dialog handler.
 *
 * Call this ONCE at the App root so the progress modal can render at app
 * level and fire regardless of which page is currently visible — manual
 * add no longer needs to switch to Home to get the modal.
 */
export const useApplyPipelineRoot = () => {
  const engineState = useEngineState();
  const {
    deepLinkApplyUrl,
    setDeepLinkApplyUrl,
    deepLinkApplyName,
    setDeepLinkApplyName,
    deepLinkApplyAutoStart,
    setDeepLinkApplyAutoStart,
  } = useContext(NavContext);

  const [applyPhase, setApplyPhase] = useState<DeepLinkApplyPhase | null>(null);
  const [applyErrorMessage, setApplyErrorMessage] = useState<string>("");
  const [applyErrorTitle, setApplyErrorTitle] = useState<string>("");
  // Tracks which caller kind is driving the *current* modal run, so the
  // manual-add path can confirm selection instead of claiming it started
  // the service. Snapshotted when the URL is consumed
  // below, not derived live from NavContext (which resets to true after
  // consumption).
  const [manualMode, setManualMode] = useState<boolean>(false);
  // Epoch at the moment we enter the 'start' phase. Only engine transitions
  // past this epoch can close the modal — avoids a stale `running` snapshot
  // (e.g. the previous subscription) flipping us to 'done' prematurely.
  const applyEpochRef = useRef<number>(-1);
  // Every import gets a monotonically increasing run id. Native imports cannot
  // always be cancelled, but stale completions must never update the current
  // modal or start an older configuration.
  const applyRunRef = useRef(0);

  // 失败状态: 弹窗提示并回到 Idle, 避免前端永久卡在 failed。
  // Suppressed while the apply modal is live — the modal surfaces the error
  // instead, to avoid a double prompt.
  useEffect(() => {
    if (engineState.kind !== "failed") return;
    if (applyPhase !== null) return;
    const reason = engineState.reason;
    (async () => {
      await message(`${t("connect_failed")}: ${reason}`, {
        title: t("error"),
        kind: "error",
      });
      await clearEngineError();
    })();
  }, [engineState.kind === "failed" ? engineState.epoch : null, applyPhase]);

  // Drive apply modal to 'done' / 'error' based on engine transitions that
  // happen after we issued the start command.
  useEffect(() => {
    if (applyPhase !== "start") return;
    if (engineState.epoch <= applyEpochRef.current) return;
    if (engineState.kind === "running") {
      setApplyPhase("done");
    } else if (engineState.kind === "failed") {
      setApplyErrorMessage(engineState.reason || t("connect_failed"));
      setApplyPhase("error");
      clearEngineError().catch(() => {});
    }
  }, [applyPhase, engineState.kind, engineState.epoch]);

  // Backstop timeout: if the engine never transitions (silent IPC failure or
  // indefinite connect attempt), flip to error after 45s so the modal never
  // wedges.
  useEffect(() => {
    if (applyPhase !== "start") return;
    const timer = setTimeout(() => {
      setApplyErrorMessage(t("connect_failed"));
      setApplyPhase("error");
    }, 45000);
    return () => clearTimeout(timer);
  }, [applyPhase]);

  // Auto-dismiss every successful apply after briefly showing confirmation.
  // This covers both apply=1 and manual imports: manual imports already make
  // the new subscription current, so keeping a second Close action adds no
  // value and leaves the underlying configuration page unnecessarily blocked.
  useEffect(() => {
    if (applyPhase !== "done") return;
    const timer = setTimeout(() => {
      applyRunRef.current += 1;
      setApplyPhase(null);
      setApplyErrorMessage("");
      setApplyErrorTitle("");
    }, 1000);
    return () => clearTimeout(timer);
  }, [applyPhase]);

  // Apply pipeline. Shared between two callers:
  //   1. Deep-link apply=1 (App.tsx on_open_url handler): autoStart=true
  //      (the default) — import, select, stop-then-start the engine.
  //   2. Manual add (configuration modal submit): autoStart=false —
  //      import and make the new configuration current, but do not touch
  //      the engine. Same modal UI, no page switch.
  useEffect(() => {
    if (!deepLinkApplyUrl) return;
    const runId = ++applyRunRef.current;
    const isCurrentRun = () => applyRunRef.current === runId;
    const url = deepLinkApplyUrl;
    const name = deepLinkApplyName;
    const autoStart = deepLinkApplyAutoStart;
    setDeepLinkApplyUrl("");
    setDeepLinkApplyName("");
    // Reset the flag so the next fire — whatever origin — defaults
    // back to the apply=1 contract unless the caller opts out again.
    setDeepLinkApplyAutoStart(true);
    setManualMode(!autoStart);

    setApplyErrorMessage("");
    setApplyErrorTitle("");
    setApplyPhase("init");

    (async () => {
      // Brief 'init' dwell so the modal can render its entrance animation
      // before the first real work starts.
      await new Promise((r) => setTimeout(r, 350));
      if (!isCurrentRun()) return;
      setApplyPhase("import");

      try {
        const id = await insertSubscription(url, name || undefined);
        if (!isCurrentRun()) return;
        if (autoStart) {
          await Promise.all([
            setStoreValue(SSI_STORE_KEY, id),
            setStoreValue(SELECTED_NODE_STORE_KEY, ""),
            swrMutate(GET_SUBSCRIPTIONS_LIST_SWR_KEY),
            vpnServiceManager.stop().catch(() => {}),
          ]);
        } else {
          // A user explicitly chose this link, so it should become the
          // current node source immediately. When already connected, rebuild
          // the unified pool with a live reload so its nodes appear without a
          // disconnect/reconnect cycle.
          await Promise.all([
            setStoreValue(SSI_STORE_KEY, id),
            setStoreValue(SELECTED_NODE_STORE_KEY, ""),
            swrMutate(GET_SUBSCRIPTIONS_LIST_SWR_KEY),
          ]);
          if (engineState.kind === "running") {
            await vpnServiceManager.syncAndReload(0);
            window.dispatchEvent(new Event(NODE_SELECTOR_REFRESH_EVENT));
          }
        }
      } catch (error) {
        if (!isCurrentRun()) return;
        setApplyErrorTitle(t("import_failed"));
        setApplyErrorMessage(formatSubscriptionImportError(error));
        setApplyPhase("error");
        return;
      }

      if (!isCurrentRun()) return;
      if (!autoStart) {
        // Manual-add path: import finished, engine untouched.
        // Jump straight to 'done' — modal shows success chip + close
        // button. Step 3 ("启动服务") marks green as a side effect of
        // isDone=true; accepted trade-off to keep the modal UI
        // identical to apply=1 per design.
        setApplyPhase("done");
        return;
      }

      // Snapshot the current engine epoch; only transitions past this
      // epoch count for the apply-modal 'done' check.
      applyEpochRef.current = engineState.epoch;
      setApplyPhase("start");

      void vpnServiceManager.syncConfig({
        onSuccess: async () => {
          if (!isCurrentRun()) return;
          try {
            await vpnServiceManager.start();
          } catch (error: any) {
            console.error("启动服务失败:", error);
            // syncConfig owns the error handoff for this pipeline. Without
            // rethrowing, a synchronous start failure would leave the modal
            // waiting for its 45-second backstop instead of showing the error.
            throw error;
          }
        },
        onError: async (error) => {
          if (!isCurrentRun()) return;
          setApplyErrorMessage(
            typeof error === "string" && error ? error : t("connect_failed"),
          );
          setApplyPhase("error");
        },
      });
    })();
  }, [deepLinkApplyUrl, engineState.kind]);

  const closeApplyModal = () => {
    applyRunRef.current += 1;
    setApplyPhase(null);
    setApplyErrorMessage("");
    setApplyErrorTitle("");
  };

  // Manual-add renders the same progress shell but never starts the engine.
  // The final step confirms that the imported configuration is selected and
  // tells the user exactly where to connect.
  const stepLabels = manualMode
    ? {
      start: t("dl_phase_start_manual"),
      done: t("dl_phase_done_manual"),
    }
    : undefined;

  return {
    applyPhase,
    applyErrorMessage,
    applyErrorTitle,
    closeApplyModal,
    stepLabels,
  };
};

/**
 * 自定义Hook: 管理VPN服务操作状态
 *
 * Plan B 后:权威状态来自 Rust 的 `engine-state` 事件(经由 `EngineStateContext`),
 * 本 hook 只剩下 UI 操作入口与派生的 isLoading/isRunning/operationStatus。
 * 应用流水线状态已上移到 `useApplyPipelineRoot`。
 */
export const useVPNOperations = () => {
  const engineState = useEngineState();
  const { setActiveScreen } = useContext(NavContext);
  // Config compilation happens before the native engine emits `starting`.
  // Keep that preparation phase visible and coalesce repeated Connect presses
  // so two independent start sequences can never race into core::start.
  const [isPreparingStart, setIsPreparingStart] = useState(false);
  const startInFlightRef = useRef(false);

  // 从权威状态派生出兼容变量
  const isRunning = engineState.kind === "running";
  const isLoading = isPreparingStart || engineState.kind === "starting" ||
    engineState.kind === "stopping";
  const operationStatus: OperationStatus =
    isPreparingStart || engineState.kind === "starting"
      ? "starting"
      : engineState.kind === "stopping"
      ? "stopping"
      : "idle";

  // Repair modal state: visible + orphan pids found by prestart_check
  const [repairState, setRepairState] = useState<
    { visible: boolean; orphanPids: number[] }
  >({
    visible: false,
    orphanPids: [],
  });

  // Pending start callback: called by onRepairSuccess to resume the start sequence
  const pendingStartRef = useRef<(() => void) | null>(null);

  const stopService = useCallback(async () => {
    try {
      await vpnServiceManager.stop();
    } catch (error) {
      console.error("停止服务失败:", error);
    }
  }, []);

  const performSyncAndStart = useCallback(
    async (onSyncError: (error: any) => Promise<void>) => {
      if (startInFlightRef.current) return;
      startInFlightRef.current = true;
      setIsPreparingStart(true);
      try {
        await vpnServiceManager.syncConfig({
          onSuccess: async () => {
            try {
              await vpnServiceManager.start();
            } catch (error: any) {
              console.error("启动服务失败:", error);
              // Let syncConfig route the failure to its single error path.
              throw error;
            }
          },
          onError: async (error) => {
            await onSyncError(error);
          },
        });
      } finally {
        startInFlightRef.current = false;
        setIsPreparingStart(false);
      }
    },
    [],
  );

  const startService = useCallback(async (isEmpty: boolean) => {
    if (isEmpty) {
      setActiveScreen("configuration");
      return message(t("please_add_subscription"), {
        title: t("tips"),
        kind: "error",
      });
    }

    // Pre-start check: if port is occupied by orphan processes, show repair modal
    const proxyPort = await getProxyPort();
    const check = await invoke<
      { port_occupied: boolean; orphan_pids: number[]; foreign_pids: number[] }
    >("prestart_check", { port: proxyPort });
    if (check.port_occupied && check.foreign_pids.length > 0) {
      return message(
        t(
          "port_occupied_by_other_app",
          { port: proxyPort },
          "Port {{port}} is used by another application. NekoPilot will not stop it.",
        ),
        { title: t("error"), kind: "error" },
      );
    }
    if (check.port_occupied && check.orphan_pids.length > 0) {
      // Store what we would do after repair, then show the modal
      pendingStartRef.current = () => {
        void performSyncAndStart(async (error) => {
          console.error("同步配置失败:", error);
          if (error?.message === "subscription_config_missing") {
            await message(t("subscription_config_missing"), {
              title: t("error"),
              kind: "error",
            });
          }
          if (error?.message === "subscription_no_usable_nodes") {
            await message(
              t(
                "subscription_no_usable_nodes",
                "The subscription has no usable nodes.",
              ),
              {
                title: t("error"),
                kind: "error",
              },
            );
            return;
          }
        });
      };
      setRepairState({ visible: true, orphanPids: check.orphan_pids });
      return;
    }

    await performSyncAndStart(async (error) => {
      console.error("同步配置失败:", error);
      if (error?.message === "subscription_config_missing") {
        await message(t("subscription_config_missing"), {
          title: t("error"),
          kind: "error",
        });
      }
      if (error?.message === "subscription_no_usable_nodes") {
        await message(
          t(
            "subscription_no_usable_nodes",
            "The subscription has no usable nodes.",
          ),
          {
            title: t("error"),
            kind: "error",
          },
        );
        return;
      }
    });
  }, [performSyncAndStart, setActiveScreen]);

  const onRepairSuccess = useCallback(() => {
    setRepairState({ visible: false, orphanPids: [] });
    const pending = pendingStartRef.current;
    pendingStartRef.current = null;
    pending?.();
  }, []);

  const onRepairClose = useCallback(() => {
    setRepairState({ visible: false, orphanPids: [] });
    pendingStartRef.current = null;
  }, []);

  const toggleService = useCallback(async (isEmpty: boolean) => {
    if (isEmpty) {
      setActiveScreen("configuration");
      return message(t("please_add_subscription"), {
        title: t("tips"),
        kind: "error",
      });
    }

    try {
      if (isRunning) {
        await stopService();
      } else {
        await startService(isEmpty);
      }
    } catch (error) {
      console.error("连接失败:", error);
      await message(`${t("connect_failed")}: ${error}`, {
        title: t("error"),
        kind: "error",
      });
    }
  }, [isRunning, setActiveScreen, startService, stopService]);

  return {
    operationStatus,
    isLoading,
    isRunning,
    startService,
    toggleService,
    repairState,
    onRepairSuccess,
    onRepairClose,
  };
};
