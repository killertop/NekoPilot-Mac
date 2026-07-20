import clsx from "clsx";
import type { ReactNode } from "react";

interface SectionLabelProps {
  children: ReactNode;
  trailing?: ReactNode;
  className?: string;
  inset?: "page" | "card";
}

export function SectionLabel({
  children,
  trailing,
  className,
  inset = "page",
}: SectionLabelProps) {
  return (
    <div
      className={clsx(
        "flex items-center justify-between mb-1.5",
        inset === "card" ? "px-4" : "px-1",
        className,
      )}
    >
      <span className="onebox-section-label">{children}</span>
      {trailing && <div className="flex items-center gap-2">{trailing}</div>}
    </div>
  );
}
