import { motion } from "framer-motion";
import { useState } from "react";
import { ArrowClockwise, CloudPlus, Plus } from "react-bootstrap-icons";
import { mutate } from "swr";
import { toast } from "sonner";
import { refreshSubscription } from "../action/subscription-hooks";
import { ListRow } from "../components/common/list-row";
import {
  PageContent,
  PageLayout,
  PageState,
} from "../components/common/page-layout";
import { SubscriptionItem } from "../components/configuration/item";
import { useSubscriptionModalController } from "../components/configuration/modal";
import { isLocalConfiguration } from "../components/configuration/subscription-metadata";
import { useSubscriptions } from "../hooks/useDB";
import { GET_SUBSCRIPTIONS_LIST_SWR_KEY } from "../types/definition";
import { t } from "../utils/helper";
import { mapSettledWithConcurrency } from "../utils/async-pool";

const SUBSCRIPTION_REFRESH_CONCURRENCY = 3;

export default function Configuration() {
  const { openModal, ModalElement } = useSubscriptionModalController();

  return (
    <PageLayout fixed>
      <div className="flex-1 min-h-0 overflow-hidden">
        <ConfigurationBody
          onAdd={openModal}
        />
      </div>
      {ModalElement}
    </PageLayout>
  );
}

function ConfigurationBody({
  onAdd,
}: {
  onAdd: () => void;
}) {
  const [expanded, setExpanded] = useState("");
  const { data, error, isLoading, mutate: retrySubscriptions } =
    useSubscriptions();

  const handleUpdateAll = async () => {
    const remoteSubscriptions = (data ?? []).filter(
      (item) => !isLocalConfiguration(item),
    );
    const results = await mapSettledWithConcurrency(
      remoteSubscriptions,
      SUBSCRIPTION_REFRESH_CONCURRENCY,
      (item) => refreshSubscription(item.identifier),
    );
    if (results.some((result) => result.status === "rejected")) {
      toast.error(t("update_subscription_failed"));
    }
    await mutate(GET_SUBSCRIPTIONS_LIST_SWR_KEY);
  };

  if (isLoading) {
    return (
      <PageState>
        <p
          className="text-sm"
          style={{ color: "var(--onebox-label-secondary)" }}
        >
          {t("loading")}
        </p>
      </PageState>
    );
  }

  if (error) {
    return (
      <PageContent className="!pb-0">
        <div className="onebox-plain-card flex items-center gap-3 px-4 py-3">
          <p
            className="min-w-0 flex-1 text-[13px]"
            style={{ color: "var(--onebox-label-secondary)" }}
          >
            {t("subscription_load_failed", "Subscription list unavailable")}
          </p>
          <button
            type="button"
            className="shrink-0 text-[13px] font-medium"
            style={{ color: "var(--onebox-blue)" }}
            onClick={() => void retrySubscriptions()}
          >
            {t("retry", "Retry")}
          </button>
        </div>
      </PageContent>
    );
  }

  if (!data || !data.length) {
    return (
      <PageState>
        <EmptyState onAdd={onAdd} />
      </PageState>
    );
  }

  return (
    <PageContent scrollable className="!pb-5">
      <ul className="onebox-grouped-card list-none p-0">
        {data.map((item) => (
          <SubscriptionItem
            key={item.identifier}
            item={item}
            expanded={expanded}
            setExpanded={setExpanded}
          />
        ))}
      </ul>

      <ActionsCard onAdd={onAdd} onUpdateAll={handleUpdateAll} />
    </PageContent>
  );
}

// iOS-style bottom action card. Two full-width rows, systemBlue labels,
// inset hairline separator (provided by .onebox-grouped-card). Sits below
// the subscription list so users see their content first, actions second.
function ActionsCard({
  onAdd,
  onUpdateAll,
}: {
  onAdd: () => void;
  onUpdateAll: () => Promise<void>;
}) {
  const [isUpdating, setIsUpdating] = useState(false);

  const handleUpdate = async () => {
    if (isUpdating) return;
    setIsUpdating(true);
    try {
      await onUpdateAll();
    } finally {
      setIsUpdating(false);
    }
  };

  return (
    <div className="onebox-grouped-card mt-4">
      <ListRow
        tone="accent"
        leading={
          <motion.div
            animate={isUpdating ? { rotate: 360 } : { rotate: 0 }}
            transition={isUpdating
              ? {
                duration: 1,
                repeat: Infinity,
                ease: "linear",
              }
              : { duration: 0.3, ease: "easeOut" }}
          >
            <ArrowClockwise
              size={18}
              style={{ color: "var(--onebox-blue)" }}
            />
          </motion.div>
        }
        title={isUpdating ? t("updating") : t("update_all_subscriptions")}
        disabled={isUpdating}
        onPress={handleUpdate}
      />
      <ListRow
        tone="accent"
        leading={<Plus size={18} style={{ color: "var(--onebox-blue)" }} />}
        title={t("add_subscription")}
        onPress={onAdd}
      />
    </div>
  );
}

function EmptyState({ onAdd }: { onAdd: () => void }) {
  return (
    <div className="flex flex-col items-center justify-center px-8 pb-14">
      <div
        className="size-16 rounded-[18px] flex items-center justify-center mb-5"
        style={{ background: "var(--onebox-blue-fill-subtle)" }}
      >
        <CloudPlus size={30} style={{ color: "var(--onebox-blue)" }} />
      </div>
      <h2
        className="text-[17px] font-semibold tracking-[-0.01em] mb-1.5"
        style={{ color: "var(--onebox-label)" }}
      >
        {t("no_subscription_config")}
      </h2>
      <p
        className="text-[13px] leading-snug text-center mb-6 max-w-[240px]"
        style={{ color: "var(--onebox-label-secondary)" }}
      >
        {t("no_subscription_hint")}
      </p>

      <button
        type="button"
        onClick={onAdd}
        className="h-10 px-5 rounded-full text-[14px] font-semibold transition-colors active:brightness-95"
        style={{
          background: "var(--onebox-blue)",
          color: "var(--onebox-on-accent)",
          boxShadow: "var(--onebox-shadow-accent)",
        }}
      >
        {t("add_subscription")}
      </button>
    </div>
  );
}
