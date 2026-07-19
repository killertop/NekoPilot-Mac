import { toast } from 'sonner';
import useSWR from 'swr';
import { invoke } from '@tauri-apps/api/core';
import { GET_SUBSCRIPTIONS_LIST_SWR_KEY, Subscription } from '../types/definition';





const subscriptionsFetcher = async () => {
    try {
        return await invoke<Subscription[]>('list_subscriptions')
    } catch (error) {
        console.error('Error fetching subscriptions:', error)
        toast.error(`订阅失败 ${error}`)
        return []

    }
}

export function useSubscriptions() {
    return useSWR<Subscription[]>(GET_SUBSCRIPTIONS_LIST_SWR_KEY, subscriptionsFetcher)
}

