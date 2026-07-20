import { openUrl } from "@tauri-apps/plugin-opener";
import bytes from "bytes";
import clsx from "clsx";
import { AnimatePresence, motion } from "framer-motion";
import React, { useEffect, useRef, useState } from "react";
import { ArrowClockwise, ChevronDown, InfoCircle, Trash3 } from "react-bootstrap-icons";
import { toast } from "sonner";
import { mutate } from "swr";
import { deleteSubscription } from "../../action/db";
import { refreshSubscription } from "../../action/subscription-hooks";
import { GET_SUBSCRIPTIONS_LIST_SWR_KEY, Subscription } from "../../types/definition";
import { t } from "../../utils/helper";
import { safeExternalHttpUrl } from "../../utils/external-url";
import Avatar from "./avatar";
import { SubscriptionDetailModal } from "./detail-modal";
import { hasTrafficQuota, isLocalConfiguration } from "./subscription-metadata";

interface SubscriptionItemProps {
    item: Subscription;
    expanded: string;
    setExpanded: (id: string) => void;
}

export const SubscriptionItem = React.memo(function SubscriptionItem({
    item,
    expanded,
    setExpanded,
}: SubscriptionItemProps) {
    const isExpanded = expanded === item.identifier;
    const isLocalLink = item.source_type === "local_link";
    const isLocalConfig = isLocalConfiguration(item);
    const hasQuota = hasTrafficQuota(item);
    const usage = hasQuota ? Math.floor((item.used_traffic / item.total_traffic) * 100) : 0;
    const danger = usage >= 100;
    const trafficText = `${bytes(item.used_traffic) ?? "0"} / ${bytes(item.total_traffic) ?? "0"}`;
    const localStatusText = isLocalLink
        ? t("local_link_no_expire")
        : t("local_file_no_expire");

    const [isDeleting, setIsDeleting] = useState(false);
    const [isRefreshing, setIsRefreshing] = useState(false);
    const [detailOpen, setDetailOpen] = useState(false);
    const [confirmingDelete, setConfirmingDelete] = useState(false);
    const deleteConfirmationTimer = useRef<number | undefined>(undefined);

    useEffect(() => () => {
        if (deleteConfirmationTimer.current !== undefined) {
            window.clearTimeout(deleteConfirmationTimer.current);
        }
    }, []);

    const handleDelete = async () => {
        if (isDeleting) return;
        if (!confirmingDelete) {
            setConfirmingDelete(true);
            deleteConfirmationTimer.current = window.setTimeout(() => {
                setConfirmingDelete(false);
                deleteConfirmationTimer.current = undefined;
            }, 3_000);
            return;
        }
        setIsDeleting(true);
        try {
            const deleted = await deleteSubscription(item.identifier);
            if (!deleted) return;
            await new Promise((resolve) => setTimeout(resolve, 100));
            await mutate(GET_SUBSCRIPTIONS_LIST_SWR_KEY);
        } finally {
            setIsDeleting(false);
            setConfirmingDelete(false);
            if (deleteConfirmationTimer.current !== undefined) {
                window.clearTimeout(deleteConfirmationTimer.current);
                deleteConfirmationTimer.current = undefined;
            }
        }
    };

    const handleToggleExpand = () => {
        setConfirmingDelete(false);
        setExpanded(isExpanded ? "" : item.identifier);
    };

    const handleRefresh = async () => {
        if (isRefreshing || isDeleting || isLocalConfig) return;
        setIsRefreshing(true);
        try {
            await refreshSubscription(item.identifier);
            await mutate(GET_SUBSCRIPTIONS_LIST_SWR_KEY);
        } catch (error) {
            console.error("Failed to refresh subscription:", error);
            toast.error(t("update_subscription_failed"));
        } finally {
            setIsRefreshing(false);
        }
    };

    const handleAvatarClick = (e: React.MouseEvent) => {
        e.stopPropagation();
        const website = safeExternalHttpUrl(item.official_website);
        if (website) void openUrl(website);
    };

    const isBusy = isDeleting;
    const progressWidth = Math.min(usage, 100);
    const progressColor = danger ? "#FF3B30" : "var(--onebox-blue)";

    const titleText = isDeleting
        ? t("deleting_subscription")
        : item.name;

    return (
        <li>
            <button
                type="button"
                onClick={isBusy ? undefined : handleToggleExpand}
                disabled={isBusy}
                className={clsx(
                    "w-full flex items-center gap-3 px-4 py-3 text-left",
                    "transition-colors duration-150",
                    !isBusy &&
                        "hover:bg-[rgba(60,60,67,0.025)] active:bg-[rgba(60,60,67,0.06)]",
                    isBusy && "opacity-60",
                )}
            >
                <div onClick={handleAvatarClick}>
                    <Avatar url={item.official_website} danger={danger} />
                </div>

                <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-1.5">
                        <span
                            className="text-[14.5px] font-medium truncate tracking-[-0.01em]"
                            style={{
                                color: danger
                                    ? "#FF3B30"
                                    : "var(--onebox-label)",
                            }}
                        >
                            {titleText}
                        </span>
                    </div>

                    <div
                        className="mt-0.5 text-[11px] tabular-nums truncate"
                        style={{ color: "var(--onebox-label-secondary)" }}
                    >
                        {isLocalConfig ? (
                            localStatusText
                        ) : (
                            hasQuota ? trafficText : t("subscription_metadata_unavailable")
                        )}
                    </div>

                    {hasQuota && (
                        <div
                            className={clsx(
                                "mt-1.5 h-0.75 rounded-full overflow-hidden",
                                isBusy && "animate-pulse",
                            )}
                            style={{ background: "rgba(60, 60, 67, 0.09)" }}
                        >
                            <div
                                className="h-full rounded-full"
                                style={{
                                    width: `${progressWidth}%`,
                                    background: progressColor,
                                    transition: "width 400ms cubic-bezier(0.32, 0.72, 0, 1), background 280ms",
                                }}
                            />
                        </div>
                    )}
                </div>

                <ChevronDown
                    size={12}
                    className="shrink-0"
                    style={{
                        color: "rgba(60, 60, 67, 0.3)",
                        transition: "transform 220ms cubic-bezier(0.32, 0.72, 0, 1)",
                        transform: isExpanded ? "rotate(180deg)" : "rotate(0deg)",
                    }}
                />
            </button>

            <AnimatePresence initial={false}>
                {isExpanded && !isBusy && (
                    <motion.div
                        key="actions"
                        initial={{ height: 0, opacity: 0 }}
                        animate={{ height: "auto", opacity: 1 }}
                        exit={{ height: 0, opacity: 0 }}
                        transition={{
                            duration: 0.22,
                            ease: [0.32, 0.72, 0, 1],
                        }}
                        className="overflow-hidden"
                    >
                        <div
                            className={clsx(
                                "grid relative",
                                isLocalConfig ? "grid-cols-2" : "grid-cols-3",
                            )}
                            style={{
                                borderTop: "0.5px solid var(--onebox-separator)",
                            }}
                        >
                            {!isLocalConfig && (
                                <button
                                    type="button"
                                    disabled={isRefreshing || isDeleting}
                                    onClick={() => void handleRefresh()}
                                    className="py-2.5 flex items-center justify-center gap-1.5 text-[13px] font-medium transition-colors active:bg-[rgba(0,122,255,0.06)] disabled:opacity-50"
                                    style={{ color: "var(--onebox-blue)" }}
                                >
                                    <ArrowClockwise
                                        size={13}
                                        className={isRefreshing ? "animate-spin" : undefined}
                                    />
                                    <span>{isRefreshing ? t("updating") : t("update")}</span>
                                </button>
                            )}
                            <button
                                type="button"
                                onClick={() => setDetailOpen(true)}
                                className="py-2.5 flex items-center justify-center gap-1.5 text-[13px] font-medium transition-colors active:bg-[rgba(0,122,255,0.06)]"
                                style={{
                                    color: "var(--onebox-blue)",
                                    borderLeft: !isLocalConfig
                                        ? "0.5px solid var(--onebox-separator)"
                                        : undefined,
                                }}
                            >
                                <InfoCircle size={13} />
                                <span>{t("details")}</span>
                            </button>
                            <button
                                type="button"
                                disabled={isDeleting}
                                onClick={handleDelete}
                                className="py-2.5 flex items-center justify-center gap-1.5 text-[13px] font-medium transition-colors active:bg-[rgba(255,59,48,0.06)]"
                                style={{
                                    color: "#FF3B30",
                                    borderLeft: "0.5px solid var(--onebox-separator)",
                                }}
                            >
                                <Trash3 size={13} />
                                <span>
                                    {isDeleting
                                        ? t("deleting_subscription")
                                        : confirmingDelete
                                            ? `${t("confirm")} ${t("delete")}?`
                                            : t("delete")}
                                </span>
                            </button>
                        </div>
                    </motion.div>
                )}
            </AnimatePresence>

            <SubscriptionDetailModal
                item={item}
                isOpen={detailOpen}
                onClose={() => setDetailOpen(false)}
            />
        </li>
    );
}, (previous, next) => {
    const previousExpanded = previous.expanded === previous.item.identifier;
    const nextExpanded = next.expanded === next.item.identifier;
    return previous.item === next.item
        && previousExpanded === nextExpanded
        && previous.setExpanded === next.setExpanded;
});
