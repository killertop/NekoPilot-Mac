import { useMemo } from "react";
import Body from "../components/home/body";
import {
    useVPNOperations,
} from "../components/home/hooks";
import { PowerToggle } from "../components/home/power-toggle";
import { PrestartRepairModal } from "../components/home/prestart-repair-modal";
import { StatusDisplay } from "../components/home/status-display";
import { useSubscriptions } from "../hooks/useDB";
import { t } from "../utils/helper";

import "./home.css";

// Layout targets the actual available area: 371×514 px
// (600 window - 30 titlebar - 56 tab bar). When the window is shorter than
// that budget, let the app-level route scroller reveal the overflow.
export default function HomePage() {
    const {
        data: subscriptions,
        error: subscriptionsError,
        isLoading: subscriptionsLoading,
        mutate: retrySubscriptions,
    } = useSubscriptions();
    const {
        isLoading,
        isRunning,
        operationStatus,
        toggleService,
        repairState,
        onRepairSuccess,
    } = useVPNOperations();

    const isEmpty = !subscriptionsError
        && subscriptions !== undefined
        && subscriptions.length === 0;

    const handlePowerToggle = () => {
        if (subscriptionsLoading || subscriptions === undefined || subscriptionsError) {
            void retrySubscriptions();
            return;
        }
        void toggleService(isEmpty);
    };

    const statusText = useMemo(() => {
        if (subscriptionsError) {
            return t("subscription_load_failed", "Subscription list unavailable");
        }
        if (subscriptionsLoading) return t("loading");
        switch (operationStatus) {
            case "starting":
                return t("connecting");
            case "stopping":
                return t("switching");
            default:
                return isRunning ? t("connected") : t("not_connected");
        }
    }, [operationStatus, isRunning, subscriptionsError, subscriptionsLoading]);

    const phase: "idle" | "connecting" | "on" = isLoading
        ? "connecting"
        : isRunning
            ? "on"
            : "idle";

    return (
        <div
            className="onebox-home onebox-scrollbar-hidden relative h-full w-full min-h-0 overflow-x-hidden overflow-y-auto"
            data-phase={phase}
        >
            <PrestartRepairModal
                visible={repairState.visible}
                orphanPids={repairState.orphanPids}
                onSuccess={onRepairSuccess}
                onClose={() => {/* dismissed on failure — user must restart */}}
            />
            {/* systemBlue aura — only rendered when the tile is active or
                connecting. Same design vocabulary as the warm glow under
                an active HomeKit accessory. Idle shows no decoration. */}
            <div className="onebox-aura" aria-hidden />

            {/* Content */}
            <div className="relative min-h-[calc(100dvh-56px)] flex flex-col items-center px-5 pt-5 pb-5">
                <PowerToggle
                    isRunning={Boolean(isRunning)}
                    isLoading={isLoading || subscriptionsLoading}
                    onClick={handlePowerToggle}
                />

                <div className="mt-4">
                    <StatusDisplay statusText={statusText} phase={phase} />
                </div>

                <div className="mt-5 w-full flex-1 min-h-0">
                    <Body isRunning={Boolean(isRunning)} />
                </div>
            </div>
        </div>
    );
}
