import { useEffect, useState } from "react";
import { Tag } from "react-bootstrap-icons";
import { getShowNodeProtocol, setShowNodeProtocol } from "../../single/store";
import { t } from "../../utils/helper";
import { NODE_SELECTOR_REFRESH_EVENT } from "../home/events";
import { ToggleSetting } from "../settings/common";

export default function ToggleNodeProtocol() {
  const [toggle, setToggle] = useState(false);
  const [isSaving, setIsSaving] = useState(false);

  useEffect(() => {
    const loadState = async () => {
      try {
        const state: boolean = await getShowNodeProtocol();
        setToggle(state);
      } catch (error) {
        console.warn("Error loading node protocol state, defaulting to false.");
      }
    };
    loadState();
  }, []);

  const handleToggle = async () => {
    if (isSaving) return;
    const next = !toggle;
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
