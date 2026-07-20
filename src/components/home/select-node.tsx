import { useEffect, useMemo, useState } from "react";

import useSWR from "swr";
import { getShowNodeProtocol } from "../../single/store";
import { clashApiFetch } from "../../utils/clash-api";
import { t } from "../../utils/helper";
import {
    AppleSelectMenu,
    AppleSelectOption,
    AppleSelectPlaceholder,
} from "./apple-select-menu";
import { buildNodeProtocolMap, type NodeProtocolMap } from "./node-protocol";
import NodeOption, { type DelayStatus } from "./node-option";
import { NODE_SELECTOR_REFRESH_EVENT } from "./events";

const DELAY_TEST_URL = "https://www.google.com/generate_204";
const DELAY_TEST_TIMEOUT_MS = 5_000;
const DELAY_TEST_CONCURRENCY = 3;

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

async function measureNodeDelay(nodeName: string): Promise<DelayStatus> {
    try {
        const response = await clashApiFetch(
            `/proxies/${encodeURIComponent(nodeName)}/delay?url=${encodeURIComponent(DELAY_TEST_URL)}&timeout=${DELAY_TEST_TIMEOUT_MS}`,
        );
        if (!response.ok) {
            throw new Error(`HTTP ${response.status}`);
        }
        const payload = await response.json() as { delay?: unknown };
        return typeof payload.delay === "number" && Number.isFinite(payload.delay)
            ? payload.delay
            : "-";
    } catch (error) {
        console.warn(`Failed to fetch proxy delay for ${nodeName}:`, error);
        return "-";
    }
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
        window.addEventListener(NODE_SELECTOR_REFRESH_EVENT, refresh);
        return () => window.removeEventListener(NODE_SELECTOR_REFRESH_EVENT, refresh);
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
            onUpdate={() => mutate()}
        />
    );
}

type NodeMenuProps = {
    currentNode: string;
    nodeList: string[];
    nodeProtocols: NodeProtocolMap;
    showProtocol: boolean;
    isRunning: boolean;
    onUpdate: () => void;
};

function NodeMenu(props: NodeMenuProps) {
    const { currentNode, nodeList, nodeProtocols, showProtocol, onUpdate, isRunning } = props;
    const [showDelay, setShowDelay] = useState(false);
    const [delays, setDelays] = useState<Record<string, DelayStatus>>({});
    const [pendingNodes, setPendingNodes] = useState<Set<string>>(new Set());
    const nodeListKey = useMemo(() => nodeList.join("\u001f"), [nodeList]);
    const stableNodeList = useMemo(
        () => Array.from(new Set(nodeList.filter(Boolean))),
        [nodeListKey],
    );

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

            let nextIndex = 0;
            const worker = async () => {
                while (!cancelled) {
                    const nodeName = stableNodeList[nextIndex++];
                    if (!nodeName) return;

                    const delay = await measureNodeDelay(nodeName);
                    if (cancelled) return;
                    setDelays((previous) => ({ ...previous, [nodeName]: delay }));
                    setPendingNodes((previous) => {
                        if (!previous.has(nodeName)) return previous;
                        const next = new Set(previous);
                        next.delete(nodeName);
                        return next;
                    });
                }
            };

            void Promise.all(
                Array.from(
                    { length: Math.min(DELAY_TEST_CONCURRENCY, stableNodeList.length) },
                    () => worker(),
                ),
            );
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

    const handleNodeChange = async (node: string) => {
        try {
            await clashApiFetch("/proxies/ExitGateway", {
                method: "PUT",
                body: JSON.stringify({ name: node }),
            });
            onUpdate();
        } catch (error) {
            console.error("Error changing node:", error);
        }
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
                    />
                </div>
            )}
        />
    );
}
