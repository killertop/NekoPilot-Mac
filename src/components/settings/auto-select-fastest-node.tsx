import { useEffect, useState } from "react";
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

  useEffect(() => {
    void getAutoSelectFastestNode()
      .then(setIsEnabled)
      .catch((error) => {
        console.warn("Failed to load automatic node selection setting", error);
      });
  }, []);

  const handleToggle = async () => {
    const previous = isEnabled;
    const next = !previous;
    setIsEnabled(next);
    window.dispatchEvent(
      new CustomEvent<boolean>(AUTO_SELECT_FASTEST_NODE_CHANGED_EVENT, {
        detail: next,
      }),
    );

    try {
      await setAutoSelectFastestNode(next);
    } catch (error) {
      setIsEnabled(previous);
      window.dispatchEvent(
        new CustomEvent<boolean>(AUTO_SELECT_FASTEST_NODE_CHANGED_EVENT, {
          detail: previous,
        }),
      );
      console.error("Failed to save automatic node selection setting", error);
    }
  };

  return (
    <ToggleSetting
      icon={<Speedometer2 className="text-[#007AFF]" size={22} />}
      title={t("auto_select_fastest_node")}
      subTitle={t("auto_select_fastest_node_desc")}
      isEnabled={isEnabled}
      onToggle={handleToggle}
    />
  );
}
