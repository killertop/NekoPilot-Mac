import clsx from "clsx";
import { ReactNode, useId } from "react";

export interface RadioOption<T extends string> {
  key: T;
  label: string;
  sublabel?: ReactNode;
  disabled?: boolean;
}

interface RadioOptionListProps<T extends string> {
  value: T;
  onChange: (v: T) => void;
  options: RadioOption<T>[];
  ariaLabel: string;
  disabled?: boolean;
}

/**
 * iOS-style radio list. Tap anywhere on a row to select it (the `<label>`
 * wraps the hidden input so the whole row is the hit target). Custom radio
 * glyph: systemBlue fill with a white centre dot when selected, hollow
 * ring when not.
 *
 * Uses `.onebox-grouped-list` (flush — keeps inset row separators but no
 * card chrome) because every caller is already inside a SettingsModal.
 * Wrapping with `.onebox-grouped-card` here would nest a card inside the
 * modal's card and produce a double-elevation look.
 */
export function RadioOptionList<T extends string>({
  value,
  onChange,
  options,
  ariaLabel,
  disabled = false,
}: RadioOptionListProps<T>) {
  const groupName = useId();
  return (
    <div
      className="onebox-grouped-list"
      role="radiogroup"
      aria-label={ariaLabel}
    >
      {options.map((opt) => {
        const checked = value === opt.key;
        const optionDisabled = disabled || opt.disabled;
        return (
          <label
            key={opt.key}
            className={clsx(
              "flex items-center gap-3 px-4 py-3 transition-colors",
              optionDisabled
                ? "opacity-50 cursor-not-allowed"
                : "cursor-pointer active:bg-[var(--onebox-row-active)]",
            )}
          >
            <div className="flex-1 min-w-0">
              <div
                className="text-[14px] tracking-[-0.005em]"
                style={{ color: "var(--onebox-label)" }}
              >
                {opt.label}
              </div>
              {opt.sublabel && (
                <div
                  className="text-[12px] mt-0.5"
                  style={{
                    color: "var(--onebox-label-secondary)",
                  }}
                >
                  {opt.sublabel}
                </div>
              )}
            </div>
            <input
              type="radio"
              name={groupName}
              checked={checked}
              onChange={() => !optionDisabled && onChange(opt.key)}
              disabled={optionDisabled}
              className="
                                shrink-0 appearance-none
                                size-4.5 rounded-full
                                border-[1.5px] border-[var(--onebox-label-tertiary)]
                                checked:border-[var(--onebox-blue)]
                                checked:bg-[var(--onebox-blue)]
                                relative
                                before:content-[''] before:absolute
                                before:w-1.5 before:h-1.5
                                before:bg-[var(--onebox-on-accent)] before:rounded-full
                                before:top-1/2 before:left-1/2
                                before:-translate-x-1/2 before:-translate-y-1/2
                                before:opacity-0 checked:before:opacity-100
                                transition-colors
                                focus-visible:outline-2 focus-visible:outline-offset-2
                                focus-visible:outline-[var(--onebox-blue)]
                                disabled:opacity-40
                            "
            />
          </label>
        );
      })}
    </div>
  );
}
