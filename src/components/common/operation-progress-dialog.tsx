import { AnimatePresence, motion } from "framer-motion";
import { type ReactNode, useEffect, useRef } from "react";
import { CheckCircleFill, XCircleFill } from "react-bootstrap-icons";
import { t } from "../../utils/helper";
import { AppDialog } from "./app-dialog";

export type ProgressStepState = "idle" | "active" | "done" | "error";

export interface ProgressStep {
  key: string;
  label: string;
  state: ProgressStepState;
  railFillPercent: number;
}

interface OperationProgressDialogProps {
  open: boolean;
  title: string;
  titleId: string;
  steps: ProgressStep[];
  running: boolean;
  terminalState?: "success" | "error";
  message?: string;
  beforeSteps?: ReactNode;
  onClose?: () => void;
  closeTone?: "accent" | "danger";
}

const STEP_ROW_HEIGHT_PX = 38;
const CIRCLE_SIZE_PX = 20;
const RAIL_SEGMENT_PX = STEP_ROW_HEIGHT_PX - CIRCLE_SIZE_PX;

export function resolveProgressStepState(
  index: number,
  activeIndex: number,
  done: boolean,
  error: boolean,
): ProgressStepState {
  if (done) return "done";
  if (error) {
    if (index < activeIndex) return "done";
    if (index === activeIndex) return "error";
    return "idle";
  }
  if (index < activeIndex) return "done";
  if (index === activeIndex) return "active";
  return "idle";
}

function StepCircle({ state }: { state: ProgressStepState }) {
  if (state === "done") {
    return (
      <CheckCircleFill
        size={CIRCLE_SIZE_PX}
        style={{ color: "var(--onebox-blue)" }}
        aria-hidden="true"
      />
    );
  }
  if (state === "error") {
    return (
      <XCircleFill
        size={CIRCLE_SIZE_PX}
        style={{ color: "var(--onebox-red)" }}
        aria-hidden="true"
      />
    );
  }
  if (state === "active") {
    return (
      <motion.div
        className="relative"
        aria-hidden="true"
        style={{ width: CIRCLE_SIZE_PX, height: CIRCLE_SIZE_PX }}
        animate={{ opacity: [0.7, 1, 0.7] }}
        transition={{ duration: 1.8, repeat: Infinity, ease: "easeInOut" }}
      >
        <div className="absolute inset-0 rounded-full bg-[var(--onebox-blue)]" />
        <div
          className="absolute size-2 rounded-full bg-[var(--onebox-on-accent)]"
          style={{
            top: "50%",
            left: "50%",
            transform: "translate(-50%, -50%)",
          }}
        />
      </motion.div>
    );
  }
  return (
    <div
      className="rounded-full bg-[var(--onebox-card)]"
      aria-hidden="true"
      style={{
        width: CIRCLE_SIZE_PX,
        height: CIRCLE_SIZE_PX,
        boxShadow: "inset 0 0 0 1.5px var(--onebox-separator)",
      }}
    />
  );
}

function StepRow({ step, isLast }: { step: ProgressStep; isLast: boolean }) {
  const labelColor = step.state === "error"
    ? "var(--onebox-red)"
    : step.state === "active"
    ? "var(--onebox-label)"
    : step.state === "done"
    ? "var(--onebox-label-secondary)"
    : "var(--onebox-label-tertiary)";

  return (
    <li
      className="relative flex items-center gap-3 list-none"
      style={{ height: STEP_ROW_HEIGHT_PX }}
    >
      <div
        className="relative z-10 flex items-center justify-center shrink-0"
        style={{ width: CIRCLE_SIZE_PX, height: CIRCLE_SIZE_PX }}
      >
        <StepCircle state={step.state} />
        {!isLast && (
          <>
            <div
              className="absolute top-full left-1/2 -translate-x-1/2 bg-[var(--onebox-separator)]"
              style={{ width: 1.5, height: RAIL_SEGMENT_PX }}
              aria-hidden="true"
            />
            <motion.div
              className="absolute top-full left-1/2 -translate-x-1/2 bg-[var(--onebox-blue)]"
              style={{ width: 1.5 }}
              initial={false}
              animate={{ height: RAIL_SEGMENT_PX * step.railFillPercent }}
              transition={{ duration: 0.4, ease: "easeOut" }}
              aria-hidden="true"
            />
          </>
        )}
      </div>
      <span
        className="text-[14px] tracking-[-0.005em]"
        style={{
          color: labelColor,
          fontWeight: step.state === "active" ? 500 : 400,
        }}
      >
        {step.label}
      </span>
    </li>
  );
}

function LivenessDots() {
  return (
    <div
      className="flex items-center gap-1"
      role="status"
      aria-label={t("loading")}
    >
      {[0, 1, 2].map((index) => (
        <motion.span
          key={index}
          className="block size-1 rounded-full bg-[var(--onebox-label-tertiary)]"
          animate={{ opacity: [0.3, 1, 0.3] }}
          transition={{
            duration: 1.4,
            repeat: Infinity,
            delay: index * 0.18,
            ease: "easeInOut",
          }}
        />
      ))}
    </div>
  );
}

export function OperationProgressDialog({
  open,
  title,
  titleId,
  steps,
  running,
  terminalState,
  message,
  beforeSteps,
  onClose,
  closeTone = "accent",
}: OperationProgressDialogProps) {
  const terminal = terminalState !== undefined;
  const canClose = Boolean(onClose);
  const closeButtonRef = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    if (open && terminal && canClose) {
      closeButtonRef.current?.focus({ preventScroll: true });
    }
  }, [canClose, open, terminal]);
  const liveStep =
    steps.find((step) => step.state === "active" || step.state === "error") ??
      steps[steps.length - 1];
  return (
    <AppDialog
      open={open}
      onClose={running ? undefined : onClose}
      dismissOnBackdrop={false}
      closeOnEscape={!running}
      labelledBy={titleId}
      surface="compact"
      busy={running}
      panelMotion={{
        initial: { scale: 0.92, y: 8 },
        animate: { scale: 1, y: 0 },
        exit: { scale: 0.94, y: 4 },
        transition: { duration: 0.22, ease: [0.32, 0.72, 0, 1] },
      }}
    >
      <div className="pt-5 px-5 pb-4">
        {terminal && (
          <div
            className="size-11 rounded-xl flex items-center justify-center mx-auto mb-3"
            style={{
              background: terminalState === "error"
                ? "var(--onebox-red-fill)"
                : "var(--onebox-green-fill)",
            }}
          >
            {terminalState === "error"
              ? (
                <XCircleFill
                  size={22}
                  style={{ color: "var(--onebox-red)" }}
                  aria-hidden="true"
                />
              )
              : (
                <CheckCircleFill
                  size={22}
                  style={{ color: "var(--onebox-green)" }}
                  aria-hidden="true"
                />
              )}
          </div>
        )}

        <h3
          id={titleId}
          className="text-[16px] font-semibold text-center tracking-[-0.01em] mb-4"
          style={{ color: "var(--onebox-label)" }}
        >
          {title}
        </h3>

        <p className="sr-only" aria-live="polite">
          {liveStep ? `${title}. ${liveStep.label}` : title}
        </p>

        {beforeSteps}

        <ol className="relative m-0 p-0 pl-1">
          {steps.map((step, index) => (
            <StepRow
              key={step.key}
              step={step}
              isLast={index === steps.length - 1}
            />
          ))}
        </ol>

        <AnimatePresence>
          {terminalState === "error" && message && (
            <motion.div
              key="operation-error"
              className="mt-3 rounded-xl px-3 py-2 text-[12px] leading-snug"
              style={{
                background: "var(--onebox-red-fill-subtle)",
                color: "var(--onebox-red)",
              }}
              role="alert"
              initial={{ opacity: 0, y: -4 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0 }}
            >
              {message}
            </motion.div>
          )}
        </AnimatePresence>
      </div>

      {running
        ? (
          <div className="flex items-center justify-center py-4">
            <LivenessDots />
          </div>
        )
        : onClose
        ? (
          <button
            ref={closeButtonRef}
            type="button"
            className="w-full h-11 text-[14px] font-semibold transition-colors active:bg-[var(--onebox-row-active)]"
            style={{
              color: closeTone === "danger"
                ? "var(--onebox-red)"
                : "var(--onebox-blue)",
              borderTop: "0.5px solid var(--onebox-separator)",
            }}
            onClick={onClose}
          >
            {t("close", "Close")}
          </button>
        )
        : null}
    </AppDialog>
  );
}
