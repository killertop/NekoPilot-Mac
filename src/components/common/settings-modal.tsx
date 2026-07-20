import type { ReactNode } from "react";
import { t } from "../../utils/helper";
import { AppDialog } from "./app-dialog";

interface SettingsModalProps {
  isOpen: boolean;
  onClose: () => void;
  title: string;
  subtitle?: string;
  children: ReactNode;
  cancelLabel?: string;
  confirmLabel?: string;
  onConfirm?: () => void;
  confirmDisabled?: boolean;
  confirmLoading?: boolean;
  confirmDestructive?: boolean;
  maxWidth?: number;
}

/**
 * iOS UIAlertController-shaped modal shell.
 *
 * - Title centered at top (16px semibold).
 * - Optional subtitle underneath (13px secondary).
 * - Arbitrary body passed via children.
 * - Bottom action bar: single Cancel/Close button (full width) when no
 *   confirm action provided, or a two-column split (Cancel | Confirm)
 *   with a vertical hairline between — the exact iOS UIAlert pattern.
 *   Confirm is rendered semibold systemBlue; pass `confirmDestructive`
 *   to paint it systemRed (for "Delete" / "Reset" style actions).
 * - Backdrop is tinted + blurred; click to dismiss.
 * - All portalled to body to survive grouped-card descendant CSS.
 */
export function SettingsModal({
  isOpen,
  onClose,
  title,
  subtitle,
  children,
  cancelLabel,
  confirmLabel,
  onConfirm,
  confirmDisabled,
  confirmLoading,
  confirmDestructive,
  maxWidth = 310,
}: SettingsModalProps) {
  const hasConfirm = !!onConfirm && !!confirmLabel;
  const confirmColor = confirmDestructive
    ? "var(--onebox-red)"
    : "var(--onebox-blue)";

  return (
    <AppDialog
      open={isOpen}
      onClose={onClose}
      ariaLabel={title}
      dismissOnBackdrop={!confirmLoading}
      closeOnEscape={!confirmLoading}
      surface="regular"
      panelStyle={{ maxWidth }}
      busy={confirmLoading}
    >
      <div className="pt-5 px-4">
        <h3
          className="text-[16px] font-semibold text-center tracking-[-0.01em] capitalize"
          style={{ color: "var(--onebox-label)" }}
        >
          {title}
        </h3>
        {subtitle && (
          <p
            className="text-[12px] text-center mt-1.5 leading-snug"
            style={{
              color: "var(--onebox-label-secondary)",
            }}
          >
            {subtitle}
          </p>
        )}
      </div>

      <div
        className="px-4 py-4"
        inert={confirmLoading ? true : undefined}
        aria-hidden={confirmLoading || undefined}
      >
        {children}
      </div>

      {hasConfirm
        ? (
          <div
            className="grid grid-cols-2"
            style={{
              borderTop: "0.5px solid var(--onebox-separator)",
            }}
          >
            <button
              type="button"
              disabled={confirmLoading}
              className="h-11 text-[14px] transition-colors active:bg-[var(--onebox-row-active)] disabled:opacity-40 disabled:cursor-not-allowed"
              style={{ color: "var(--onebox-blue)" }}
              onClick={onClose}
            >
              {cancelLabel ?? t("cancel")}
            </button>
            <button
              type="button"
              disabled={confirmDisabled || confirmLoading}
              onClick={onConfirm}
              className="h-11 text-[14px] font-semibold transition-colors active:bg-[var(--onebox-blue-fill-subtle)] disabled:opacity-40 disabled:cursor-not-allowed"
              style={{
                color: confirmColor,
                borderLeft: "0.5px solid var(--onebox-separator)",
              }}
            >
              {confirmLoading ? t("saving", "Saving...") : confirmLabel}
            </button>
          </div>
        )
        : (
          <button
            type="button"
            disabled={confirmLoading}
            className="w-full h-11 text-[14px] font-semibold transition-colors active:bg-[var(--onebox-blue-fill-subtle)] disabled:opacity-40 disabled:cursor-not-allowed"
            style={{
              color: "var(--onebox-blue)",
              borderTop: "0.5px solid var(--onebox-separator)",
            }}
            onClick={onClose}
          >
            {cancelLabel ?? t("close")}
          </button>
        )}
    </AppDialog>
  );
}
