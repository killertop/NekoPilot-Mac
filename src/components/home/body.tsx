import { useSubscriptions } from "../../hooks/useDB";
import { t, vpnServiceManager } from "../../utils/helper";
import { AppleNetworkStatus, GoogleNetworkStatus } from "./network-check";
import NetworkSpeed from "./network-speed";
import SelectSub from "./select-config";
import SelectNode from "./select-node";
import { NODE_SELECTOR_REFRESH_EVENT } from "./events";
import { switchToSubscriptionNode } from "../../utils/node-pool";

function SectionLabel({
    children,
    trailing,
}: {
    children: React.ReactNode;
    trailing?: React.ReactNode;
}) {
    return (
        <div className="flex items-center justify-between px-1 mb-1.5">
            <span
                className="text-[11px] font-semibold uppercase tracking-[0.08em] capitalize"
                style={{ color: 'var(--onebox-label-secondary)' }}
            >
                {children}
            </span>
            {trailing && (
                <div className="flex items-center gap-2">{trailing}</div>
            )}
        </div>
    );
}

export default function Body({
    isRunning,
}: {
    isRunning: boolean;
}) {
    const { data, error, isLoading, mutate } = useSubscriptions();

    const handleUpdate = async (identifier: string, changed: boolean) => {
        try {
            if (changed && isRunning) {
                // Current builds keep every airport and local node in the
                // active selector, so changing configuration is a local API
                // operation rather than a sing-box restart. The fallback is
                // needed once when upgrading from an older single-pool config.
                let switched = await switchToSubscriptionNode(identifier);
                if (!switched) {
                    await vpnServiceManager.syncAndReload(0);
                    for (let attempt = 0; attempt < 8 && !switched; attempt += 1) {
                        if (attempt > 0) {
                            await new Promise((resolve) => window.setTimeout(resolve, 125));
                        }
                        try {
                            switched = await switchToSubscriptionNode(identifier);
                        } catch {
                            // SIGHUP can briefly recreate the local controller.
                        }
                    }
                }
                if (!switched) throw new Error("subscription_node_not_loaded");
            }
            window.dispatchEvent(new Event(NODE_SELECTOR_REFRESH_EVENT));
        } catch (error) {
            console.error(t("update_config_failed") + ":", error);
        }
    };

    if (error) {
        return (
            <div className="w-full">
                <div className="onebox-plain-card flex items-center gap-3 px-4 py-3">
                    <div className="min-w-0 flex-1">
                        <p
                            className="text-[13px] font-medium"
                            style={{ color: "var(--onebox-label)" }}
                        >
                            {t("subscription_load_failed")}
                        </p>
                        <p
                            className="mt-0.5 truncate text-[11px]"
                            style={{ color: "var(--onebox-label-secondary)" }}
                        >
                            {String(error)}
                        </p>
                    </div>
                    <button
                        type="button"
                        className="shrink-0 text-[13px] font-medium"
                        style={{ color: "var(--onebox-blue)" }}
                        onClick={() => void mutate()}
                    >
                        {t("retry")}
                    </button>
                </div>
            </div>
        );
    }

    return (
        <div className="w-full space-y-4">
            <section className="w-full">
                <SectionLabel
                    trailing={
                        <>
                            <AppleNetworkStatus />
                            <GoogleNetworkStatus isRunning={isRunning} />
                        </>
                    }
                >
                    {t("current_subscription")}
                </SectionLabel>
                <SelectSub
                    onUpdate={handleUpdate}
                    data={data}
                    isLoading={isLoading}
                />
            </section>

            <section className="w-full">
                <SectionLabel>{t("node_selection")}</SectionLabel>
                <SelectNode isRunning={isRunning} subscriptions={data} />
            </section>

            <NetworkSpeed isRunning={isRunning} />
        </div>
    );
}
