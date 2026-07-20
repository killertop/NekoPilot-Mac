import { useState } from "react";
import {
  ExclamationCircleFill,
  GlobeAsiaAustralia,
} from "react-bootstrap-icons";
import { externalFaviconUrl } from "../../utils/external-url";

type AvatarProps = {
  url: string;
  danger: boolean;
};

// Module-scoped favicon status cache. Persists across Avatar (re)mounts so
// navigating away from the Configuration page and back doesn't trigger a
// fresh "globe fallback → image swap" flash on every config row. The
// browser caches the bytes itself; we cache the load-succeeded vs
// load-failed decision.
//
// Entries are only ever upgraded (no eviction) — the set is bounded by
// the number of subscriptions the user has ever seen, which is tiny.
const faviconStatus = new Map<string, "ok" | "fail">();

// 36px rounded-square app-icon tile.
// No hover ring — the row itself provides hit feedback. Favicon from HTTP(S)
// official_website, globe fallback, red warning tile for over-quota state.
export default function Avatar({ url, danger }: AvatarProps) {
  const faviconUrl = externalFaviconUrl(url);

  // Seed local state from the module cache so a known-failed URL skips
  // the <img> entirely on re-mount (no flash), and a known-good URL
  // renders <img> from first paint.
  const initialFailedUrl = faviconUrl && faviconStatus.get(faviconUrl) === "fail"
    ? faviconUrl
    : null;
  const [failedUrl, setFailedUrl] = useState<string | null>(initialFailedUrl);
  const faviconFailed = Boolean(
    faviconUrl &&
      (failedUrl === faviconUrl || faviconStatus.get(faviconUrl) === "fail"),
  );

  if (danger) {
    return (
      <div
        className="size-9 rounded-[10px] flex items-center justify-center shrink-0"
        style={{ background: "var(--onebox-red-fill)" }}
      >
        <ExclamationCircleFill
          size={18}
          style={{ color: "var(--onebox-red)" }}
        />
      </div>
    );
  }

  return (
    <div
      className="size-9 rounded-[10px] flex items-center justify-center overflow-hidden shrink-0"
      style={{ background: "var(--onebox-fill)" }}
    >
      {faviconUrl && !faviconFailed
        ? (
          <img
            src={faviconUrl}
            alt=""
            className="size-full object-cover"
            // `eager` pairs with the module-level cache above — we've
            // already made a routing decision by the time <img>
            // renders, so defer-load just delays the paint.
            loading="eager"
            decoding="async"
            onLoad={() => faviconStatus.set(faviconUrl, "ok")}
            onError={() => {
              faviconStatus.set(faviconUrl, "fail");
              setFailedUrl(faviconUrl);
            }}
          />
        )
        : (
          <GlobeAsiaAustralia
            size={18}
            style={{ color: "var(--onebox-label-tertiary)" }}
          />
        )}
    </div>
  );
}
