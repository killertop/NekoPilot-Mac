import clsx from "clsx";
import type { ReactNode } from "react";

interface PageLayoutProps {
  children: ReactNode;
  fixed?: boolean;
  className?: string;
}

/** Shared route shell. Home intentionally keeps its dedicated hero layout. */
export function PageLayout({ children, fixed, className }: PageLayoutProps) {
  return (
    <div
      className={clsx(
        "onebox-scrollpage",
        fixed && "onebox-scrollpage--fixed flex flex-col",
        className,
      )}
    >
      {children}
    </div>
  );
}

interface PageContentProps {
  children: ReactNode;
  className?: string;
  scrollable?: boolean;
}

interface PageStateProps {
  children: ReactNode;
  className?: string;
}

/** Keeps loading, error and empty states inside the route's shared bounds. */
export function PageState({ children, className }: PageStateProps) {
  return (
    <div className={clsx("onebox-page-inner h-full", className)}>
      <div className="h-full flex flex-col items-center justify-center">
        {children}
      </div>
    </div>
  );
}

/** Consistent 16px route inset and 448px maximum content width. */
export function PageContent(
  { children, className, scrollable }: PageContentProps,
) {
  return (
    <div
      className={clsx(
        "onebox-page-inner",
        scrollable && "onebox-scrollbar-hidden h-full overflow-auto",
        className,
      )}
    >
      {children}
    </div>
  );
}
