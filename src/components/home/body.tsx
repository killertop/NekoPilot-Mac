import { useState } from "react";
import { ArrowClockwise } from "react-bootstrap-icons";
import { useSubscriptions } from "../../hooks/useDB";
import { t } from "../../utils/helper";
import NetworkSpeed from "./network-speed";
import SelectNode from "./select-node";

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
    const { data, error, mutate } = useSubscriptions();
    const [urlTestRequest, setUrlTestRequest] = useState(0);
    const [isUrlTesting, setIsUrlTesting] = useState(false);

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
                            <button
                                type="button"
                                disabled={isUrlTesting}
                                onClick={() => setUrlTestRequest((request) => request + 1)}
                                className="inline-flex h-7 items-center gap-1 rounded-full px-2 text-[11px] font-semibold transition-opacity disabled:opacity-40"
                                style={{
                                    color: "var(--onebox-blue)",
                                    background: "rgba(0, 122, 255, 0.10)",
                                }}
                                title={t("url_test")}
                            >
                                <ArrowClockwise
                                    size={12}
                                    className={isUrlTesting ? "animate-spin" : undefined}
                                />
                                <span>{isUrlTesting ? t("url_testing") : t("url_test")}</span>
                            </button>
                        </>
                    }
                >
                    {t("all_nodes")}
                </SectionLabel>
                <SelectNode
                    isRunning={isRunning}
                    subscriptions={data}
                    urlTestRequest={urlTestRequest}
                    onUrlTestStateChange={setIsUrlTesting}
                />
                <span className="sr-only" aria-live="polite">
                    {isUrlTesting ? t("url_testing") : ""}
                </span>
            </section>

            <NetworkSpeed isRunning={isRunning} />
        </div>
    );
}
