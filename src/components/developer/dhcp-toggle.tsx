import { useEffect, useState } from "react";
import { Ethernet } from "react-bootstrap-icons";
import { getUseDHCP, setUseDHCP } from "../../single/store";
import { DHCP_CHANGED_EVENT } from "../../types/definition";
import { t, vpnServiceManager } from "../../utils/helper";
import { ToggleSetting } from "../settings/common";

export default function ToggleDHCP() {
  const [toggle, setToggle] = useState(false);

  useEffect(() => {
    const loadState = async () => {
      try {
        const state: boolean = await getUseDHCP();
        setToggle(Boolean(state));
      } catch (error) {
        console.warn("Error loading DHCP state, defaulting to false.");
      }
    };
    void loadState();
  }, []);

  const handleToggle = async () => {
    try {
      const next = !toggle;
      setToggle(next);
      await setUseDHCP(next);
      window.dispatchEvent(
        new CustomEvent<boolean>(DHCP_CHANGED_EVENT, { detail: next }),
      );

      if (!await vpnServiceManager.is_running()) return;

      // 切换 DHCP 设置后需要同步并重载配置
      await vpnServiceManager.syncAndReload();
    } catch (error) {
      console.error("Failed to toggle DHCP:", error);
    }
  };

  return (
    <ToggleSetting
      icon={<Ethernet className="text-[#5856D6]" size={22} />}
      title={t("use_dhcp")}
      subTitle={t("use_dhcp_desc")}
      isEnabled={toggle}
      onToggle={handleToggle}
    />
  );
}
