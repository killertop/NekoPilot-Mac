import { useMemo } from 'react';
import { t } from '../../utils/helper';
import type { DelayStatus } from '../../utils/node-delay';
import { nodeDisplayName, nodeProtocolLabel } from "./node-protocol";

export type { DelayStatus } from '../../utils/node-delay';

interface NodeOptionProps {
    nodeName: string;
    protocol?: string;
    showProtocol: boolean;
    delay: DelayStatus;
    hasDelay: boolean;
    isTesting: boolean;
    contextLabel?: string;
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

// 延迟指示器组件
interface DelayIndicatorProps {
    delay: DelayStatus;
    hasDelay: boolean;
    isTesting: boolean;
}

const DelayIndicator = ({ delay, hasDelay, isTesting }: DelayIndicatorProps) => {
    const displayText = delay === '-' ? t("timeout") : `${delay}ms`;

    return (
        <div className="h-5 flex items-center justify-end min-w-[3.5rem]">
            {hasDelay ? (
                <div
                    className="text-sm font-medium"
                    style={isTesting
                        ? { color: "var(--onebox-label-tertiary)" }
                        : undefined}
                    title={isTesting ? t("url_testing") : undefined}
                >
                    {displayText}
                </div>
            ) : !isTesting ? (
                <div
                    className="text-sm font-medium"
                    style={{ color: "var(--onebox-label-tertiary)" }}
                >
                    —
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
    delay,
    hasDelay,
    isTesting,
    contextLabel,
}: NodeOptionProps) {
    // 计算显示的节点名称
    const displayName = useMemo(() => {
        const label = nodeName === 'auto' ? t("auto") : nodeDisplayName(nodeName, protocol);
        return contextLabel ? `${contextLabel} · ${label}` : label;
    }, [nodeName, protocol, contextLabel]);
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
            <DelayIndicator
                delay={delay}
                hasDelay={hasDelay}
                isTesting={isTesting}
            />
        </div>
    );
}
