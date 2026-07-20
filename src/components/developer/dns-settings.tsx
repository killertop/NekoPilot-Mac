import { useEffect, useState } from "react";
import { HddRack } from "react-bootstrap-icons";
import { toast } from "sonner";
import { getDirectDNS, setDirectDNS } from "../../single/store";
import { t, vpnServiceManager } from "../../utils/helper";
import { IOSTextField } from "../common/ios-text-field";
import { SettingsModal } from "../common/settings-modal";
import { SettingItem } from "../settings/common";

export default function DNSSettingsItem() {
    const [isOpen, setIsOpen] = useState(false);
    const [dnsServers, setDnsServers] = useState("");
    const [isLoading, setIsLoading] = useState(false);
    useEffect(() => {
        if (isOpen) void loadDNS();
    }, [isOpen]);

    const loadDNS = async () => {
        const dns = await getDirectDNS();
        setDnsServers(dns);
    };

    const handleSave = async () => {
        if (!dnsServers.trim()) {
            toast.error(t("dns_cannot_empty", "DNS cannot be empty"));
            return;
        }
        setIsLoading(true);
        try {
            await setDirectDNS(dnsServers.trim());
            if (await vpnServiceManager.is_running()) {
                await vpnServiceManager.syncAndReload();
            }
            toast.success(t("dns_saved", "DNS settings saved successfully"));
            setIsOpen(false);
        } catch (error) {
            const code = error instanceof Error ? error.message : String(error);
            toast.error(
                code.includes("invalid_direct_dns")
                    ? t("dns_invalid", "Enter a valid DNS IP address")
                    : t("dns_save_failed", "Failed to save DNS settings"),
            );
        } finally {
            setIsLoading(false);
        }
    };

    return (
        <>
            <SettingItem
                icon={<HddRack className="text-[#30B0C7]" size={22} />}
                title={t("direct_dns_settings", "Direct DNS Settings")}
                subTitle={t("open_direct_dns", "Open direct DNS settings")}
                onPress={() => setIsOpen(true)}
            />
            <SettingsModal
                isOpen={isOpen}
                onClose={() => setIsOpen(false)}
                title={t("direct_dns_settings", "Direct DNS Settings")}
                confirmLabel={t("save")}
                onConfirm={handleSave}
                confirmDisabled={!dnsServers.trim()}
                confirmLoading={isLoading}
            >
                <IOSTextField
                    value={dnsServers}
                    onChange={setDnsServers}
                    placeholder="119.29.29.29"
                    monospace
                    autoFocus
                />
                <p
                    className="text-[11px] mt-2 ml-1 leading-snug"
                    style={{ color: "var(--onebox-label-secondary)" }}
                >
                    {t(
                        "dns_hint",
                        "Enter DNS server address for direct connections",
                    )}
                </p>
            </SettingsModal>
        </>
    );
}
