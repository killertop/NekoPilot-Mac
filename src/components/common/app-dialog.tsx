import clsx from "clsx";
import {
  AnimatePresence,
  motion,
  type TargetAndTransition,
  type Transition,
  type VariantLabels,
} from "framer-motion";
import {
  type CSSProperties,
  type ReactNode,
  type RefObject,
  useLayoutEffect,
  useRef,
  useState,
} from "react";
import { Portal, useBodyScrollLock } from "./portal";

type MotionTarget = TargetAndTransition | VariantLabels;

export interface DialogMotion {
  initial: MotionTarget;
  animate: MotionTarget;
  exit: MotionTarget;
  transition: Transition;
}

export const ALERT_DIALOG_MOTION: DialogMotion = {
  initial: { scale: 0.94, y: 8 },
  animate: { scale: 1, y: 0 },
  exit: { scale: 0.96, y: 4 },
  transition: { duration: 0.22, ease: [0.32, 0.72, 0, 1] },
};

export const SHEET_DIALOG_MOTION: DialogMotion = {
  initial: { y: 24, opacity: 0, scale: 0.96 },
  animate: { y: 0, opacity: 1, scale: 1 },
  exit: { y: 12, opacity: 0, scale: 0.98 },
  transition: { duration: 0.26, ease: [0.32, 0.72, 0, 1] },
};

export const BOTTOM_SHEET_MOTION: DialogMotion = {
  initial: { y: "100%" },
  animate: { y: 0 },
  exit: { y: "100%" },
  transition: { type: "spring", damping: 30, stiffness: 320 },
};

const FOCUSABLE_SELECTOR = [
  "button:not([disabled]):not([tabindex='-1'])",
  "[href]:not([tabindex='-1'])",
  "input:not([disabled]):not([tabindex='-1'])",
  "select:not([disabled]):not([tabindex='-1'])",
  "textarea:not([disabled]):not([tabindex='-1'])",
  "[tabindex]:not([tabindex='-1'])",
].join(",");

interface DialogStackEntry {
  id: symbol;
  panel: HTMLElement;
}

const dialogStack: DialogStackEntry[] = [];
let nextDialogLayer = 100;

function topDialog() {
  return dialogStack[dialogStack.length - 1];
}

function syncDialogStack() {
  const lastIndex = dialogStack.length - 1;
  dialogStack.forEach((entry, index) => {
    const covered = index !== lastIndex;
    entry.panel.inert = covered;
    if (covered) entry.panel.setAttribute("aria-hidden", "true");
    else entry.panel.removeAttribute("aria-hidden");
  });

  // Keep global live regions (for example Sonner toasts) available while a
  // dialog is open. Only the interactive app shell belongs in the inert
  // subtree; `#root` is a fallback for isolated tests and legacy mounts.
  const appRoot = document.getElementById("onebox-app-main") ??
    document.getElementById("root");
  if (!appRoot) return;
  const covered = dialogStack.length > 0;
  appRoot.inert = covered;
  if (covered) appRoot.setAttribute("aria-hidden", "true");
  else appRoot.removeAttribute("aria-hidden");
}

function focusableElements(panel: HTMLElement): HTMLElement[] {
  return Array.from(panel.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR))
    .filter((element) => {
      if (
        element.hidden ||
        element.closest("[hidden], [inert], [aria-hidden='true']")
      ) {
        return false;
      }
      const style = window.getComputedStyle(element);
      return style.display !== "none" && style.visibility !== "hidden";
    });
}

export type DialogSurface =
  | "compact"
  | "regular"
  | "detail"
  | "sheet"
  | "custom";
export type DialogPlacement = "center" | "bottom";

const SURFACE_CLASS: Record<DialogSurface, string> = {
  compact: "w-full max-w-[290px] rounded-[14px] overflow-hidden",
  regular: "w-full max-w-[320px] rounded-[14px] overflow-hidden",
  detail: "w-full max-w-[340px] rounded-[18px] overflow-hidden",
  sheet: "w-full max-w-[480px] rounded-t-[16px] overflow-hidden",
  custom: "",
};

interface AppDialogProps {
  open: boolean;
  children: ReactNode;
  ariaLabel?: string;
  labelledBy?: string;
  describedBy?: string;
  onClose?: () => void;
  dismissOnBackdrop?: boolean;
  closeOnEscape?: boolean;
  initialFocusRef?: RefObject<HTMLElement | null>;
  containerClassName?: string;
  panelClassName?: string;
  panelStyle?: CSSProperties;
  panelMotion?: DialogMotion;
  placement?: DialogPlacement;
  surface?: DialogSurface;
  busy?: boolean;
}

/**
 * Shared modal foundation for every app dialog and sheet.
 *
 * The focus stack, backdrop, scroll lock, animation and visual layer share
 * one lifecycle. Only the top dialog handles Escape and Tab; closing keeps
 * the background inert until the exit animation has actually finished.
 */
export function AppDialog({
  open,
  children,
  ariaLabel,
  labelledBy,
  describedBy,
  onClose,
  dismissOnBackdrop = true,
  closeOnEscape = true,
  initialFocusRef,
  containerClassName,
  panelClassName,
  panelStyle,
  panelMotion = ALERT_DIALOG_MOTION,
  placement = "center",
  surface = "regular",
  busy = false,
}: AppDialogProps) {
  const panelRef = useRef<HTMLDivElement>(null);
  const dialogId = useRef(Symbol("app-dialog"));
  const [present, setPresent] = useState(open);
  const [layer, setLayer] = useState(100);
  const openRef = useRef(open);
  const onCloseRef = useRef(onClose);
  const dismissOnBackdropRef = useRef(dismissOnBackdrop);
  const closeOnEscapeRef = useRef(closeOnEscape);
  const initialFocusRefRef = useRef(initialFocusRef);

  openRef.current = open;
  onCloseRef.current = onClose;
  dismissOnBackdropRef.current = dismissOnBackdrop;
  closeOnEscapeRef.current = closeOnEscape;
  initialFocusRefRef.current = initialFocusRef;

  useLayoutEffect(() => {
    if (open) setPresent(true);
  }, [open]);
  useBodyScrollLock(present);

  useLayoutEffect(() => {
    if (!present || !panelRef.current) return;

    const id = dialogId.current;
    const panel = panelRef.current;
    const previouslyFocused = document.activeElement instanceof HTMLElement
      ? document.activeElement
      : null;
    const assignedLayer = nextDialogLayer;
    nextDialogLayer += 1;
    setLayer(assignedLayer);
    dialogStack.push({ id, panel });

    const focusTarget = initialFocusRefRef.current?.current ??
      panel.querySelector<HTMLElement>(
        "[data-autofocus='true'], [autofocus]",
      ) ??
      focusableElements(panel)[0] ??
      panel;
    focusTarget.focus({ preventScroll: true });
    syncDialogStack();

    const requestClose = () => {
      if (!openRef.current) return;
      onCloseRef.current?.();
    };

    const handleKeyDown = (event: KeyboardEvent) => {
      if (topDialog()?.id !== id) return;

      if (
        event.key === "Escape" &&
        !event.isComposing &&
        closeOnEscapeRef.current &&
        onCloseRef.current
      ) {
        event.preventDefault();
        event.stopPropagation();
        requestClose();
        return;
      }

      if (event.key !== "Tab") return;
      const focusable = focusableElements(panel);
      if (focusable.length === 0) {
        event.preventDefault();
        panel.focus({ preventScroll: true });
        return;
      }

      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      const active = document.activeElement;
      if (event.shiftKey && (active === first || !panel.contains(active))) {
        event.preventDefault();
        last.focus({ preventScroll: true });
      } else if (
        !event.shiftKey && (active === last || !panel.contains(active))
      ) {
        event.preventDefault();
        first.focus({ preventScroll: true });
      }
    };

    const handleFocusIn = (event: FocusEvent) => {
      if (topDialog()?.id !== id || panel.contains(event.target as Node)) {
        return;
      }
      const target = focusableElements(panel)[0] ?? panel;
      target.focus({ preventScroll: true });
    };

    document.addEventListener("keydown", handleKeyDown, true);
    document.addEventListener("focusin", handleFocusIn, true);
    return () => {
      document.removeEventListener("keydown", handleKeyDown, true);
      document.removeEventListener("focusin", handleFocusIn, true);
      const index = dialogStack.findIndex((entry) => entry.id === id);
      if (index >= 0) dialogStack.splice(index, 1);
      syncDialogStack();
      if (dialogStack.length === 0) nextDialogLayer = 100;

      const expectedTopId = topDialog()?.id;
      window.setTimeout(() => {
        const currentTop = topDialog();
        if (
          currentTop?.id !== expectedTopId || !previouslyFocused?.isConnected
        ) return;
        if (!currentTop || currentTop.panel.contains(previouslyFocused)) {
          previouslyFocused.focus({ preventScroll: true });
        }
      }, 0);
    };
  }, [present]);

  const accessibleLabel = labelledBy ? undefined : ariaLabel;
  const handleBackdrop = () => {
    if (
      openRef.current &&
      dismissOnBackdropRef.current &&
      onCloseRef.current
    ) {
      onCloseRef.current();
    }
  };

  return (
    <Portal>
      <AnimatePresence
        onExitComplete={() => {
          if (!openRef.current) setPresent(false);
        }}
      >
        {open && (
          <motion.div
            className={clsx(
              "fixed inset-0 flex justify-center px-4",
              placement === "bottom" ? "items-end" : "items-center",
              containerClassName,
            )}
            style={{ zIndex: layer }}
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.18 }}
          >
            <div
              className="onebox-dialog-backdrop absolute inset-0"
              onClick={handleBackdrop}
              aria-hidden="true"
            />
            <motion.div
              ref={panelRef}
              role="dialog"
              aria-modal="true"
              aria-label={accessibleLabel}
              aria-labelledby={labelledBy}
              aria-describedby={describedBy}
              aria-busy={busy || undefined}
              tabIndex={-1}
              className={clsx(
                "onebox-dialog-panel relative",
                SURFACE_CLASS[surface],
                panelClassName,
              )}
              style={{
                ...(surface === "sheet"
                  ? { boxShadow: "var(--onebox-shadow-sheet)" }
                  : undefined),
                ...panelStyle,
              }}
              initial={panelMotion.initial}
              animate={panelMotion.animate}
              exit={panelMotion.exit}
              transition={panelMotion.transition}
            >
              {children}
            </motion.div>
          </motion.div>
        )}
      </AnimatePresence>
    </Portal>
  );
}
