import useSWR from 'swr';
import { invoke } from '@tauri-apps/api/core';
import { GET_SUBSCRIPTIONS_LIST_SWR_KEY, Subscription } from '../types/definition';
const subscriptionsFetcher = async () => {
    return invoke<Subscription[]>('list_subscriptions');
};

export function useSubscriptions() {
    return useSWR<Subscription[]>(GET_SUBSCRIPTIONS_LIST_SWR_KEY, subscriptionsFetcher)
}
