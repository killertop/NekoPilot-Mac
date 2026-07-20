import { useEffect, useRef, useState } from "react";
import { Ethernet } from "react-bootstrap-icons";
import { toast } from "sonner";
import {
  DEFAULT_PROXY_PORT,
  PROXY_PORT_CHANGED_EVENT,
} from "../../types/definition";
import {
  getProxyPort,
  getSkipSystemProxy,
  setProxyPort,
  setSkipSystemProxy,
} from "../../single/store";
import { t, vpnServiceManager } from "../../utils/helper";
import { useEngineState } from "../../hooks/useEngineState";
import { IOSTextField } from "../common/ios-text-field";
import { SettingsModal } from "../common/settings-modal";
import { SettingItem } from "./common";

function normalizePort(value: string): number | null {
  const port = Number(value.trim());
  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    return null;
  }
  return port;
}

export default function ProxyPortSetting() {
  const engineState = useEngineState();
  const [isOpen, setIsOpen] = useState(false);
  const [port, setPort] = useState(DEFAULT_PROXY_PORT.toString());
  const [currentPort, setCurrentPort] = useState(DEFAULT_PROXY_PORT);
  const [isLoading, setIsLoading] = useState(false);
  const [skipSystemProxy, setSkipSystemProxyState] = useState(false);
  const [isSavingProxyMode, setIsSavingProxyMode] = useState(false);
  const [isStateLoading, setIsStateLoading] = useState(false);
  const operationInFlightRef = useRef(false);
  const stateLoadEpochRef = useRef(0);

  const loadState = async () => {
    const epoch = ++stateLoadEpochRef.current;
    setIsStateLoading(true);
    try {
      const [savedPort, skipProxy] = await Promise.all([
        getProxyPort(),
        getSkipSystemProxy(),
      ]);
      if (epoch !== stateLoadEpochRef.current) return;
      setCurrentPort(savedPort);
      setPort(savedPort.toString());
      setSkipSystemProxyState(skipProxy);
    } catch (error) {
      if (epoch === stateLoadEpochRef.current) {
        console.error("Failed to load proxy settings", error);
        toast.error(t("proxy_settings_load_failed", "Failed to load proxy settings"));
      }
    } finally {
      if (epoch === stateLoadEpochRef.current) setIsStateLoading(false);
    }
  };

  useEffect(() => {
    void loadState();
    return () => {
      stateLoadEpochRef.current += 1;
    };
  }, []);

  useEffect(() => {
    if (!isOpen) return;
    void loadState();
    return () => {
      stateLoadEpochRef.current += 1;
    };
  }, [isOpen]);

  const handleToggleSkipProxy = async () => {
    if (
      operationInFlightRef.current || isLoading || isSavingProxyMode ||
      isStateLoading
    ) return;
    operationInFlightRef.current = true;
    const next = !skipSystemProxy;
    setSkipSystemProxyState(next);

    const saveSkipSystemProxy = async () => {
      await setSkipSystemProxy(next);
    };

    try {
      setIsSavingProxyMode(true);
      if (engineState.kind === "running") {
        await toast.promise(
          (async () => {
            await vpnServiceManager.stop();
            await saveSkipSystemProxy();
          })(),
          {
            loading: t("please_wait_releasing_resources"),
            success: t(
              "system_proxy_saved_stop_vpn",
              "System proxy setting saved, VPN stopped",
            ),
            error: t(
              "system_proxy_save_failed",
              "Failed to save system proxy setting",
            ),
          },
        );
      } else {
        await saveSkipSystemProxy();
        toast.success(t("system_proxy_saved", "System proxy setting saved"));
      }
    } catch (error) {
      setSkipSystemProxyState(!next);
      console.error("Error saving system proxy toggle state:", error);
      toast.error(
        t("system_proxy_save_failed", "Failed to save system proxy setting"),
      );
    } finally {
      operationInFlightRef.current = false;
      setIsSavingProxyMode(false);
    }
  };

  const parsedPort = normalizePort(port);
  const error = port.trim() && parsedPort === null
    ? t("proxy_port_invalid", "Port must be between 1 and 65535")
    : undefined;

  const handleSave = async () => {
    if (
      operationInFlightRef.current || isLoading || isSavingProxyMode ||
      isStateLoading
    ) return;
    if (parsedPort === null) {
      toast.error(t("proxy_port_invalid", "Port must be between 1 and 65535"));
      return;
    }

    operationInFlightRef.current = true;
    setIsLoading(true);
    try {
      const applySavedPort = () => {
        setCurrentPort(parsedPort);
        window.dispatchEvent(
          new CustomEvent<number>(PROXY_PORT_CHANGED_EVENT, {
            detail: parsedPort,
          }),
        );
      };

      if (engineState.kind === "running") {
        await toast.promise(
          (async () => {
            await vpnServiceManager.stop();
            await setProxyPort(parsedPort);
            applySavedPort();
          })(),
          {
            loading: t("please_wait_releasing_resources"),
            success: t(
              "proxy_port_saved_stop_vpn",
              "Proxy port saved, VPN stopped",
            ),
            error: t("proxy_port_save_failed", "Failed to save proxy port"),
          },
        );
      } else {
        await setProxyPort(parsedPort);
        applySavedPort();
        toast.success(t("proxy_port_saved", "Proxy port saved"));
      }
      setIsOpen(false);
    } catch {
      toast.error(t("proxy_port_save_failed", "Failed to save proxy port"));
    } finally {
      operationInFlightRef.current = false;
      setIsLoading(false);
    }
  };

  return (
    <>
      <SettingItem
        icon={<Ethernet size={22} style={{ color: "var(--onebox-orange)" }} />}
        title={t("proxy_port", "Proxy port")}
        subTitle={t("proxy_port_desc", "HTTP/SOCKS mixed inbound")}
        badge={currentPort}
        onPress={() => setIsOpen(true)}
      />
      <SettingsModal
        isOpen={isOpen}
        onClose={() => setIsOpen(false)}
        title={t("proxy_port", "Proxy port")}
        subtitle={t("proxy_port_desc", "HTTP/SOCKS mixed inbound")}
        confirmLabel={t("save")}
        onConfirm={handleSave}
        confirmDisabled={parsedPort === null || isSavingProxyMode ||
          isStateLoading}
        confirmLoading={isLoading || isSavingProxyMode || isStateLoading}
      >
        <IOSTextField
          label={t("proxy_port", "Proxy port")}
          value={port}
          onChange={(value) => setPort(value.replace(/[^\d]/g, ""))}
          placeholder={DEFAULT_PROXY_PORT.toString()}
          error={error}
          disabled={isLoading || isSavingProxyMode || isStateLoading}
          monospace
          autoFocus
          onSubmit={handleSave}
        />
        {
          <label
            className="mt-4 pt-3 flex items-center gap-3 cursor-pointer"
            style={{ borderTop: "0.5px solid var(--onebox-separator)" }}
          >
            <div className="flex-1 min-w-0">
              <div
                className="text-[14px]"
                style={{ color: "var(--onebox-label)" }}
              >
                {t("set_system_proxy")}
              </div>
              <div
                className="text-[12px] mt-0.5 leading-snug"
                style={{ color: "var(--onebox-label-secondary)" }}
              >
                {t("set_system_proxy_desc")}
              </div>
            </div>
            <input
              type="checkbox"
              className="onebox-toggle"
              checked={!skipSystemProxy}
              onChange={handleToggleSkipProxy}
              disabled={isSavingProxyMode || isLoading || isStateLoading}
            />
          </label>
        }
      </SettingsModal>
    </>
  );
}
