import AboutItem from "../components/settings/about";
import ToggleAutoStart from "../components/settings/auto-start";
import ToggleAutoSelectFastestNode from "../components/settings/auto-select-fastest-node";
import DNSSettingsItem from "../components/developer/dns-settings";
import ToggleNodeProtocol from "../components/developer/node-protocol-toggle";
import UASettingsItem from "../components/developer/ua-settings";
import ToggleLan from "../components/settings/lan";
import ProxyPortSetting from "../components/settings/proxy-port";
import { PageContent, PageLayout } from "../components/common/page-layout";
import { useVersion } from "../hooks/useVersion";
import { t } from "../utils/helper";

export default function Settings() {
  const version = useVersion();

  return (
    <PageLayout>
      <PageContent>
        <div className="space-y-4">
          <div className="onebox-grouped-card">
            <ToggleAutoSelectFastestNode />
            <ToggleAutoStart />
            <ToggleLan />
            <ProxyPortSetting />
          </div>

          <div className="onebox-grouped-card">
            <DNSSettingsItem />
            <ToggleNodeProtocol />
            <UASettingsItem />
          </div>

          <div className="onebox-grouped-card">
            <AboutItem />
          </div>
        </div>

        <div
          className="text-center text-[11px] mt-6 mb-2"
          style={{ color: "var(--onebox-label-tertiary)" }}
        >
          <p>{t("version")} {version}</p>
          <p className="mt-0.5">© 2026 NekoPilot</p>
        </div>
      </PageContent>
    </PageLayout>
  );
}
