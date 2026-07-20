import clsx from "clsx";
import { X } from "react-bootstrap-icons";
import { t } from "../../utils/helper";

interface DialogHeaderProps {
  title: string;
  titleId?: string;
  onClose?: () => void;
  closeDisabled?: boolean;
  className?: string;
  grabber?: boolean;
}

/** Shared title and close affordance for app dialogs and sheets. */
export function DialogHeader({
  title,
  titleId,
  onClose,
  closeDisabled,
  className,
  grabber,
}: DialogHeaderProps) {
  return (
    <div
      className={clsx(
        "relative flex items-center justify-center h-11 px-4 shrink-0",
        className,
      )}
    >
      {grabber && (
        <span
          className="absolute top-2 left-1/2 -translate-x-1/2 w-9 h-1 rounded-full"
          style={{ background: "var(--onebox-fill-strong)" }}
          aria-hidden="true"
        />
      )}
      <h3
        id={titleId}
        className={clsx(
          "text-[15px] font-semibold tracking-[-0.01em]",
          grabber && "mt-1.5",
        )}
        style={{ color: "var(--onebox-label)" }}
      >
        {title}
      </h3>
      {onClose && (
        <button
          type="button"
          onClick={onClose}
          disabled={closeDisabled}
          className="absolute right-2 top-2 size-7 rounded-full flex items-center justify-center transition-colors active:bg-[var(--onebox-row-active)] disabled:opacity-40 disabled:cursor-not-allowed"
          aria-label={t("close")}
        >
          <X
            size={18}
            style={{ color: "var(--onebox-label-secondary)" }}
            aria-hidden="true"
          />
        </button>
      )}
    </div>
  );
}
