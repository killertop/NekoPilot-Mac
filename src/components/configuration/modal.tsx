import { useModalState, ValidationErrors } from "../../action/modal-state-hook";
import { t } from "../../utils/helper";
import { AppDialog } from "../common/app-dialog";
import { IOSTextField } from "../common/ios-text-field";

// ---- Form step ---------------------------------------------------------

interface FormStepProps {
  name: string;
  url: string;
  errors: ValidationErrors;
  onNameChange: (value: string) => void;
  onUrlChange: (value: string) => void;
  onClose: () => void;
  onAdd: () => void;
}

const FormStep: React.FC<FormStepProps> = ({
  name,
  url,
  errors,
  onNameChange,
  onUrlChange,
  onClose,
  onAdd,
}) => (
  <>
    <h3
      id="add-subscription-title"
      className="text-[16px] font-semibold text-center pt-5 pb-3.5 px-5 tracking-[-0.01em]"
      style={{ color: "var(--onebox-label)" }}
    >
      {t("add_subscription")}
    </h3>
    <div className="px-4 pb-4 space-y-2.5">
      <IOSTextField
        label={t("name_placeholder_1")}
        placeholder={t("name_placeholder_1")}
        value={name}
        onChange={onNameChange}
        error={errors.name}
      />
      <IOSTextField
        label={t("subscription_url")}
        placeholder={t("name_placeholder_2")}
        value={url}
        onChange={onUrlChange}
        error={errors.url}
        autoFocus
        onSubmit={onAdd}
      />
      <p
        className="px-1 text-[11px] leading-snug"
        style={{ color: "var(--onebox-label-tertiary)" }}
      >
        {t("local_proxy_protocols")}
      </p>
    </div>
    <div
      className="grid grid-cols-2"
      style={{ borderTop: "0.5px solid var(--onebox-separator)" }}
    >
      <button
        type="button"
        className="h-11 text-[14px] transition-colors active:bg-[var(--onebox-row-active)]"
        style={{ color: "var(--onebox-blue)" }}
        onClick={onClose}
      >
        {t("close")}
      </button>
      <button
        type="button"
        className="h-11 text-[14px] font-semibold transition-colors active:bg-[var(--onebox-blue-fill-subtle)]"
        style={{
          color: "var(--onebox-blue)",
          borderLeft: "0.5px solid var(--onebox-separator)",
        }}
        onClick={onAdd}
      >
        {t("add")}
      </button>
    </div>
  </>
);

// ---- Trigger + dialog --------------------------------------------------

/**
 * Hook that returns an `openModal` callback and a ready-to-render
 * `ModalElement`. Submit hands the URL off to the apply=1 pipeline
 * (NavContext.setDeepLinkApplyUrl + setActiveScreen('home')) — Home's
 * DeepLinkApplyProgressModal then drives the full init → import →
 * start → done flow, so manual add and deep-link apply=1 share the
 * same modal UI *and* behaviour.
 */
export function useSubscriptionModalController() {
  const {
    open,
    name,
    url,
    errors,
    openModal,
    closeModal,
    onNameChange,
    onUrlChange,
    submit,
  } = useModalState();
  const ModalElement = (
    <AppDialog
      open={open}
      onClose={closeModal}
      labelledBy="add-subscription-title"
      surface="compact"
      panelMotion={{
        initial: { scale: 0.92, y: 8 },
        animate: { scale: 1, y: 0 },
        exit: { scale: 0.94, y: 4 },
        transition: { duration: 0.22, ease: [0.32, 0.72, 0, 1] },
      }}
    >
      <FormStep
        name={name}
        url={url}
        errors={errors}
        onNameChange={onNameChange}
        onUrlChange={onUrlChange}
        onClose={closeModal}
        onAdd={submit}
      />
    </AppDialog>
  );

  return { openModal: () => openModal(), ModalElement };
}
