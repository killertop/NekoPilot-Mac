import { invoke } from '@tauri-apps/api/core';

import { useEffect, useState } from 'react';


export function useVersion() {
    const [version, setVersion] = useState<string>('');

    useEffect(() => {
        let cancelled = false;
        const fetchVersion = async () => {
            try {
                const appVersion = await invoke('get_app_version') as string;
                if (!cancelled) setVersion(appVersion);
            } catch (error) {
                if (!cancelled) console.error('Error fetching version:', error);
            }
        };

        void fetchVersion();
        return () => {
            cancelled = true;
        };
    }, []);

    return version;
}
