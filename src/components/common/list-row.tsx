import clsx from "clsx";
import type { CSSProperties, ReactNode } from "react";
import { ChevronRight } from "react-bootstrap-icons";

export type ListRowTone = "default" | "accent" | "danger";

interface ListRowContentProps {
  leading?: ReactNode;
  title: ReactNode;
  subtitle?: ReactNode;
  trailing?: ReactNode;
  showChevron?: boolean;
  tone?: ListRowTone;
  compact?: boolean;
  titleClassName?: string;
  subtitleClassName?: string;
}

function toneColor(tone: ListRowTone): string {
  if (tone === "accent") return "var(--onebox-blue)";
  if (tone === "danger") return "var(--onebox-red)";
  return "var(--onebox-label)";
}

function ListRowContent({
  leading,
  title,
  subtitle,
  trailing,
  showChevron,
  tone = "default",
  compact,
  titleClassName,
  subtitleClassName,
}: ListRowContentProps) {
  return (
    <>
      {leading && (
        <div
          className={clsx(
            "flex items-center justify-center shrink-0",
            compact ? "size-6" : "size-7",
          )}
        >
          {leading}
        </div>
      )}
      <div className="flex-1 min-w-0">
        <div
          className={clsx(
            "tracking-[-0.005em] truncate",
            compact ? "text-[14px]" : "text-[15px]",
            titleClassName,
          )}
          style={{ color: toneColor(tone) }}
          title={typeof title === "string" ? title : undefined}
        >
          {title}
        </div>
        {subtitle && (
          <div
            className={clsx(
              "text-[12px] truncate mt-0.5",
              subtitleClassName,
            )}
            style={{ color: "var(--onebox-label-secondary)" }}
            title={typeof subtitle === "string" ? subtitle : undefined}
          >
            {subtitle}
          </div>
        )}
      </div>
      {trailing && (
        <div
          className="text-[13px] tracking-[-0.005em] shrink-0"
          style={{ color: "var(--onebox-label-secondary)" }}
        >
          {trailing}
        </div>
      )}
      {showChevron && (
        <ChevronRight
          size={13}
          className="shrink-0"
          style={{ color: "var(--onebox-label-tertiary)" }}
          aria-hidden="true"
        />
      )}
    </>
  );
}

interface ListRowProps extends ListRowContentProps {
  onPress?: () => void;
  disabled?: boolean;
  className?: string;
  ariaLabel?: string;
}

interface RowSurfaceProps {
  children: ReactNode;
  onPress: () => void;
  disabled?: boolean;
  selected?: boolean;
  compact?: boolean;
  className?: string;
  ariaLabel?: string;
  ariaPressed?: boolean;
  ariaExpanded?: boolean;
  style?: CSSProperties;
}

/** Shared interactive row surface for simple and composite list content. */
export function RowSurface({
  children,
  onPress,
  disabled,
  selected,
  compact,
  className,
  ariaLabel,
  ariaPressed,
  ariaExpanded,
  style,
}: RowSurfaceProps) {
  return (
    <button
      type="button"
      disabled={disabled}
      onClick={onPress}
      aria-label={ariaLabel}
      aria-pressed={ariaPressed}
      aria-expanded={ariaExpanded}
      style={style}
      className={clsx(
        "w-full flex items-center gap-3 px-4 text-left transition-colors",
        "focus-visible:outline-2 focus-visible:outline-offset-[-2px] focus-visible:outline-[var(--onebox-blue)]",
        compact ? "py-2.5" : "py-3",
        selected &&
          "bg-[var(--onebox-blue-fill-subtle)] hover:bg-[var(--onebox-blue-fill)] active:bg-[var(--onebox-blue-fill)]",
        !selected && !disabled &&
          "hover:bg-[var(--onebox-row-hover)] active:bg-[var(--onebox-row-active)]",
        disabled && "opacity-50 cursor-not-allowed",
        className,
      )}
    >
      {children}
    </button>
  );
}

/** One row vocabulary for settings, actions and read-only grouped lists. */
export function ListRow({
  onPress,
  disabled,
  className,
  ariaLabel,
  ...contentProps
}: ListRowProps) {
  const rowClassName = clsx(
    "w-full flex items-center gap-3 px-4 text-left",
    contentProps.compact ? "py-2.5" : "py-3",
    onPress && "transition-colors",
    onPress && !disabled &&
      "hover:bg-[var(--onebox-row-hover)] active:bg-[var(--onebox-row-active)]",
    disabled && "opacity-50 cursor-not-allowed",
    className,
  );

  if (onPress) {
    return (
      <RowSurface
        disabled={disabled}
        onPress={onPress}
        compact={contentProps.compact}
        className={clsx("!gap-3", className)}
        ariaLabel={ariaLabel}
      >
        <ListRowContent {...contentProps} />
      </RowSurface>
    );
  }

  return (
    <div className={rowClassName} aria-label={ariaLabel}>
      <ListRowContent {...contentProps} />
    </div>
  );
}

interface ToggleListRowProps extends ListRowContentProps {
  checked: boolean;
  onChange: () => void;
  disabled?: boolean;
  ariaLabel?: string;
}

/** Native-label toggle row so its full 44px+ surface remains clickable. */
export function ToggleListRow({
  checked,
  onChange,
  disabled,
  ariaLabel,
  ...contentProps
}: ToggleListRowProps) {
  return (
    <label
      className={clsx(
        "w-full flex items-center gap-3 px-4 py-3",
        disabled ? "opacity-50 cursor-not-allowed" : "cursor-pointer",
      )}
    >
      <ListRowContent
        {...contentProps}
        trailing={
          <input
            type="checkbox"
            className="onebox-toggle"
            checked={checked}
            onChange={onChange}
            disabled={disabled}
            aria-label={ariaLabel}
          />
        }
      />
    </label>
  );
}

interface InfoRowProps {
  label: ReactNode;
  value: ReactNode;
  tail?: ReactNode;
  title?: string;
  compact?: boolean;
  onPress?: () => void;
  showChevron?: boolean;
  valueClassName?: string;
}

export function InfoRow({
  label,
  value,
  tail,
  title,
  compact,
  onPress,
  showChevron,
  valueClassName,
}: InfoRowProps) {
  const content = (
    <>
      <div className="flex items-center justify-between gap-3">
        <span
          className="text-[14px] tracking-[-0.005em] shrink-0 truncate"
          style={{ color: "var(--onebox-label)" }}
        >
          {label}
        </span>
        <span
          className={clsx(
            "min-w-0 flex-1 text-right text-[13px] tracking-[-0.005em] truncate tabular-nums",
            valueClassName,
          )}
          style={{ color: "var(--onebox-label-secondary)" }}
        >
          {value}
        </span>
        {showChevron && (
          <ChevronRight
            size={13}
            className="shrink-0"
            style={{ color: "var(--onebox-label-tertiary)" }}
            aria-hidden="true"
          />
        )}
      </div>
      {tail && <div className="mt-2">{tail}</div>}
    </>
  );
  const className = clsx(
    "w-full px-4 text-left",
    compact ? "py-2.5" : "py-3",
    onPress &&
      "transition-colors hover:bg-[var(--onebox-row-hover)] active:bg-[var(--onebox-row-active)] focus-visible:outline-2 focus-visible:outline-offset-[-2px] focus-visible:outline-[var(--onebox-blue)]",
  );

  if (onPress) {
    return (
      <button
        type="button"
        onClick={onPress}
        className={className}
        title={title}
      >
        {content}
      </button>
    );
  }
  return <div className={className} title={title}>{content}</div>;
}
