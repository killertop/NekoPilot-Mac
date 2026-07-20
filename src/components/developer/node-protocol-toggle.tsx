import { useEffect, useRef, useState } from "react";
import { Tag } from "react-bootstrap-icons";
import { getShowNodeProtocol, setShowNodeProtocol } from "../../single/store";
import { t } from "../../utils/helper";
import { NODE_SELECTOR_REFRESH_EVENT } from "../home/events";
import { ToggleSetting } from "../settings/common";

export default function ToggleNodeProtocol() {
  const [toggle, setToggle] = useState(false);
  const [isSaving, setIsSaving] = useState(false);
  const didInteract = useRef(false);

  useEffect(() => {
    let cancelled = false;
    const loadState = async () => {
      try {
        const state: boolean = await getShowNodeProtocol();
        if (!cancelled && !didInteract.current) setToggle(state);
      } catch {
        if (!cancelled) {
          console.warn("Error loading node protocol state, defaulting to false.");
        }
      }
    };
    void loadState();
    return () => {
      cancelled = true;
    };
  }, []);

  const handleToggle = async () => {
    if (isSaving) return;
    const next = !toggle;
    didInteract.current = true;
    setToggle(next);
    try {
      setIsSaving(true);
      await setShowNodeProtocol(next);
      window.dispatchEvent(new Event(NODE_SELECTOR_REFRESH_EVENT));
    } catch (error) {
      setToggle(toggle);
      console.error("Error saving node protocol state:", error);
    } finally {
      setIsSaving(false);
    }
  };

  return (
    <ToggleSetting
      icon={<Tag size={22} style={{ color: "var(--onebox-purple)" }} />}
      title={t("show_node_protocol")}
      subTitle={t("show_node_protocol_desc")}
      isEnabled={toggle}
      onToggle={handleToggle}
      disabled={isSaving}
    />
  );
}
