import {
    startTransition,
    useEffect,
    useMemo,
    useRef,
    useState,
} from "react";
import { Check } from "react-bootstrap-icons";
import { invoke } from "@tauri-apps/api/core";
import useSWR from "swr";

import {
    getShowNodeProtocol,
    getStoreValue,
    setStoreValue,
} from "../../single/store";
import {
    NODE_DELAY_HISTORY_STORE_KEY,
    SELECTED_NODE_STORE_KEY,
    SSI_STORE_KEY,
    type Subscription,
} from "../../types/definition";
import { clashApiFetch } from "../../utils/clash-api";
import { t } from "../../utils/helper";
import {
    measureNodeDelays,
    measureOfflineNodeDelay,
} from "../../utils/node-delay";
import { compareNodesByDelay } from "../../utils/node-order";
import {
    delaysFromHistory,
    parseNodeDelayHistory,
    retainNodeDelayHistory,
    updateNodeDelayHistory,
    type NodeDelayHistory,
} from "../../utils/node-delay-history";
import {
    selectExitGatewayNode,
    subscriptionIdentifierForNode,
} from "../../utils/node-pool";
import { AppleSelectPlaceholder } from "./apple-select-menu";
import {
    buildNodeProtocolMap,
    nodeDisplayName,
    type NodeProtocolMap,
} from "./node-protocol";
import NodeOption, { type DelayStatus } from "./node-option";
import {
    MANUAL_NODE_SELECTION_EVENT,
    NODE_SELECTOR_REFRESH_EVENT,
} from "./events";

type SelectorResponse = {
    all?: string[];
    now?: string;
};

type NodeSelectorData = {
    all: string[];
    now: string;
    nodeProtocols: NodeProtocolMap;
    showProtocol: boolean;
};

type RuntimeNodeSummary = {
    tag: string;
    protocol: string;
};

type SelectNodeProps = {
    isRunning: boolean;
    subscriptions?: Subscription[];
    urlTestRequest: number;
    onUrlTestStateChange: (isTesting: boolean) => void;
};

export default function SelectNode({
    isRunning,
    subscriptions,
    urlTestRequest,
    onUrlTestStateChange,
}: SelectNodeProps) {
    const nodeSourcesKey = useMemo(
        () => (subscriptions ?? [])
            .map((item) => `${item.identifier}:${item.last_update_time}`)
            .join("\u001f"),
        [subscriptions],
    );
    const { data, isLoading, error, mutate } = useSWR<NodeSelectorData>(
        `swr-unified-node-pool-${isRunning}-${nodeSourcesKey}`,
        async () => {
            const showProtocol = await getShowNodeProtocol();
            if (!isRunning) {
                const [nodes, selectedNode] = await Promise.all([
                    invoke<RuntimeNodeSummary[]>("list_runtime_nodes"),
                    getStoreValue(SELECTED_NODE_STORE_KEY) as Promise<
                        string | undefined
                    >,
                ]);
                const all = nodes.map((node) => node.tag);
                return {
                    all,
                    now: selectedNode && all.includes(selectedNode)
                        ? selectedNode
                        : all[0] ?? "",
                    nodeProtocols: Object.fromEntries(
                        nodes.map((node) => [node.tag, node.protocol]),
                    ),
                    showProtocol,
                };
            }
            const [selectorResponse, allProxiesResponse] = await Promise.all([
                clashApiFetch("/proxies/ExitGateway"),
                clashApiFetch("/proxies")
                    .then((response) => response.json())
                    .catch((fetchError) => {
                        console.warn(
                            "Failed to fetch proxy protocol metadata:",
                            fetchError,
                        );
                        return undefined;
                    }),
            ]);
            const selector = (await selectorResponse.json()) as SelectorResponse;
            const nodeList = Array.isArray(selector.all) ? selector.all : [];
            return {
                all: nodeList,
                now: selector.now ?? "",
                nodeProtocols: buildNodeProtocolMap(nodeList, allProxiesResponse),
                showProtocol,
            };
        },
        {
            revalidateOnFocus: true,
            refreshInterval: 0,
        },
    );

    useEffect(() => {
        const refresh = () => void mutate();
        window.addEventListener(NODE_SELECTOR_REFRESH_EVENT, refresh);
        return () => {
            window.removeEventListener(NODE_SELECTOR_REFRESH_EVENT, refresh);
        };
    }, [mutate]);

    if (error) {
        console.error(error);
        return (
            <div className="onebox-plain-card flex items-center gap-3 px-3.5 py-2.5">
                <span
                    className="min-w-0 flex-1 text-sm"
                    style={{ color: "var(--onebox-label-secondary)" }}
                >
                    {t("node_load_failed")}
                </span>
                <button
                    type="button"
                    className="shrink-0 text-[13px] font-medium"
                    style={{ color: "var(--onebox-blue)" }}
                    onClick={() => void mutate()}
                >
                    {t("retry")}
                </button>
            </div>
        );
    }
    if (isLoading || !data) {
        return (
            <AppleSelectPlaceholder tone="loading">
                <span className="min-h-5 inline-flex items-center gap-2">
                    <span className="inline-block size-3 rounded-full bg-blue-500/20 animate-pulse" />
                    <span
                        className="h-3 w-24 rounded-full animate-pulse"
                        style={{ background: "var(--onebox-fill)" }}
                    />
                </span>
            </AppleSelectPlaceholder>
        );
    }

    return (
        <NodeList
            nodeList={data.all}
            currentNode={data.now}
            nodeProtocols={data.nodeProtocols}
            showProtocol={data.showProtocol}
            isRunning={isRunning}
            subscriptionNames={Object.fromEntries(
                (subscriptions ?? []).map((item) => [item.identifier, item.name]),
            )}
            urlTestRequest={urlTestRequest}
            onUrlTestStateChange={onUrlTestStateChange}
            onUpdate={(node) => {
                if (!node) return mutate();
                return mutate(
                    (current) => current ? { ...current, now: node } : current,
                    { revalidate: false },
                );
            }}
        />
    );
}

type NodeListProps = {
    currentNode: string;
    nodeList: string[];
    nodeProtocols: NodeProtocolMap;
    showProtocol: boolean;
    isRunning: boolean;
    subscriptionNames: Record<string, string>;
    urlTestRequest: number;
    onUrlTestStateChange: (isTesting: boolean) => void;
    onUpdate: (node?: string) => unknown;
};

function NodeList({
    currentNode,
    nodeList,
    nodeProtocols,
    showProtocol,
    isRunning,
    subscriptionNames,
    urlTestRequest,
    onUrlTestStateChange,
    onUpdate,
}: NodeListProps) {
    const [delays, setDelays] = useState<Record<string, DelayStatus>>({});
    const [pendingNodes, setPendingNodes] = useState<Set<string>>(new Set());
    const selectedNodeRef = useRef(currentNode);
    const selectionEpoch = useRef(0);
    const selectionQueue = useRef<Promise<void>>(Promise.resolve());
    const lastUrlTestRequest = useRef(0);
    const delayHistory = useRef<NodeDelayHistory>({});
    const delayHistoryLoad = useRef<Promise<void>>(Promise.resolve());
    const delayHistoryWriteQueue = useRef<Promise<void>>(Promise.resolve());
    const nodeListKey = useMemo(() => nodeList.join("\u001f"), [nodeList]);
    const stableNodeList = useMemo(
        () => Array.from(new Set(nodeList.filter(Boolean))),
        [nodeListKey],
    );
    const duplicateDisplayNames = useMemo(() => {
        const counts = new Map<string, number>();
        for (const node of stableNodeList) {
            const label = nodeDisplayName(node, nodeProtocols[node]);
            counts.set(label, (counts.get(label) ?? 0) + 1);
        }
        return new Set(
            Array.from(counts.entries())
                .filter(([, count]) => count > 1)
                .map(([label]) => label),
        );
    }, [stableNodeList, nodeProtocols]);

    useEffect(() => {
        selectedNodeRef.current = currentNode;
    }, [currentNode]);

    useEffect(() => {
        let cancelled = false;
        const load = getStoreValue(NODE_DELAY_HISTORY_STORE_KEY)
            .then((raw) => {
                if (cancelled) return;
                // A fast new measurement may finish while the native store is
                // loading. Merge it over persisted history so fresh data wins.
                delayHistory.current = retainNodeDelayHistory({
                    ...parseNodeDelayHistory(raw),
                    ...delayHistory.current,
                }, stableNodeList);
                const historicalDelays = delaysFromHistory(
                    delayHistory.current,
                    stableNodeList,
                );
                if (Object.keys(historicalDelays).length === 0) return;
                setDelays((previous) => ({
                    ...historicalDelays,
                    ...previous,
                }));
            })
            .catch((historyError) => {
                console.warn("Failed to restore URL Test history:", historyError);
            });
        delayHistoryLoad.current = load;
        return () => {
            cancelled = true;
        };
    }, [stableNodeList]);

    const contextLabel = (node: string) => {
        const label = nodeDisplayName(node, nodeProtocols[node]);
        if (!duplicateDisplayNames.has(label)) return undefined;
        const identifier = subscriptionIdentifierForNode(node);
        return identifier
            ? subscriptionNames[identifier] ?? identifier.slice(0, 6)
            : undefined;
    };

    useEffect(() => {
        const isManualUrlTest = urlTestRequest > lastUrlTestRequest.current;

        if (stableNodeList.length === 0) {
            setDelays({});
            setPendingNodes(new Set());
            onUrlTestStateChange(false);
            return;
        }

        lastUrlTestRequest.current = urlTestRequest;

        // Home never tests merely because it mounted, regained focus, changed
        // connection state, or refreshed its node pool. Manual URL Test owns
        // only the visible delay/sort state here; the independent ten-minute
        // auto-selection hook keeps its own schedule and node-switching logic.
        if (!isManualUrlTest) {
            setPendingNodes(new Set());
            onUrlTestStateChange(false);
            return;
        }

        // One bounded pass measures the unified runtime pool. React transitions
        // keep row reordering low-priority, so a large airport cannot block a
        // click while results arrive and the list converges toward fastest-first.
        let cancelled = false;
        setPendingNodes(new Set(stableNodeList));
        onUrlTestStateChange(true);

        const timer = window.setTimeout(async () => {
            if (cancelled) return;
            try {
                await measureNodeDelays(stableNodeList, {
                    force: true,
                    measure: isRunning ? undefined : measureOfflineNodeDelay,
                    isCancelled: () => cancelled,
                    onResult: (nodeName, delay) => {
                        delayHistory.current = retainNodeDelayHistory(
                            updateNodeDelayHistory(
                                delayHistory.current,
                                nodeName,
                                delay,
                            ),
                            stableNodeList,
                        );
                        delayHistoryWriteQueue.current = delayHistoryWriteQueue.current
                            .catch(() => undefined)
                            .then(() => delayHistoryLoad.current)
                            .then(() => setStoreValue(
                                NODE_DELAY_HISTORY_STORE_KEY,
                                delayHistory.current,
                            ))
                            .catch((historyError) => {
                                console.warn("Failed to save URL Test history:", historyError);
                            });
                        startTransition(() => {
                            setDelays((previous) => ({
                                ...previous,
                                [nodeName]: delay,
                            }));
                            setPendingNodes((previous) => {
                                if (!previous.has(nodeName)) return previous;
                                const next = new Set(previous);
                                next.delete(nodeName);
                                return next;
                            });
                        });
                    },
                });
            } finally {
                if (!cancelled) onUrlTestStateChange(false);
            }
        }, 0);

        return () => {
            cancelled = true;
            window.clearTimeout(timer);
            onUrlTestStateChange(false);
        };
    }, [isRunning, stableNodeList, urlTestRequest, onUrlTestStateChange]);

    const sortedNodes = useMemo(
        () => [...stableNodeList].sort((left, right) =>
            compareNodesByDelay(left, right, delays, pendingNodes)
        ),
        [stableNodeList, delays, pendingNodes],
    );

    const handleNodeChange = (node: string) => {
        const previous = selectedNodeRef.current;
        if (node === previous) return;
        const epoch = ++selectionEpoch.current;
        selectedNodeRef.current = node;
        onUpdate(node);
        window.dispatchEvent(new Event(MANUAL_NODE_SELECTION_EVENT));

        selectionQueue.current = selectionQueue.current
            .catch(() => undefined)
            .then(async () => {
                if (epoch !== selectionEpoch.current) return;
                if (isRunning) await selectExitGatewayNode(node);
                const identifier = subscriptionIdentifierForNode(node);
                const writes = [setStoreValue(SELECTED_NODE_STORE_KEY, node)];
                if (identifier) writes.push(setStoreValue(SSI_STORE_KEY, identifier));
                await Promise.all(writes).catch((persistError) => {
                    console.warn("Failed to persist selected node:", persistError);
                });
            })
            .catch((switchError) => {
                if (epoch !== selectionEpoch.current) return;
                console.error("Error changing node:", switchError);
                selectedNodeRef.current = previous;
                onUpdate(previous);
                onUpdate();
            });
    };

    if (sortedNodes.length === 0) {
        return <AppleSelectPlaceholder>{t("no_node")}</AppleSelectPlaceholder>;
    }

    return (
        <div
            className="onebox-grouped-card"
            role="listbox"
            aria-label={t("all_nodes")}
        >
            {sortedNodes.map((node) => {
                const isSelected = node === currentNode;
                return (
                    <button
                        key={node}
                        type="button"
                        role="option"
                        aria-selected={isSelected}
                        onClick={() => handleNodeChange(node)}
                        className="w-full min-h-11 px-3.5 py-2.5 flex items-center gap-2 text-left transition-colors active:bg-[rgba(0,122,255,0.12)]"
                        style={{
                            background: isSelected
                                ? "rgba(0, 122, 255, 0.08)"
                                : undefined,
                            contentVisibility: "auto",
                            containIntrinsicSize: "44px",
                        }}
                    >
                        <div className="min-w-0 flex-1">
                            <NodeOption
                                nodeName={node}
                                protocol={nodeProtocols[node]}
                                showProtocol={showProtocol}
                                delay={delays[node] ?? "-"}
                                hasDelay={Object.prototype.hasOwnProperty.call(delays, node)}
                                isTesting={pendingNodes.has(node)}
                                contextLabel={contextLabel(node)}
                            />
                        </div>
                        <Check
                            size={16}
                            className="shrink-0 transition-opacity"
                            style={{
                                color: "var(--onebox-blue)",
                                opacity: isSelected ? 1 : 0,
                            }}
                        />
                    </button>
                );
            })}
        </div>
    );
}
