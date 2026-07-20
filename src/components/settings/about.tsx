import { invoke } from "@tauri-apps/api/core";
import { useEffect, useState } from "react";
import { Clipboard, InfoCircleFill } from "react-bootstrap-icons";
import { toast } from "sonner";
import { OsInfo } from "../../types/definition";
import {
  formatOsInfo,
  getOsInfo,
  getSingBoxUserAgent,
  t,
} from "../../utils/helper";
import nekoPilotLogoUrl from "../../assets/nekopilot-logo.png";
import { AppDialog, SHEET_DIALOG_MOTION } from "../common/app-dialog";
import { DialogHeader } from "../common/dialog-header";
import { InfoRow, ListRow } from "../common/list-row";
import { SectionLabel } from "../common/section-label";
import { SettingItem } from "./common";

const getVersion = async () => {
  const version = await invoke<string>("version");
  return version;
};

/**
 * iOS-style About sheet.
 *
 * Hero: app-icon tile in the systemBlue gradient + app name + version.
 * Section 1 — Device info: grouped-card rows (OS, kernel tappable to show
 * the raw version dump, User-Agent tappable to copy).
 *
 * Nested `CoreInfoSheet` replaces the old `<dialog>` element to keep
 * z-index and styling under the same roof as the rest of the About UI.
 */
export default function AboutItem() {
  const [isOpen, setIsOpen] = useState(false);

  return (
    <>
      <SettingItem
        icon={
          <InfoCircleFill size={22} style={{ color: "var(--onebox-blue)" }} />
        }
        title={t("about")}
        onPress={() => setIsOpen(true)}
      />
      <AboutSheet isOpen={isOpen} onClose={() => setIsOpen(false)} />
    </>
  );
}

function AboutSheet(
  { isOpen, onClose }: { isOpen: boolean; onClose: () => void },
) {
  const [osInfo, setOsInfo] = useState<OsInfo>({
    appVersion: "",
    osArch: "x86",
    osType: "windows",
    osVersion: "",
    osLocale: "",
  });
  const [ua, setUa] = useState<string>("");
  const [versionDump, setVersionDump] = useState<string>("");
  const [coreVersion, setCoreVersion] = useState<string>("");
  const [showCoreInfo, setShowCoreInfo] = useState(false);

  useEffect(() => {
    if (!isOpen) {
      setShowCoreInfo(false);
      return;
    }
    getOsInfo().then(setOsInfo).catch(console.error);
    getSingBoxUserAgent().then(setUa).catch(console.error);
    getVersion()
      .then((v) => {
        try {
          const core = v.split("\n")[0].trim().split(" ")[2]?.trim() ?? "";
          setCoreVersion(core);
        } catch {
          // fall back to empty core version
        }
        setVersionDump(v);
      })
      .catch(console.error);
  }, [isOpen]);

  const copyUa = () => {
    toast.promise(navigator.clipboard.writeText(ua), {
      loading: t("copying"),
      success: t("copy_success"),
      error: t("copy_error"),
    });
  };

  return (
    <>
      <AppDialog
        open={isOpen}
        onClose={onClose}
        ariaLabel={t("about")}
        placement="bottom"
        surface="detail"
        containerClassName="!px-3 pb-3"
        panelClassName="flex flex-col"
        panelStyle={{
          maxHeight: "calc(100dvh - 80px)",
          background: "var(--onebox-bg)",
        }}
        panelMotion={SHEET_DIALOG_MOTION}
      >
        <DialogHeader
          title={t("about")}
          onClose={onClose}
          className="capitalize bg-[var(--onebox-card)]"
        />

        <div className="onebox-scrollbar-hidden flex-1 overflow-y-auto">
          {/* Hero */}
          <div
            className="flex flex-col items-center pt-6 pb-7"
            style={{ background: "var(--onebox-card)" }}
          >
            {
              /* 72px squircle tile. The source PNG has ~22 px
                                    of transparent padding on every side (content
                                    bbox 212×212 / 256×256), which reads as a
                                    visible ring of window background around the
                                    blue icon. Wrap in an overflow-hidden container
                                    and scale the <img> past the container bounds
                                    so the transparent ring is clipped out — the
                                    visible outline is the container's rounded
                                    mask, filled edge-to-edge with icon blue.
                                    Shadow is a low-alpha systemBlue glow (two
                                    layers: broad halo + tight seat) to avoid
                                    competing with the hero's centre of mass. */
            }
            <div
              className="size-[72px] rounded-[20px] overflow-hidden mb-3.5"
              style={{
                boxShadow: "var(--onebox-shadow-accent)",
              }}
            >
              <img
                src={nekoPilotLogoUrl}
                alt="NekoPilot"
                className="size-full"
                style={{ transform: "scale(1.25)" }}
              />
            </div>
            <h2
              className="text-[22px] font-semibold tracking-[-0.02em]"
              style={{ color: "var(--onebox-label)" }}
            >
              NekoPilot
            </h2>
            <p
              className="text-[13px] mt-1"
              style={{
                color: "var(--onebox-label-secondary)",
              }}
            >
              {t("version")} {osInfo.appVersion}
            </p>
          </div>

          <div className="px-4 pt-5 pb-5 space-y-5">
            {/* Device info */}
            <section>
              <SectionLabel inset="card">{t("system_info")}</SectionLabel>
              <div className="onebox-grouped-card">
                <InfoRow
                  label={t("os")}
                  value={formatOsInfo(
                    osInfo.osType,
                    osInfo.osArch,
                  )}
                />
                <InfoRow
                  label={t("kernel_version")}
                  value={coreVersion}
                  compact
                  showChevron
                  onPress={() => setShowCoreInfo(true)}
                />
                <UaRow ua={ua} onCopy={copyUa} />
              </div>
            </section>
          </div>
        </div>
      </AppDialog>

      <CoreInfoSheet
        open={isOpen && showCoreInfo}
        versionDump={versionDump}
        onClose={() => setShowCoreInfo(false)}
      />
    </>
  );
}

// ---- Pieces --------------------------------------------------------------

function UaRow({ ua, onCopy }: { ua: string; onCopy: () => void }) {
  return (
    <ListRow
      compact
      title="User-Agent"
      onPress={onCopy}
      trailing={
        <div className="max-w-[160px] flex items-center gap-2">
          <span className="min-w-0 truncate text-[11px] font-mono">{ua}</span>
          <Clipboard size={13} aria-hidden="true" />
        </div>
      }
    />
  );
}

function CoreInfoSheet({
  open,
  versionDump,
  onClose,
}: {
  open: boolean;
  versionDump: string;
  onClose: () => void;
}) {
  return (
    <AppDialog
      open={open}
      onClose={onClose}
      ariaLabel={t("core_info")}
      surface="regular"
      panelClassName="flex flex-col"
      panelStyle={{ maxHeight: "calc(100dvh - 100px)" }}
    >
      <h3
        className="text-[16px] font-semibold text-center pt-4 pb-3 px-5 tracking-[-0.01em] capitalize"
        style={{ color: "var(--onebox-label)" }}
      >
        {t("core_info")}
      </h3>
      <div className="onebox-scrollbar-hidden flex-1 overflow-y-auto px-4 pb-4">
        <div
          className="rounded-xl px-3 py-2.5 text-[11px] leading-relaxed font-mono whitespace-pre-wrap break-all"
          style={{
            background: "var(--onebox-card-muted)",
            color: "var(--onebox-label-secondary)",
          }}
        >
          {versionDump}
        </div>
      </div>
      <button
        type="button"
        onClick={onClose}
        className="w-full h-11 text-[14px] font-semibold transition-colors active:bg-[var(--onebox-blue-fill-subtle)] shrink-0"
        style={{
          color: "var(--onebox-blue)",
          borderTop: "0.5px solid var(--onebox-separator)",
        }}
      >
        {t("close")}
      </button>
    </AppDialog>
  );
}
