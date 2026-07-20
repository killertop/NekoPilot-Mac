import { useEffect, useRef } from "react";
import {
  OperationProgressDialog,
  type ProgressStep,
  resolveProgressStepState,
} from "../common/operation-progress-dialog";
import { t } from "../../utils/helper";

export type DeepLinkApplyPhase = "init" | "import" | "start" | "done" | "error";

export interface DeepLinkApplyProgressModalProps {
  visible: boolean;
  phase: DeepLinkApplyPhase;
  errorMessage?: string;
  errorTitle?: string;
  onClose?: () => void;
  stepLabels?: Partial<Record<"init" | "import" | "start" | "done", string>>;
}

type StepKey = "init" | "import" | "start";
const STEP_KEYS: readonly StepKey[] = ["init", "import", "start"];

function phaseToIndex(phase: DeepLinkApplyPhase): number {
  switch (phase) {
    case "init":
      return 0;
    case "import":
      return 1;
    case "start":
      return 2;
    case "done":
      return STEP_KEYS.length;
    default:
      return -1;
  }
}

export function DeepLinkApplyProgressModal({
  visible,
  phase,
  errorMessage,
  errorTitle,
  onClose,
  stepLabels,
}: DeepLinkApplyProgressModalProps) {
  const lastRunningIndex = useRef(0);
  useEffect(() => {
    const index = phaseToIndex(phase);
    if (index >= 0 && index < STEP_KEYS.length) {
      lastRunningIndex.current = index;
    }
  }, [phase]);

  const error = phase === "error";
  const done = phase === "done";
  const running = !error && !done;
  const activeIndex = error ? lastRunningIndex.current : phaseToIndex(phase);
  const labelFor = (key: StepKey | "done") =>
    stepLabels?.[key] ?? t(`dl_phase_${key}`);
  const steps: ProgressStep[] = STEP_KEYS.map((key, index) => ({
    key,
    label: labelFor(key),
    state: resolveProgressStepState(index, activeIndex, done, error),
    railFillPercent: done
      ? 1
      : error
      ? (index < activeIndex ? 1 : 0)
      : index < activeIndex
      ? 1
      : index === activeIndex
      ? 0.5
      : 0,
  }));

  const title = error
    ? (errorTitle || t("connect_failed", "Connection failed"))
    : done
    ? labelFor("done")
    : t("dl_phase_title", "Applying configuration");

  return (
    <OperationProgressDialog
      open={visible}
      title={title}
      titleId="deep-link-apply-title"
      steps={steps}
      running={running}
      terminalState={error ? "error" : done ? "success" : undefined}
      message={errorMessage}
      onClose={onClose}
    />
  );
}

export default DeepLinkApplyProgressModal;
