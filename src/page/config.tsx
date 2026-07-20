import { motion } from "framer-motion";
import { useState } from "react";
import { ArrowClockwise, CloudPlus, Plus } from "react-bootstrap-icons";
import { mutate } from "swr";
import { toast } from "sonner";
import { refreshSubscription } from "../action/subscription-hooks";
import { SubscriptionItem } from "../components/configuration/item";
import { useSubscriptionModalController } from "../components/configuration/modal";
import { isLocalConfiguration } from "../components/configuration/subscription-metadata";
import { useSubscriptions } from "../hooks/useDB";
import {
    GET_SUBSCRIPTIONS_LIST_SWR_KEY,
} from "../types/definition";
import { t } from "../utils/helper";
import { mapSettledWithConcurrency } from "../utils/async-pool";

const SUBSCRIPTION_REFRESH_CONCURRENCY = 3;


export default function Configuration() {
    const { openModal, ModalElement } = useSubscriptionModalController();

    return (
        <div className="onebox-scrollpage onebox-scrollpage--fixed flex flex-col">
            <div className="flex-1 min-h-0 overflow-hidden">
                <ConfigurationBody
                    onAdd={openModal}
                />
            </div>
            {ModalElement}
        </div>
    );
}


function ConfigurationBody({
    onAdd,
}: {
    onAdd: () => void;
}) {
    const [expanded, setExpanded] = useState("");
    const { data, error, isLoading, mutate: retrySubscriptions } = useSubscriptions();

    const handleUpdateAll = async () => {
        const remoteSubscriptions = (data ?? []).filter(
            (item) => !isLocalConfiguration(item),
        );
        const results = await mapSettledWithConcurrency(
            remoteSubscriptions,
            SUBSCRIPTION_REFRESH_CONCURRENCY,
            (item) => refreshSubscription(item.identifier),
        );
        if (results.some((result) => result.status === "rejected")) {
            toast.error(t("update_subscription_failed"));
        }
        await mutate(GET_SUBSCRIPTIONS_LIST_SWR_KEY);
    };

    if (isLoading) {
        return (
            <div className="flex justify-center items-center pt-20">
                <p
                    className="text-sm"
                    style={{ color: "var(--onebox-label-secondary)" }}
                >
                    {t("loading")}
                </p>
            </div>
        );
    }

    if (error) {
        return (
            <div className="px-4 pt-5">
                <div className="onebox-plain-card flex items-center gap-3 px-4 py-3">
                    <p
                        className="min-w-0 flex-1 text-[13px]"
                        style={{ color: "var(--onebox-label-secondary)" }}
                    >
                        {t("subscription_load_failed", "Subscription list unavailable")}
                    </p>
                    <button
                        type="button"
                        className="shrink-0 text-[13px] font-medium"
                        style={{ color: "var(--onebox-blue)" }}
                        onClick={() => void retrySubscriptions()}
                    >
                        {t("retry", "Retry")}
                    </button>
                </div>
            </div>
        );
    }

    if (!data || !data.length) {
        return <EmptyState onAdd={onAdd} />;
    }

    return (
        <div className="onebox-scrollbar-hidden h-full overflow-auto px-4 pb-5">
            <ul className="onebox-grouped-card list-none p-0">
                {data.map((item) => (
                    <SubscriptionItem
                        key={item.identifier}
                        item={item}
                        expanded={expanded}
                        setExpanded={setExpanded}
                    />
                ))}
            </ul>

            <ActionsCard onAdd={onAdd} onUpdateAll={handleUpdateAll} />
        </div>
    );
}

// iOS-style bottom action card. Two full-width rows, systemBlue labels,
// inset hairline separator (provided by .onebox-grouped-card). Sits below
// the subscription list so users see their content first, actions second.
function ActionsCard({
    onAdd,
    onUpdateAll,
}: {
    onAdd: () => void;
    onUpdateAll: () => Promise<void>;
}) {
    const [isUpdating, setIsUpdating] = useState(false);

    const handleUpdate = async () => {
        if (isUpdating) return;
        setIsUpdating(true);
        try {
            await onUpdateAll();
        } finally {
            setIsUpdating(false);
        }
    };

    return (
        <div className="onebox-grouped-card mt-4">
            <ActionRow
                icon={
                    <motion.div
                        animate={isUpdating ? { rotate: 360 } : { rotate: 0 }}
                        transition={
                            isUpdating
                                ? {
                                      duration: 1,
                                      repeat: Infinity,
                                      ease: "linear",
                                  }
                                : { duration: 0.3, ease: "easeOut" }
                        }
                    >
                        <ArrowClockwise
                            size={18}
                            style={{ color: "var(--onebox-blue)" }}
                        />
                    </motion.div>
                }
                label={
                    isUpdating
                        ? t("updating")
                        : t("update_all_subscriptions")
                }
                disabled={isUpdating}
                onPress={handleUpdate}
            />
            <ActionRow
                icon={
                    <Plus size={18} style={{ color: "var(--onebox-blue)" }} />
                }
                label={t("add_subscription")}
                onPress={onAdd}
            />
        </div>
    );
}

function ActionRow({
    icon,
    label,
    disabled,
    onPress,
}: {
    icon: React.ReactNode;
    label: string;
    disabled?: boolean;
    onPress: () => void;
}) {
    return (
        <button
            type="button"
            disabled={disabled}
            onClick={onPress}
            className={`w-full flex items-center gap-3 px-4 py-3 text-left transition-colors ${
                disabled
                    ? "opacity-50 cursor-not-allowed"
                    : "hover:bg-[rgba(60,60,67,0.025)] active:bg-[rgba(60,60,67,0.06)]"
            }`}
        >
            <div className="size-7 flex items-center justify-center shrink-0">
                {icon}
            </div>
            <span
                className="flex-1 text-[15px] tracking-[-0.005em]"
                style={{ color: "var(--onebox-blue)" }}
            >
                {label}
            </span>
        </button>
    );
}

function EmptyState({ onAdd }: { onAdd: () => void }) {
    return (
        <div className="h-full flex flex-col items-center justify-center px-8 pb-20">
            <div
                className="size-16 rounded-[18px] flex items-center justify-center mb-5"
                style={{ background: "rgba(0, 122, 255, 0.1)" }}
            >
                <CloudPlus size={30} style={{ color: "var(--onebox-blue)" }} />
            </div>
            <h2
                className="text-[17px] font-semibold tracking-[-0.01em] mb-1.5"
                style={{ color: "var(--onebox-label)" }}
            >
                {t("no_subscription_config")}
            </h2>
            <p
                className="text-[13px] leading-snug text-center mb-6 max-w-[240px]"
                style={{ color: "var(--onebox-label-secondary)" }}
            >
                {t("no_subscription_hint")}
            </p>

            <button
                type="button"
                onClick={onAdd}
                className="h-10 px-5 rounded-full text-[14px] font-semibold transition-colors active:brightness-95"
                style={{
                    background: "var(--onebox-blue)",
                    color: "#FFFFFF",
                    boxShadow:
                        "0 2px 8px -2px rgba(0, 122, 255, 0.4), 0 1px 2px rgba(0, 0, 0, 0.05)",
                }}
            >
                {t("add_subscription")}
            </button>
        </div>
    );
}
