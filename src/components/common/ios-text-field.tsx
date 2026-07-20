import clsx from "clsx";
import { type Ref, useId, useState } from "react";

interface IOSTextFieldProps {
  value: string;
  onChange: (value: string) => void;
  placeholder?: string;
  error?: string;
  autoFocus?: boolean;
  disabled?: boolean;
  monospace?: boolean;
  /** Called when user presses Enter. No-op if omitted. */
  onSubmit?: () => void;
  /**
   * Shorter height and smaller text for dense inline uses
   * (e.g. next to an inline Add button). Default is Apple's
   * standard 40px form row height.
   */
  compact?: boolean;
  /**
   * Extra classes applied to the wrapper div. Use this for flex
   * sizing in parent rows (e.g. `flex-1`).
   */
  className?: string;
  inputRef?: Ref<HTMLInputElement>;
  label?: string;
}

/**
 * iOS-style text input. Grey translucent fill, no border, no focus ring.
 * Focus is indicated by a slightly darker fill. Error state uses systemRed
 * tints. Rounded-xl.
 */
export function IOSTextField({
  value,
  onChange,
  placeholder,
  error,
  autoFocus,
  disabled,
  monospace,
  onSubmit,
  compact,
  className,
  inputRef,
  label,
}: IOSTextFieldProps) {
  const [focused, setFocused] = useState(false);
  const errorId = useId();

  const bg = error
    ? focused ? "var(--onebox-red-fill)" : "var(--onebox-red-fill-subtle)"
    : focused
    ? "var(--onebox-fill)"
    : "var(--onebox-card-muted)";

  return (
    <div className={className}>
      <input
        ref={inputRef}
        type="text"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        onFocus={() => setFocused(true)}
        onBlur={() => setFocused(false)}
        onKeyDown={(e) => {
          if (e.key === "Enter" && onSubmit) {
            e.preventDefault();
            onSubmit();
          }
        }}
        placeholder={placeholder}
        disabled={disabled}
        autoFocus={autoFocus}
        data-autofocus={autoFocus || undefined}
        aria-label={label ?? placeholder}
        aria-invalid={Boolean(error) || undefined}
        aria-describedby={error ? errorId : undefined}
        className={clsx(
          "w-full rounded-xl outline-none focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[var(--onebox-blue)] disabled:opacity-50",
          compact
            ? "h-9 px-3 text-[13px] tracking-[-0.005em]"
            : "h-10 px-3.5 text-[14px]",
        )}
        style={{
          background: bg,
          color: "var(--onebox-label)",
          transition: "background 180ms ease-out",
          fontFamily: monospace
            ? '"SF Mono", ui-monospace, "Menlo", monospace'
            : undefined,
        }}
      />
      {error && (
        <p
          id={errorId}
          className="text-[11px] mt-1 ml-1"
          style={{ color: "var(--onebox-red)" }}
        >
          {error}
        </p>
      )}
    </div>
  );
}
