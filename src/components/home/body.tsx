import { useSubscriptions } from "../../hooks/useDB";
import { t, vpnServiceManager } from "../../utils/helper";
import { AppleNetworkStatus, GoogleNetworkStatus } from "./network-check";
import NetworkSpeed from "./network-speed";
import SelectSub from "./select-config";
import SelectNode from "./select-node";
import { NODE_SELECTOR_REFRESH_EVENT } from "./events";

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
    onUpdate,
}: {
    isRunning: boolean;
    onUpdate: () => void;
}) {
    const { data, error, isLoading, mutate } = useSubscriptions();

    const handleUpdate = async (_identifier: string, isUpdate: boolean) => {
        try {
            if (isUpdate && isRunning) {
                await vpnServiceManager.syncConfig({});
                onUpdate();
            }
            // The selected configuration can replace ExitGateway while the
            // engine stays running. Refresh the node picker so it never
            // keeps showing a selector from the previous configuration.
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
                <SelectNode isRunning={isRunning} />
            </section>

            <NetworkSpeed isRunning={isRunning} />
        </div>
    );
}
