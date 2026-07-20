import { useEffect, useMemo, useRef, useState } from "react";

import useSWR from "swr";
import { getShowNodeProtocol } from "../../single/store";
import type { Subscription } from "../../types/definition";
import { clashApiFetch } from "../../utils/clash-api";
import { t } from "../../utils/helper";
import { measureNodeDelays } from "../../utils/node-delay";
import {
    preferredNodeForSubscription,
    selectExitGatewayNode,
    subscriptionIdentifierForNode,
} from "../../utils/node-pool";
import {
    AppleSelectMenu,
    AppleSelectOption,
    AppleSelectPlaceholder,
} from "./apple-select-menu";
import { buildNodeProtocolMap, nodeDisplayName, type NodeProtocolMap } from "./node-protocol";
import NodeOption, { type DelayStatus } from "./node-option";
import {
    MANUAL_NODE_SELECTION_EVENT,
    NODE_SELECTOR_OPTIMISTIC_CONFIG_EVENT,
    NODE_SELECTOR_REFRESH_EVENT,
} from "./events";

function compareNodesByDelay(
    left: string,
    right: string,
    delays: Record<string, DelayStatus>,
    pendingNodes: Set<string>,
): number {
    const leftDelay = delays[left];
    const rightDelay = delays[right];
    const leftHasDelay = typeof leftDelay === "number";
    const rightHasDelay = typeof rightDelay === "number";

    // Results should visibly converge toward the fastest nodes while the
    // batch is still running. Pending nodes stay below measured ones, and
    // completed timeouts move to the bottom after every successful result.
    if (leftHasDelay && rightHasDelay) return leftDelay - rightDelay;
    if (leftHasDelay) return -1;
    if (rightHasDelay) return 1;

    const leftPending = pendingNodes.has(left);
    const rightPending = pendingNodes.has(right);
    if (leftPending !== rightPending) return leftPending ? -1 : 1;
    return 0;
}

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

type SelectNodeProps = {
    isRunning: boolean;
    subscriptions?: Subscription[];
};

export default function SelectNode(props: SelectNodeProps) {
    const { isRunning } = props;
    const { data, isLoading, error, mutate } = useSWR(
        `swr-clash-proxies-ExitGateway-${props.isRunning}`,
        async () => {
            if (!isRunning) {
                return { all: [], now: "", nodeProtocols: {}, showProtocol: false };
            }
            const showProtocol = await getShowNodeProtocol();
            const [selectorResponse, allProxiesResponse] = await Promise.all([
                clashApiFetch("/proxies/ExitGateway"),
                // Read protocol metadata once per selector refresh, never on a
                // timer. It is needed both for the optional badge and to hide
                // the internal `VLESS ·` prefix when the badge is disabled.
                clashApiFetch("/proxies")
                    .then((response) => response.json())
                    .catch((error) => {
                        console.warn("Failed to fetch proxy protocol metadata:", error);
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
            } satisfies NodeSelectorData;
        },
        {
            revalidateOnFocus: true,
            // Node changes are initiated by this component and call mutate()
            // directly. Polling the local Clash API every second adds no value.
            refreshInterval: 0,
        },
    );

    useEffect(() => {
        const refresh = () => {
            void mutate();
        };
        const optimisticallySelectConfiguration = (event: Event) => {
            const identifier = (event as CustomEvent<string>).detail;
            if (!identifier) return;
            void mutate((current) => {
                if (!current) return current;
                const target = preferredNodeForSubscription(identifier, current.all);
                return target && target !== current.now
                    ? { ...current, now: target }
                    : current;
            }, { revalidate: false });
        };
        window.addEventListener(NODE_SELECTOR_REFRESH_EVENT, refresh);
        window.addEventListener(
            NODE_SELECTOR_OPTIMISTIC_CONFIG_EVENT,
            optimisticallySelectConfiguration,
        );
        return () => {
            window.removeEventListener(NODE_SELECTOR_REFRESH_EVENT, refresh);
            window.removeEventListener(
                NODE_SELECTOR_OPTIMISTIC_CONFIG_EVENT,
                optimisticallySelectConfiguration,
            );
        };
    }, [mutate]);

    if (!isRunning) {
        return (
            <AppleSelectPlaceholder>{t("not_started")}</AppleSelectPlaceholder>
        );
    }

    if (error) {
        console.error(error);
    }
    if (isLoading || !data) {
        return (
            <AppleSelectPlaceholder tone="loading">
                <span className="min-h-5 inline-flex items-center gap-2">
                    <span className="inline-block size-3 rounded-full bg-blue-500/20 animate-pulse" />
                    <span
                        className="h-3 w-24 rounded-full animate-pulse"
                        style={{ background: 'var(--onebox-fill)' }}
                    />
                </span>
            </AppleSelectPlaceholder>
        );
    }

    return (
        <NodeMenu
            isRunning={isRunning}
            nodeList={data.all}
            currentNode={data.now}
            nodeProtocols={data.nodeProtocols}
            showProtocol={data.showProtocol}
            subscriptionNames={Object.fromEntries(
                (props.subscriptions ?? []).map((item) => [item.identifier, item.name]),
            )}
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

type NodeMenuProps = {
    currentNode: string;
    nodeList: string[];
    nodeProtocols: NodeProtocolMap;
    showProtocol: boolean;
    isRunning: boolean;
    subscriptionNames: Record<string, string>;
    onUpdate: (node?: string) => unknown;
};

function NodeMenu(props: NodeMenuProps) {
    const { currentNode, nodeList, nodeProtocols, showProtocol, subscriptionNames, onUpdate, isRunning } = props;
    const [showDelay, setShowDelay] = useState(false);
    const [delays, setDelays] = useState<Record<string, DelayStatus>>({});
    const [pendingNodes, setPendingNodes] = useState<Set<string>>(new Set());
    const selectedNodeRef = useRef(currentNode);
    const selectionEpoch = useRef(0);
    const selectionQueue = useRef<Promise<void>>(Promise.resolve());
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

    const contextLabel = (node: string) => {
        const label = nodeDisplayName(node, nodeProtocols[node]);
        if (!duplicateDisplayNames.has(label)) return undefined;
        const identifier = subscriptionIdentifierForNode(node);
        return identifier ? subscriptionNames[identifier] ?? identifier.slice(0, 6) : undefined;
    };

    useEffect(() => {
        if (!isRunning || stableNodeList.length === 0) {
            setShowDelay(false);
            setDelays({});
            setPendingNodes(new Set());
            return;
        }

        // A connection starts one bounded test pass for every node in the
        // active selector. Results are shared by both the trigger and popup,
        // rather than relying on each visible option to start its own request.
        // This avoids a request storm for large subscriptions while still
        // filling all rows automatically after Connect succeeds.
        let cancelled = false;
        setShowDelay(false);
        setDelays({});
        setPendingNodes(new Set(stableNodeList));

        const timer = window.setTimeout(() => {
            if (cancelled) return;
            setShowDelay(true);

            void measureNodeDelays(stableNodeList, {
                isCancelled: () => cancelled,
                onResult: (nodeName, delay) => {
                    setDelays((previous) => ({ ...previous, [nodeName]: delay }));
                    setPendingNodes((previous) => {
                        if (!previous.has(nodeName)) return previous;
                        const next = new Set(previous);
                        next.delete(nodeName);
                        return next;
                    });
                },
            });
        }, 500);

        return () => {
            cancelled = true;
            window.clearTimeout(timer);
        };
    }, [isRunning, stableNodeList]);

    const options = useMemo<AppleSelectOption<string>[]>(
        () =>
            nodeList
                .map((name) => ({
                    value: name,
                    key: name,
                    raw: nodeProtocols[name],
                }))
                .sort((left, right) => compareNodesByDelay(
                    left.value,
                    right.value,
                    delays,
                    pendingNodes,
                )),
        [nodeList, nodeProtocols, delays, pendingNodes],
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
                await selectExitGatewayNode(node);
            })
            .catch((error) => {
                if (epoch !== selectionEpoch.current) return;
                console.error("Error changing node:", error);
                selectedNodeRef.current = previous;
                onUpdate(previous);
                onUpdate();
            });
    };

    if (!nodeList || nodeList.length === 0) {
        return (
            <AppleSelectPlaceholder>{t("no_node")}</AppleSelectPlaceholder>
        );
    }

    return (
        <AppleSelectMenu<string>
            value={currentNode}
            options={options}
            onChange={handleNodeChange}
            menuMaxHeight={220}
            renderTrigger={() => (
                <NodeOption
                    nodeName={currentNode}
                    protocol={nodeProtocols[currentNode]}
                    showProtocol={showProtocol}
                    showDelay={showDelay}
                    delay={delays[currentNode] ?? "-"}
                    isTesting={pendingNodes.has(currentNode)}
                    contextLabel={contextLabel(currentNode)}
                />
            )}
            renderOption={({ option, isSelected }) => (
                <div
                    className={isSelected ? "font-semibold text-blue-600" : ""}
                    style={
                        isSelected ? undefined : { color: 'var(--onebox-label)' }
                    }
                >
                    <NodeOption
                        nodeName={option.value}
                        protocol={
                            typeof option.raw === "string"
                                ? option.raw
                                : undefined
                        }
                        showProtocol={showProtocol}
                        showDelay={showDelay}
                        delay={delays[option.value] ?? "-"}
                        isTesting={pendingNodes.has(option.value)}
                        contextLabel={contextLabel(option.value)}
                    />
                </div>
            )}
        />
    );
}
