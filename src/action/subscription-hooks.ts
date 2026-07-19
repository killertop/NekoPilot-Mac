import { useCallback, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { getSingBoxUserAgent, t } from "../utils/helper";


type MessageType = 'success' | 'error' | 'warning' | undefined;

export function useUpdateSubscription() {
    const [loading, setLoading] = useState(false);
    const [message, setMessage] = useState<string>('');
    const [messageType, setMessageType] = useState<MessageType>();

    const resetMessage = () => {
        setMessage('');
        setMessageType(undefined);
    };

    const update = useCallback(async (identifier: string) => {
        setLoading(true);
        setMessage('');
        setMessageType(undefined);
        try {
            await invoke('refresh_subscription', {
                identifier,
                userAgent: await getSingBoxUserAgent(),
            });
            setMessage(t('update_subscription_success'));
            setMessageType('success');
        } catch {
            setMessage(t('update_subscription_failed'));
            setMessageType('error');
        } finally {
            setLoading(false);
        }
    }, []);

    return { update, resetMessage, loading, message, messageType };
}
