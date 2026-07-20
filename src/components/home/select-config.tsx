import { useEffect, useMemo, useRef } from "react";
import { getStoreValue, setStoreValue } from "../../single/store";
import { SSI_STORE_KEY, Subscription } from "../../types/definition";
import { t } from "../../utils/helper";
import {
    AppleSelectMenu,
    AppleSelectOption,
    AppleSelectPlaceholder,
} from "./apple-select-menu";
import {
    ACTIVE_SUBSCRIPTION_CHANGED_EVENT,
    NODE_SELECTOR_OPTIMISTIC_CONFIG_EVENT,
} from "./events";

type SubscriptionProps = {
    data: Subscription[] | undefined;
    isLoading: boolean;
    selectedIdentifier: string;
    onSelectionChange: (identifier: string) => void;
    onUpdate: (identifier: string, changed: boolean) => Promise<void>;
};

export default function SelectSub({
    data,
    isLoading,
    selectedIdentifier,
    onSelectionChange,
    onUpdate,
}: SubscriptionProps) {
    const selectedRef = useRef("");
    const selectionEpoch = useRef(0);
    const selectionQueue = useRef<Promise<void>>(Promise.resolve());

    useEffect(() => {
        if (!selectedIdentifier || selectedRef.current === selectedIdentifier) return;
        selectionEpoch.current += 1;
        selectedRef.current = selectedIdentifier;
    }, [selectedIdentifier]);

    useEffect(() => {
        let cancelled = false;
        const syncEpoch = selectionEpoch.current;

        const syncDisplay = async () => {
            if (!data?.length) return;
            const savedId = await getStoreValue(SSI_STORE_KEY);
            if (cancelled || syncEpoch !== selectionEpoch.current) return;
            const item = data.find((i) => i.identifier === savedId);
            if (item) {
                selectedRef.current = item.identifier;
                onSelectionChange(item.identifier);
            } else {
                selectedRef.current = data[0].identifier;
                onSelectionChange(data[0].identifier);
                await setStoreValue(SSI_STORE_KEY, data[0].identifier);
            }
            window.dispatchEvent(
                new CustomEvent<string>(ACTIVE_SUBSCRIPTION_CHANGED_EVENT, {
                    detail: selectedRef.current,
                }),
            );
        };
        void syncDisplay();

        return () => {
            cancelled = true;
        };
    }, [data, onSelectionChange]);

    const options = useMemo<AppleSelectOption<string>[]>(() => {
        return (
            data?.map((item) => ({
                value: item.identifier,
                key: item.identifier,
                raw: item,
            })) ?? []
        );
    }, [data]);

    if (isLoading) {
        return (
            <AppleSelectPlaceholder tone="loading">
                <span className="inline-flex items-center gap-2">
                    <span className="inline-block size-3 rounded-full bg-blue-500/20 animate-pulse" />
                    {t("loading")}
                </span>
            </AppleSelectPlaceholder>
        );
    }

    if (!data?.length) {
        return (
            <AppleSelectPlaceholder>{t("no_subscription")}</AppleSelectPlaceholder>
        );
    }

    const selectedItem = data.find((i) => i.identifier === selectedIdentifier);

    const updateSubscription = (identifier: string) => {
        const item = data.find((i) => i.identifier === identifier);
        if (!item) return;
        const prevId = selectedRef.current;
        if (prevId === item.identifier) return;
        const epoch = ++selectionEpoch.current;

        // Update both selectors in the same frame as the click. Persistence
        // and the local Clash API switch continue asynchronously.
        selectedRef.current = item.identifier;
        onSelectionChange(item.identifier);
        window.dispatchEvent(
            new CustomEvent<string>(ACTIVE_SUBSCRIPTION_CHANGED_EVENT, {
                detail: item.identifier,
            }),
        );
        window.dispatchEvent(
            new CustomEvent<string>(NODE_SELECTOR_OPTIMISTIC_CONFIG_EVENT, {
                detail: item.identifier,
            }),
        );
        selectionQueue.current = selectionQueue.current
            .catch(() => undefined)
            .then(async () => {
                // Coalesce a queued selection if the user has already made a
                // newer choice. Work already in progress remains serialized,
                // so the newest selection always wins.
                if (epoch !== selectionEpoch.current) return;
                await setStoreValue(SSI_STORE_KEY, item.identifier);
                if (epoch !== selectionEpoch.current) return;
                await onUpdate(item.identifier, true);
            })
            .catch(async (error) => {
                if (epoch !== selectionEpoch.current) return;
                console.error("Failed to select configuration:", error);
                selectedRef.current = prevId;
                onSelectionChange(prevId);
                window.dispatchEvent(
                    new CustomEvent<string>(ACTIVE_SUBSCRIPTION_CHANGED_EVENT, {
                        detail: prevId,
                    }),
                );
                window.dispatchEvent(
                    new CustomEvent<string>(NODE_SELECTOR_OPTIMISTIC_CONFIG_EVENT, {
                        detail: prevId,
                    }),
                );
                try {
                    await setStoreValue(SSI_STORE_KEY, prevId);
                    await onUpdate(prevId, true);
                } catch (rollbackError) {
                    console.error("Failed to restore previous configuration:", rollbackError);
                }
            });
    };

    return (
        <AppleSelectMenu<string>
            value={selectedIdentifier}
            options={options}
            onChange={updateSubscription}
            menuMaxHeight={256}
            renderTrigger={() => (
                <span
                    className="block truncate text-[14px] font-medium"
                    style={{ color: 'var(--onebox-label)' }}
                >
                    {selectedItem?.name ?? t("no_subscription")}
                </span>
            )}
            renderOption={({ option, isSelected }) => {
                const sub = option.raw as Subscription | undefined;
                if (!sub) return null;
                return (
                    <div className="flex min-w-0">
                        <span
                            className={`truncate text-[14px] ${
                                isSelected
                                    ? "text-blue-600 font-semibold"
                                    : "font-medium"
                            }`}
                            style={
                                isSelected
                                    ? undefined
                                    : { color: 'var(--onebox-label)' }
                            }
                        >
                            {sub.name}
                        </span>
                    </div>
                );
            }}
        />
    );
}
