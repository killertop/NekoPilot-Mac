import { ReactNode, useEffect } from "react";
import { createPortal } from "react-dom";

let bodyScrollLockCount = 0;

/**
 * Render children into document.body instead of the caller's DOM location.
 *
 * Use this around modals/dialogs that sit inside `.onebox-grouped-card`
 * (or any other container with descendant-scoped CSS). Rendering in-place
 * can make `position: fixed` lose to a class-specificity-matching
 * ancestor rule (e.g. our `> * + * { position: relative }` separator
 * rule), which pushes the modal in-flow and expands the parent.
 *
 * The Tauri webview always has document.body available before React
 * renders, so there's no SSR guard here.
 */
export function Portal({ children }: { children: ReactNode }) {
    return createPortal(children, document.body);
}

/** Keep the underlying page from scrolling while one or more modals are open. */
export function useBodyScrollLock(locked: boolean) {
    useEffect(() => {
        if (!locked) return;

        bodyScrollLockCount += 1;
        document.body.classList.add("overflow-hidden");

        return () => {
            bodyScrollLockCount = Math.max(0, bodyScrollLockCount - 1);
            if (bodyScrollLockCount === 0) {
                document.body.classList.remove("overflow-hidden");
            }
        };
    }, [locked]);
}
