import { useEffect, useRef, useState } from "react";
import { Speedometer2 } from "react-bootstrap-icons";
import {
  getAutoSelectFastestNode,
  setAutoSelectFastestNode,
} from "../../single/store";
import {
  AUTO_SELECT_FASTEST_NODE_CHANGED_EVENT,
  DEFAULT_AUTO_SELECT_FASTEST_NODE,
} from "../../types/definition";
import { t } from "../../utils/helper";
import { ToggleSetting } from "./common";

export default function ToggleAutoSelectFastestNode() {
  const [isEnabled, setIsEnabled] = useState(DEFAULT_AUTO_SELECT_FASTEST_NODE);
  const [isSaving, setIsSaving] = useState(false);
  const didInteract = useRef(false);

  useEffect(() => {
    void getAutoSelectFastestNode()
      .then((value) => {
        if (!didInteract.current) setIsEnabled(value);
      })
      .catch((error) => {
        console.warn("Failed to load automatic node selection setting", error);
      });
  }, []);

  const handleToggle = async () => {
    if (isSaving) return;
    const previous = isEnabled;
    const next = !previous;
    didInteract.current = true;
    setIsEnabled(next);
    window.dispatchEvent(
      new CustomEvent<boolean>(AUTO_SELECT_FASTEST_NODE_CHANGED_EVENT, {
        detail: next,
      }),
    );

    try {
      setIsSaving(true);
      await setAutoSelectFastestNode(next);
    } catch (error) {
      setIsEnabled(previous);
      window.dispatchEvent(
        new CustomEvent<boolean>(AUTO_SELECT_FASTEST_NODE_CHANGED_EVENT, {
          detail: previous,
        }),
      );
      console.error("Failed to save automatic node selection setting", error);
    } finally {
      setIsSaving(false);
    }
  };

  return (
    <ToggleSetting
      icon={<Speedometer2 size={22} style={{ color: "var(--onebox-blue)" }} />}
      title={t("auto_select_fastest_node")}
      subTitle={t("auto_select_fastest_node_desc")}
      isEnabled={isEnabled}
      onToggle={handleToggle}
      disabled={isSaving}
    />
  );
}
