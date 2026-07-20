import { invoke } from "@tauri-apps/api/core";
import { useEffect, useRef, useState } from "react";
import { getProxyPort } from "../../single/store";
import { t } from "../../utils/helper";
import {
  OperationProgressDialog,
  type ProgressStep,
  resolveProgressStepState,
} from "../common/operation-progress-dialog";

export interface PrestartRepairModalProps {
  visible: boolean;
  orphanPids: number[];
  onSuccess: () => void;
  onClose: () => void;
}

type RepairPhase = "detecting" | "killing" | "verifying" | "success" | "failed";
const PHASE_STEPS: readonly RepairPhase[] = [
  "detecting",
  "killing",
  "verifying",
];

function phaseToIndex(phase: RepairPhase): number {
  switch (phase) {
    case "detecting":
      return 0;
    case "killing":
      return 1;
    case "verifying":
      return 2;
    case "success":
      return PHASE_STEPS.length;
    default:
      return -1;
  }
}

export function PrestartRepairModal({
  visible,
  orphanPids,
  onSuccess,
  onClose,
}: PrestartRepairModalProps) {
  const [phase, setPhase] = useState<RepairPhase>("detecting");
  const hasRun = useRef(false);
  const onSuccessRef = useRef(onSuccess);
  onSuccessRef.current = onSuccess;

  useEffect(() => {
    if (!visible) {
      hasRun.current = false;
      setPhase("detecting");
      return;
    }
    if (hasRun.current) return;
    hasRun.current = true;
    let cancelled = false;

    void (async () => {
      await new Promise((resolve) => setTimeout(resolve, 600));
      if (cancelled) return;
      setPhase("killing");
      try {
        const port = await getProxyPort();
        const result = await invoke<
          { success: boolean; port_released: boolean }
        >(
          "kill_orphans",
          { port },
        );
        if (cancelled) return;
        setPhase("verifying");
        await new Promise((resolve) => setTimeout(resolve, 800));
        if (cancelled) return;
        if (result.success && result.port_released) {
          setPhase("success");
          await new Promise((resolve) => setTimeout(resolve, 800));
          if (!cancelled) onSuccessRef.current();
        } else {
          setPhase("failed");
        }
      } catch {
        if (!cancelled) setPhase("failed");
      }
    })();
    return () => {
      cancelled = true;
      hasRun.current = false;
    };
  }, [visible]);

  const success = phase === "success";
  const failed = phase === "failed";
  const running = !success && !failed;
  const lastRunningIndex = useRef(0);
  useEffect(() => {
    const index = phaseToIndex(phase);
    if (index >= 0 && index < PHASE_STEPS.length) {
      lastRunningIndex.current = index;
    }
  }, [phase]);
  const activeIndex = failed ? lastRunningIndex.current : phaseToIndex(phase);
  const steps: ProgressStep[] = PHASE_STEPS.map((step, index) => ({
    key: step,
    label: t(`prestart_${step}`, step),
    state: resolveProgressStepState(index, activeIndex, success, failed),
    railFillPercent: success
      ? 1
      : failed
      ? (index < activeIndex ? 1 : 0)
      : index < activeIndex
      ? 1
      : index === activeIndex
      ? 0.5
      : 0,
  }));

  const title = failed
    ? t("prestart_failed", "Repair failed, please restart your computer")
    : success
    ? t("prestart_success", "Repaired, starting service")
    : t("prestart_repair_title", "Clean Up Orphan Processes");

  const pidList = orphanPids.length > 0 && running
    ? (
      <div className="flex flex-wrap gap-1.5 mb-4">
        {orphanPids.map((pid) => (
          <span
            key={pid}
            className="text-[11px] px-2 py-0.5 rounded-full"
            style={{
              background: "var(--onebox-card-muted)",
              color: "var(--onebox-label-secondary)",
            }}
          >
            {t("prestart_pid_label", "Orphan process")} {pid}
          </span>
        ))}
      </div>
    )
    : undefined;

  return (
    <OperationProgressDialog
      open={visible}
      title={title}
      titleId="prestart-repair-title"
      steps={steps}
      running={running}
      terminalState={failed ? "error" : success ? "success" : undefined}
      beforeSteps={pidList}
      onClose={success ? onSuccess : onClose}
      closeTone={failed ? "danger" : "accent"}
    />
  );
}
