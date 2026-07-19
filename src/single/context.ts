import { createContext } from "react";



export type ActiveScreenType = 'home' | 'configuration' | 'settings' | 'router_settings';



interface NavContextType {
    activeScreen: ActiveScreenType;
    setActiveScreen: (screen: ActiveScreenType) => void;
    deepLinkUrl: string;
    setDeepLinkUrl: (url: string) => void;
    deepLinkApplyUrl: string;
    setDeepLinkApplyUrl: (url: string) => void;
    deepLinkApplyName: string;
    setDeepLinkApplyName: (name: string) => void;
    // Whether the apply pipeline should auto-start the VPN engine after
    // import. True = deep-link apply=1 behaviour (the default). Set to
    // false right before firing `setDeepLinkApplyUrl` to request a
    // manual-add flow: import and select the config, but do not restart the
    // engine.
    // The consumer (useVPNOperations) resets this back to true after
    // consuming each URL, so every fresh fire defaults to the apply=1
    // contract unless explicitly overridden.
    deepLinkApplyAutoStart: boolean;
    setDeepLinkApplyAutoStart: (autoStart: boolean) => void;
}

export const NavContext = createContext<NavContextType>({
    activeScreen: 'home',
    setActiveScreen: () => { },
    deepLinkUrl: '',
    setDeepLinkUrl: () => { },
    deepLinkApplyUrl: '',
    setDeepLinkApplyUrl: () => { },
    deepLinkApplyName: '',
    setDeepLinkApplyName: () => { },
    deepLinkApplyAutoStart: true,
    setDeepLinkApplyAutoStart: () => { },
});
