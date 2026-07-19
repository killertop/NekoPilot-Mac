import { useCallback, useEffect, useMemo, useState } from 'react';
import useSWR from "swr";
import { clashApiFetch } from '../../utils/clash-api';
import { t } from '../../utils/helper';
import { nodeDisplayName, nodeProtocolLabel } from "./node-protocol";

// 常量定义
const API_CONFIG = {
    TIMEOUT: 3000,
    // Probe a node once when it becomes visible. Repeating a delay request for
    // every option consumes bandwidth and wakes the proxy while the picker is
    // merely open.
    REFRESH_INTERVAL: 0,
    TIMEOUT_DELAY: 2000
} as const;

const DelayTestUrl = "https://www.google.com/generate_204"

// 类型定义
type DelayStatus = '-' | number;

interface ProxyResponse {
    delay: DelayStatus;
}

interface NodeOptionProps {
    nodeName: string;
    protocol?: string;
    showProtocol: boolean;
    showDelay: boolean;
    // Only the active node is measured. Mounting all rows in a large picker
    // must not start one delay probe per node.
    measureDelay?: boolean;
}

// 样式常量
const STYLES = {
    container: 'flex justify-between items-center w-full',
    protocolContainer: 'grid grid-cols-[minmax(0,1fr)_auto_minmax(3.5rem,auto)] items-center gap-2 w-full',
    nodeName: 'truncate font-medium flex-1 min-w-0 text-sm',
    protocolNodeName: 'truncate font-medium min-w-0 text-sm',
    protocol: 'rounded-md px-1.5 py-0.5 text-[10px] font-semibold leading-4',
    startingContainer: 'onebox-select'
} as const;

// 自定义 Hook：管理代理延迟数据
const useProxyDelay = (nodeName: string, enabled: boolean) => {
    const fetcher = useCallback(async (path: string): Promise<ProxyResponse> => {
        if (!nodeName) {
            return { delay: '-' };
        }

        try {
            const response = await clashApiFetch(path);

            if (!response.ok) {
                throw new Error(`HTTP ${response.status}`);
            }

            return await response.json();
        } catch (error) {
            console.warn(`Failed to fetch proxy delay for ${nodeName}:`, error);
            return { delay: '-' };
        }
    }, [nodeName]);

    const swrKey = enabled && nodeName
        ? `/proxies/${encodeURIComponent(nodeName)}/delay?url=${encodeURIComponent(DelayTestUrl)}&timeout=5000`
        : null;

    const { data, error, isLoading } = useSWR<ProxyResponse>(
        swrKey,
        fetcher,
        {
            refreshInterval: API_CONFIG.REFRESH_INTERVAL,
            revalidateOnFocus: false,
            dedupingInterval: 1000
        }
    );

    const delay: DelayStatus = data?.delay ?? '-';

    return {
        delay,
        isError: !!error,
        isLoading
    };
};

// 延迟指示器组件
interface DelayIndicatorProps {
    delay: DelayStatus;
    showDelay: boolean;
    delayText: string;
}

const DelayIndicator = ({ delay, showDelay, delayText }: DelayIndicatorProps) => {
    const displayText = delay === '-' ? delayText : `${delay}ms`;

    return (
        <div className="h-5 flex items-center justify-end min-w-[3.5rem]">
            {showDelay ? (
                <div className="text-sm font-medium transition-all duration-300 ease">
                    {displayText}
                </div>
            ) : (
                <span className="onebox-spinner onebox-spinner-dots onebox-spinner-sm">
                    <span />
                    <span />
                    <span />
                </span>
            )}
        </div>
    );
};

export default function NodeOption({
    nodeName,
    protocol,
    showProtocol,
    showDelay,
    measureDelay = true,
}: NodeOptionProps) {
    const [delayText, setDelayText] = useState<string>('-');
    const { delay } = useProxyDelay(nodeName, measureDelay);

    // 处理超时显示
    useEffect(() => {
        if (!showDelay || delay !== '-') {
            return;
        }

        const timer = setTimeout(() => {
            setDelayText(t("timeout"));
        }, API_CONFIG.TIMEOUT_DELAY);

        return () => clearTimeout(timer);
    }, [showDelay, delay]);

    // 重置延迟文本
    useEffect(() => {
        if (delay !== '-') {
            setDelayText('-');
        }
    }, [delay]);

    // 计算显示的节点名称
    const displayName = useMemo(() => {
        return nodeName === 'auto' ? t("auto") : nodeDisplayName(nodeName, protocol);
    }, [nodeName, protocol]);
    const protocolLabel = nodeProtocolLabel(protocol);

    // 处理节点名称为空的情况
    if (!nodeName) {
        return (
            <div className={STYLES.startingContainer}>
                {t('starting')}
            </div>
        );
    }

    return (
        <div className={showProtocol ? STYLES.protocolContainer : STYLES.container}>
            <span
                className={showProtocol ? STYLES.protocolNodeName : STYLES.nodeName}
                title={displayName}
            >
                {displayName}
            </span>
            {showProtocol && (
                <span
                    className={STYLES.protocol}
                    style={{
                        visibility: protocol ? "visible" : "hidden",
                        color: 'var(--onebox-blue)',
                        background: 'rgba(0, 122, 255, 0.10)',
                    }}
                    title={protocolLabel}
                >
                    {protocolLabel ?? "proxy"}
                </span>
            )}
            {measureDelay ? (
                <DelayIndicator
                    delay={delay}
                    showDelay={showDelay}
                    delayText={delayText}
                />
            ) : (
                <span className="block h-5 min-w-[3.5rem]" aria-hidden />
            )}
        </div>
    );
}
