import { ToggleSetting } from "./common";

import { disable, enable, isEnabled } from "@tauri-apps/plugin-autostart";
import { useEffect, useState } from "react";
import { Power } from "react-bootstrap-icons";
import { toast } from "sonner";
import { t } from "../../utils/helper";

export default function ToggleAutoStart() {
  const [isOn, setIsOn] = useState(false);
  const [isSaving, setIsSaving] = useState(false);

  useEffect(() => {
    const checkAutoStart = async () => {
      try {
        const isAutoStartEnabled = await isEnabled();
        setIsOn(isAutoStartEnabled);
      } catch (error) {
        console.error("检查自动启动状态失败:", error);
        toast.error(t("auto_start_failed"));
      }
    };
    checkAutoStart();
  }, []);

  const handleToggle = async () => {
    if (isSaving) return;
    // 保存当前状态用于可能的回滚
    const previousState = isOn;

    // 乐观更新 UI
    setIsOn(!isOn);

    try {
      setIsSaving(true);
      if (!isOn) {
        await enable();
      } else {
        await disable();
      }
    } catch (error) {
      // 操作失败，回滚到之前的状态
      setIsOn(previousState);
      console.error("切换自动启动设置失败:", error);
      toast.error(t("auto_start_failed_1"));
    } finally {
      setIsSaving(false);
    }
  };

  return (
    <div>
      <ToggleSetting
        icon={<Power size={22} style={{ color: "var(--onebox-orange)" }} />}
        title={t("auto_start")}
        isEnabled={isOn}
        onToggle={handleToggle}
        disabled={isSaving}
      />
    </div>
  );
}
