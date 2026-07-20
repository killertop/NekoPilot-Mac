import bytes from "bytes";
import { AnimatePresence, motion } from "framer-motion";
import { useEffect, useRef, useState } from "react";
import {
  Check,
  Clipboard as ClipboardIcon,
  ClipboardCheck,
  Globe,
  PencilSquare,
  Trash3,
} from "react-bootstrap-icons";
import { toast } from "sonner";
import { mutate } from "swr";
import {
  deleteSubscription,
  getSubscriptionConfig,
  renameSubscription,
} from "../../action/db";
import {
  GET_SUBSCRIPTIONS_LIST_SWR_KEY,
  Subscription,
} from "../../types/definition";
import { t } from "../../utils/helper";
import { safeExternalHttpUrl } from "../../utils/external-url";
import { AppDialog } from "../common/app-dialog";
import { DialogHeader } from "../common/dialog-header";
import { InfoRow, ListRow } from "../common/list-row";
import Avatar from "./avatar";
import { extractLocalNodeInfo, type LocalNodeInfo } from "./local-node-info";
import {
  hasTrafficQuota,
  normalizeTimestampMs,
} from "./subscription-metadata";

interface SubscriptionDetailModalProps {
  item: Subscription | null;
  isOpen: boolean;
  onClose: () => void;
}

// Relative-time helper. `Intl.RelativeTimeFormat` with `numeric: 'auto'` gives
// us "just now" / "刚刚" automatically for the <60s case.
function formatRelative(ts: number, locale: string): string {
  const diffMs = ts - Date.now();
  const abs = Math.abs(diffMs);
  const rtf = new Intl.RelativeTimeFormat(locale, { numeric: "auto" });
  if (abs < 60_000) return rtf.format(Math.round(diffMs / 1000), "second");
  if (abs < 3_600_000) return rtf.format(Math.round(diffMs / 60_000), "minute");
  if (abs < 86_400_000) {
    return rtf.format(Math.round(diffMs / 3_600_000), "hour");
  }
  return rtf.format(Math.round(diffMs / 86_400_000), "day");
}

function formatAbsolute(ts: number, locale: string): string {
  try {
    return new Date(ts).toLocaleString(locale, {
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
    });
  } catch {
    return new Date(ts).toISOString();
  }
}

// Detail sheet for a single subscription. Layout follows the iOS
// "Settings → item → detail" pattern adapted to a 371 px centered modal:
// hero zone up top (avatar + inline-editable name + website link),
// three grouped-list cards below (用量 / 链接 / 操作), and an isolated
// red Delete card at the bottom so the destructive action has breathing
// room from the rest.
export function SubscriptionDetailModal({
  item,
  isOpen,
  onClose,
}: SubscriptionDetailModalProps) {
  const [nameDraft, setNameDraft] = useState("");
  const [isEditingName, setIsEditingName] = useState(false);
  const [savingName, setSavingName] = useState(false);
  const [copiedUrl, setCopiedUrl] = useState(false);
  const [copiedConfig, setCopiedConfig] = useState(false);
  const [copyingConfig, setCopyingConfig] = useState(false);
  const [confirmingDelete, setConfirmingDelete] = useState(false);
  const [isDeleting, setIsDeleting] = useState(false);
  const [localNodeInfo, setLocalNodeInfo] = useState<LocalNodeInfo>();
  const nameInputRef = useRef<HTMLInputElement>(null);
  const savingNameRef = useRef(false);
  const copiedUrlTimer = useRef<number | undefined>(undefined);
  const copiedConfigTimer = useRef<number | undefined>(undefined);
  const deleteConfirmationTimer = useRef<number | undefined>(undefined);

  const clearTransientTimers = () => {
    for (
      const timer of [
        copiedUrlTimer.current,
        copiedConfigTimer.current,
        deleteConfirmationTimer.current,
      ]
    ) {
      if (timer !== undefined) window.clearTimeout(timer);
    }
    copiedUrlTimer.current = undefined;
    copiedConfigTimer.current = undefined;
    deleteConfirmationTimer.current = undefined;
  };

  useEffect(() => () => clearTransientTimers(), []);

  // Reset all transient state whenever the modal opens for a (possibly
  // different) item. Also seed the name draft from the freshest item
  // payload — SWR may have refreshed since the row was mounted.
  useEffect(() => {
    if (!isOpen || !item) return;
    clearTransientTimers();
    setNameDraft(item.name);
    setIsEditingName(false);
    setCopiedUrl(false);
    setCopiedConfig(false);
    setConfirmingDelete(false);
    setIsDeleting(false);
  }, [isOpen, item?.identifier]);

  useEffect(() => {
    if (!isOpen || !item || item.source_type !== "local_link") {
      setLocalNodeInfo(undefined);
      return;
    }
    setLocalNodeInfo(undefined);
    let cancelled = false;
    void getSubscriptionConfig(item.identifier)
      .then((config) => {
        if (!cancelled) setLocalNodeInfo(extractLocalNodeInfo(config));
      })
      .catch((error) => {
        if (!cancelled) {
          setLocalNodeInfo(undefined);
          console.error("Failed to load local node details:", error);
        }
      });
    return () => {
      cancelled = true;
    };
  }, [isOpen, item?.identifier, item?.source_type]);

  // Auto-focus the name input when edit mode turns on.
  useEffect(() => {
    if (isEditingName) {
      nameInputRef.current?.focus();
      nameInputRef.current?.select();
    }
  }, [isEditingName]);

  if (!item) return null;

  const isLocalLink = item.source_type === "local_link";
  const hasQuota = hasTrafficQuota(item);
  const usage = hasQuota
    ? Math.min(100, Math.floor((item.used_traffic / item.total_traffic) * 100))
    : 0;
  const danger = usage >= 100;
  const locale = document.documentElement.lang || navigator.language || "en";

  const trafficText = `${bytes(item.used_traffic) ?? "0"} / ${
    bytes(item.total_traffic) ?? "0"
  }`;
  const lastUpdateTimestamp = normalizeTimestampMs(item.last_update_time);
  const lastUpdateRelative = formatRelative(lastUpdateTimestamp, locale);
  const lastUpdateAbsolute = formatAbsolute(lastUpdateTimestamp, locale);
  const localSecurity = localNodeInfo
    ? localNodeInfo.tls
      ? [
        localNodeInfo.tls.reality
          ? "Reality"
          : localNodeInfo.tls.enabled
          ? "TLS"
          : t("security_none"),
        localNodeInfo.tls.serverName
          ? `SNI: ${localNodeInfo.tls.serverName}`
          : undefined,
        localNodeInfo.tls.fingerprint
          ? `uTLS: ${localNodeInfo.tls.fingerprint}`
          : undefined,
        localNodeInfo.tls.insecure ? t("tls_insecure") : undefined,
      ].filter(Boolean).join(" · ")
      : t("security_none")
    : undefined;

  const officialWebsite = safeExternalHttpUrl(item.official_website);
  const hasOfficialSite = Boolean(officialWebsite);

  const nameChanged = nameDraft.trim() && nameDraft.trim() !== item.name;

  const handleSaveName = async () => {
    if (savingNameRef.current) return;
    if (!nameChanged) {
      setIsEditingName(false);
      return;
    }
    savingNameRef.current = true;
    setSavingName(true);
    try {
      await renameSubscription(item.identifier, nameDraft);
      await mutate(GET_SUBSCRIPTIONS_LIST_SWR_KEY);
      toast.success(t("name_updated"));
      setIsEditingName(false);
    } catch (e) {
      toast.error(String(e));
    } finally {
      savingNameRef.current = false;
      setSavingName(false);
    }
  };

  const handleCopyUrl = async () => {
    try {
      await navigator.clipboard.writeText(item.subscription_url);
      setCopiedUrl(true);
      toast.success(t("subscription_url_copied"));
      if (copiedUrlTimer.current !== undefined) {
        window.clearTimeout(copiedUrlTimer.current);
      }
      copiedUrlTimer.current = window.setTimeout(() => {
        setCopiedUrl(false);
        copiedUrlTimer.current = undefined;
      }, 1500);
    } catch (e) {
      toast.error(t("copy_error"));
    }
  };

  const handleCopyConfig = async () => {
    if (copyingConfig) return;
    setCopyingConfig(true);
    try {
      const config = await getSubscriptionConfig(item.identifier);
      if (!config) {
        toast.error(t("get_subscription_config_failed"));
        return;
      }
      await navigator.clipboard.writeText(JSON.stringify(config, null, 2));
      setCopiedConfig(true);
      toast.success(t("config_content_copied"));
      if (copiedConfigTimer.current !== undefined) {
        window.clearTimeout(copiedConfigTimer.current);
      }
      copiedConfigTimer.current = window.setTimeout(() => {
        setCopiedConfig(false);
        copiedConfigTimer.current = undefined;
      }, 1500);
    } catch (e) {
      toast.error(t("copy_error"));
    } finally {
      setCopyingConfig(false);
    }
  };

  const handleDelete = async () => {
    if (isDeleting) return;
    if (!confirmingDelete) {
      setConfirmingDelete(true);
      // Auto-cancel the confirmation state after 3 s so a stale
      // "tap to confirm" doesn't sit there indefinitely.
      if (deleteConfirmationTimer.current !== undefined) {
        window.clearTimeout(deleteConfirmationTimer.current);
      }
      deleteConfirmationTimer.current = window.setTimeout(() => {
        setConfirmingDelete(false);
        deleteConfirmationTimer.current = undefined;
      }, 3000);
      return;
    }
    if (deleteConfirmationTimer.current !== undefined) {
      window.clearTimeout(deleteConfirmationTimer.current);
      deleteConfirmationTimer.current = undefined;
    }
    setIsDeleting(true);
    try {
      const deleted = await deleteSubscription(item.identifier);
      if (!deleted) {
        setConfirmingDelete(false);
        return;
      }
      await mutate(GET_SUBSCRIPTIONS_LIST_SWR_KEY);
      onClose();
    } finally {
      setIsDeleting(false);
    }
  };

  const requestClose = () => {
    if (!isDeleting) onClose();
  };

  return (
    <AppDialog
      open={isOpen}
      onClose={requestClose}
      ariaLabel={t("details")}
      dismissOnBackdrop={!isDeleting}
      closeOnEscape={!isDeleting}
      surface="detail"
      busy={isDeleting}
      containerClassName="!px-3"
      panelClassName="flex flex-col"
      panelStyle={{
        maxHeight: "calc(100dvh - 60px)",
        background: "var(--onebox-bg)",
      }}
      panelMotion={{
        initial: { scale: 0.94, y: 12, opacity: 0 },
        animate: { scale: 1, y: 0, opacity: 1 },
        exit: { scale: 0.96, y: 4, opacity: 0 },
        transition: { duration: 0.24, ease: [0.32, 0.72, 0, 1] },
      }}
    >
      {/* ── Header ───────────────────────────────── */}
      <DialogHeader
        title={t("details")}
        onClose={requestClose}
        closeDisabled={isDeleting}
        className="bg-[var(--onebox-card)]"
      />

      <div className="onebox-scrollbar-hidden flex-1 overflow-y-auto">
        <div className="px-4 pt-5 pb-5 space-y-5">
          {
            /* Local links contain connection parameters, not a
                                        subscription quota. Remote subscriptions keep
                                        their upstream-provided usage metadata. */
          }
          <section>
            <div className="onebox-grouped-card">
              {/* Name row — avatar + inline-editable text */}
              <div className="px-4 py-3.5 flex items-center gap-3">
                <Avatar
                  url={item.official_website}
                  danger={danger}
                />
                <div className="flex-1 min-w-0">
                  <AnimatePresence mode="wait" initial={false}>
                    {isEditingName
                      ? (
                        <motion.form
                          key="edit"
                          className="flex items-center gap-2"
                          initial={{ opacity: 0, y: 2 }}
                          animate={{ opacity: 1, y: 0 }}
                          exit={{ opacity: 0, y: -2 }}
                          transition={{ duration: 0.12 }}
                          onSubmit={(e) => {
                            e.preventDefault();
                            handleSaveName();
                          }}
                        >
                          <input
                            ref={nameInputRef}
                            type="text"
                            aria-label={t("name_placeholder_1")}
                            value={nameDraft}
                            onChange={(e) => setNameDraft(e.target.value)}
                            disabled={savingName}
                            onBlur={handleSaveName}
                            className="flex-1 min-w-0 text-[15px] font-medium tracking-[-0.01em] bg-transparent border-0 outline-none"
                            style={{
                              color: "var(--onebox-label)",
                              borderBottom: "1px solid var(--onebox-blue)",
                              padding: "1px 0",
                            }}
                          />
                          <button
                            type="submit"
                            disabled={savingName}
                            className="size-5 rounded-full flex items-center justify-center shrink-0"
                            style={{
                              background: "var(--onebox-blue)",
                              color: "var(--onebox-on-accent)",
                              opacity: nameChanged ? 1 : 0.4,
                            }}
                            aria-label={t("save")}
                          >
                            <Check size={11} />
                          </button>
                        </motion.form>
                      )
                      : (
                        <motion.button
                          key="display"
                          type="button"
                          onClick={() => setIsEditingName(true)}
                          className="group w-full flex items-center gap-1.5"
                          initial={{ opacity: 0, y: 2 }}
                          animate={{ opacity: 1, y: 0 }}
                          exit={{ opacity: 0, y: -2 }}
                          transition={{ duration: 0.12 }}
                        >
                          <span
                            className="text-[15px] font-medium tracking-[-0.01em] truncate"
                            style={{
                              color: danger
                                ? "var(--onebox-red)"
                                : "var(--onebox-label)",
                            }}
                          >
                            {item.name}
                          </span>
                          <PencilSquare
                            size={11}
                            className="opacity-40 group-hover:opacity-80 transition-opacity shrink-0"
                            style={{ color: "var(--onebox-label-secondary)" }}
                          />
                        </motion.button>
                      )}
                  </AnimatePresence>
                  {hasOfficialSite && !isEditingName && (
                    <a
                      href="#"
                      onClick={(e) => {
                        e.preventDefault();
                        import("@tauri-apps/plugin-opener").then(
                          ({ openUrl }) => {
                            if (officialWebsite) {
                              return openUrl(officialWebsite);
                            }
                          },
                        );
                      }}
                      className="mt-0.5 inline-flex items-center gap-1 text-[11px]"
                      style={{ color: "var(--onebox-blue)" }}
                    >
                      <Globe size={9} />
                      <span className="truncate">
                        {officialWebsite ? new URL(officialWebsite).host : ""}
                      </span>
                    </a>
                  )}
                </div>
              </div>
              {isLocalLink
                ? (
                  <>
                    {localNodeInfo?.protocol && (
                      <InfoRow
                        label={t("node_protocol")}
                        value={localNodeInfo.protocol}
                      />
                    )}
                    {localNodeInfo?.server && (
                      <InfoRow
                        label={t("node_server")}
                        value={localNodeInfo.server}
                      />
                    )}
                    {localSecurity && (
                      <InfoRow
                        label={t("node_security")}
                        value={localSecurity}
                      />
                    )}
                    {localNodeInfo?.transport && (
                      <InfoRow
                        label={t("node_transport")}
                        value={[
                          localNodeInfo.transport.type,
                          localNodeInfo.transport.detail,
                        ].filter(Boolean).join(" · ")}
                      />
                    )}
                    <InfoRow
                      label={t("local_node_update")}
                      value={t("local_link_no_expire")}
                    />
                    <InfoRow
                      label={t("added_at")}
                      value={lastUpdateRelative}
                      title={lastUpdateAbsolute}
                    />
                  </>
                )
                : (
                  <>
                    {hasQuota && (
                      <InfoRow
                        label={t("traffic_usage")}
                        value={trafficText}
                        tail={<ProgressBar percent={usage} danger={danger} />}
                      />
                    )}
                    {!hasQuota && (
                      <InfoRow
                        label={t("subscription_metadata")}
                        value={t("subscription_metadata_unavailable")}
                      />
                    )}
                    <InfoRow
                      label={t("last_updated")}
                      value={lastUpdateRelative}
                      title={lastUpdateAbsolute}
                    />
                  </>
                )}
            </div>
          </section>

          {
            /* Subscription URL — separate card so
                                        the long value can wrap onto two
                                        lines without crowding the stats
                                        grid above. */
          }
          <section>
            <div className="onebox-grouped-card">
              <div className="px-4 py-3">
                <div
                  className="text-[12px] mb-1"
                  style={{
                    color: "var(--onebox-label-secondary)",
                  }}
                >
                  {t("subscription_url")}
                </div>
                <div
                  className="text-[11.5px] leading-snug break-all onebox-selectable"
                  style={{
                    fontFamily: 'ui-monospace, "SF Mono", Menlo, monospace',
                    color: "var(--onebox-label)",
                  }}
                >
                  {item.subscription_url}
                </div>
              </div>
            </div>
          </section>

          {/* Primary actions */}
          <section>
            <div className="onebox-grouped-card">
              <ListRow
                compact
                showChevron
                leading={copiedUrl
                  ? (
                    <ClipboardCheck
                      size={16}
                      style={{
                        color: "var(--onebox-green)",
                      }}
                    />
                  )
                  : (
                    <ClipboardIcon
                      size={16}
                      style={{
                        color: "var(--onebox-blue)",
                      }}
                    />
                  )}
                title={t("copy_subscription_url")}
                onPress={handleCopyUrl}
              />
              <ListRow
                compact
                showChevron
                leading={copiedConfig
                  ? (
                    <ClipboardCheck
                      size={16}
                      style={{
                        color: "var(--onebox-green)",
                      }}
                    />
                  )
                  : (
                    <ClipboardIcon
                      size={16}
                      style={{
                        color: "var(--onebox-blue)",
                      }}
                    />
                  )}
                title={t("copy_config_content")}
                onPress={handleCopyConfig}
                disabled={copyingConfig}
              />
            </div>
          </section>

          {
            /* Destructive — isolated card so a
                                        red-glyph row doesn't visually
                                        pool with the blue-glyph primary
                                        actions above. */
          }
          <section>
            <div className="onebox-grouped-card">
              <button
                type="button"
                onClick={handleDelete}
                disabled={isDeleting}
                className="w-full flex items-center justify-center gap-2 px-4 py-3 text-[14px] font-medium transition-colors active:bg-[var(--onebox-red-fill-subtle)]"
                style={{ color: "var(--onebox-red)" }}
              >
                <Trash3 size={15} />
                <span>
                  {isDeleting
                    ? t("deleting_subscription")
                    : confirmingDelete
                    ? t("confirm") +
                      " " +
                      t("delete") +
                      "?"
                    : t("delete")}
                </span>
              </button>
            </div>
          </section>
        </div>
      </div>
    </AppDialog>
  );
}

// ── Internal subcomponents ─────────────────────────────────────────

function ProgressBar(
  { percent, danger }: { percent: number; danger: boolean },
) {
  return (
    <div
      className="h-1 rounded-full overflow-hidden"
      style={{ background: "var(--onebox-progress-track)" }}
    >
      <div
        className="h-full rounded-full"
        style={{
          width: `${percent}%`,
          background: danger ? "var(--onebox-red)" : "var(--onebox-blue)",
          transition: "width 400ms cubic-bezier(0.32, 0.72, 0, 1)",
        }}
      />
    </div>
  );
}
