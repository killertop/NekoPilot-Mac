import clsx from "clsx";
import type { ReactNode } from "react";

/** Static row used while the node list is loading, empty or unavailable. */
export function NodeListPlaceholder({
  children,
  tone = "muted",
}: {
  children: ReactNode;
  tone?: "muted" | "loading";
}) {
  return (
    <div
      className={clsx(
        "onebox-plain-card w-full min-h-11 px-4 py-2.5 flex items-center gap-2",
        tone !== "loading" && "opacity-70",
      )}
    >
      <div
        className="flex-1 min-w-0 text-sm"
        style={{ color: "var(--onebox-label-tertiary)" }}
      >
        {children}
      </div>
    </div>
  );
}
