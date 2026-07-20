import { motion } from "framer-motion";
import { type ReactNode, useEffect, useMemo, useRef, useState } from "react";
import {
  Pencil,
  Plus,
  QuestionCircle,
  XCircleFill,
} from "react-bootstrap-icons";
import { toast } from "sonner";
import {
  AppDialog,
  BOTTOM_SHEET_MOTION,
} from "../components/common/app-dialog";
import { IOSTextField } from "../components/common/ios-text-field";
import { DialogHeader } from "../components/common/dialog-header";
import { PageContent, PageLayout } from "../components/common/page-layout";
import { SectionLabel } from "../components/common/section-label";
import { HelpModal } from "../components/router-settings/help-modal";
import {
  isValidIpCidr,
  kindsInClass,
  RULE_ACTIONS,
  RULE_KINDS,
  type RuleAction,
  type RuleKind,
} from "../config/merger/custom-rules";
import { getCustomRuleSet, setCustomRuleSet } from "../single/store";
import { useEngineState } from "../hooks/useEngineState";
import { t, vpnServiceManager } from "../utils/helper";
import {
  ACTION_COLOR,
  ACTION_TINT,
  ActionBadge,
  KIND_META,
  KindChip,
} from "../components/router-settings/rule-badges";
import {
  addRule,
  emptyRuleSets,
  type FlatRule,
  flattenRules,
  removeRule,
  type RuleSets,
  updateRule,
} from "./router-rules";

// Above this many rules, reveal the search field.
const SEARCH_THRESHOLD = 12;

export default function RouterSettings() {
  const engineState = useEngineState();
  const [sets, setSets] = useState<RuleSets>(emptyRuleSets);
  const setsRef = useRef<RuleSets>(emptyRuleSets());
  const persistInFlightRef = useRef(false);
  const [isSaving, setIsSaving] = useState(false);
  const [loadState, setLoadState] = useState<"loading" | "ready" | "error">(
    "loading",
  );
  const [loadAttempt, setLoadAttempt] = useState(0);
  const [showHelp, setShowHelp] = useState(false);
  const [search, setSearch] = useState("");
  const [justChanged, setJustChanged] = useState<string | null>(null);

  // Add composer — its own state; action/kind persist across adds for batch entry.
  const [addOpen, setAddOpen] = useState(false);
  const [action, setAction] = useState<RuleAction>("direct");
  const [kind, setKind] = useState<RuleKind>("domain");
  const [input, setInput] = useState("");

  // Edit composer — its own state; seeded from the row being edited.
  const [editOpen, setEditOpen] = useState(false);
  const [editOriginal, setEditOriginal] = useState<FlatRule | null>(null);
  const [editAction, setEditAction] = useState<RuleAction>("direct");
  const [editKind, setEditKind] = useState<RuleKind>("domain");
  const [editValue, setEditValue] = useState("");

  useEffect(() => {
    let cancelled = false;
    const load = async () => {
      setLoadState("loading");
      try {
        const [direct, proxy] = await Promise.all([
          getCustomRuleSet("direct"),
          getCustomRuleSet("proxy"),
        ]);
        if (cancelled) return;
        const loaded = { direct, proxy };
        setsRef.current = loaded;
        setSets(loaded);
        setLoadState("ready");
      } catch {
        if (cancelled) return;
        setLoadState("error");
        toast.error(t("load_rules_failed", "Failed to load rules"));
      }
    };
    void load();
    return () => {
      cancelled = true;
    };
  }, [loadAttempt]);

  const allRules = useMemo(() => flattenRules(sets), [sets]);
  const visibleRules = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (!q) return allRules;
    return allRules.filter((r) => r.value.toLowerCase().includes(q));
  }, [allRules, search]);

  // Persist the next sets and write every affected action's store key. Edit
  // can move a rule between two actions, so callers pass all touched actions.
  const applyRulesLive = async () => {
    // The native lifecycle gate serializes every write-triggered reload so
    // the latest saved rule set is never dropped by a racing edit.
    if (engineState.kind !== "running") return;
    await vpnServiceManager.syncAndReload(0);
  };

  const persist = async (next: RuleSets, actions: RuleAction[]) => {
    if (loadState !== "ready") return false;
    if (persistInFlightRef.current) {
      toast.info(t("saving", "Saving..."));
      return false;
    }
    persistInFlightRef.current = true;
    setIsSaving(true);
    const previous = setsRef.current;
    const uniqueActions = [...new Set(actions)];
    setsRef.current = next;
    setSets(next);
    try {
      const writes = await Promise.allSettled(
        uniqueActions.map((a) => setCustomRuleSet(a, next[a])),
      );
      const failedWrite = writes.find((result) => result.status === "rejected");
      if (failedWrite?.status === "rejected") throw failedWrite.reason;
    } catch (error) {
      // An edit can touch both stores. If one write won the race before the
      // other failed, restore every touched action to keep disk and UI equal.
      const rollback = await Promise.allSettled(
        uniqueActions.map((a) => setCustomRuleSet(a, previous[a])),
      );
      if (rollback.some((result) => result.status === "rejected")) {
        console.error("Failed to roll back partially saved rules", rollback);
      }
      setsRef.current = previous;
      setSets(previous);
      console.error("Failed to save rules:", error);
      toast.error(t("save_failed", "Save failed"));
      return false;
    } finally {
      persistInFlightRef.current = false;
      setIsSaving(false);
    }
    void applyRulesLive().catch((error) => {
      console.error("Failed to apply rules live:", error);
      toast.error(
        t(
          "rules_live_apply_failed",
          "Rules were saved but could not be applied live",
        ),
      );
    });
    return true;
  };

  const handleAdd = async () => {
    // A flat model makes bulk import free: split on newlines / commas so a
    // pasted list becomes one rule per token, all sharing the explicit
    // action + kind (no error-prone auto-detection).
    const tokens = input
      .split(/[\n,]+/)
      .map((s) => s.trim())
      .filter(Boolean);
    if (tokens.length === 0) {
      toast.error(t("input_empty", "Input cannot be empty"));
      return;
    }
    if (kind === "ip_cidr" && tokens.some((token) => !isValidIpCidr(token))) {
      toast.error("CIDR: IPv4 /0–/32 · IPv6 /0–/128");
      return;
    }

    let next = sets;
    let added = 0;
    let dupes = 0;
    let conflict = false;
    for (const token of tokens) {
      const out = addRule(next, action, kind, token);
      if (!out.sets) {
        dupes++;
        continue;
      }
      next = out.sets;
      added++;
      if (out.conflictAction) conflict = true;
    }

    if (added === 0) {
      toast.error(t("rule_exists", "Rule already exists"));
      return;
    }

    if (!await persist(next, [action])) return;
    setInput("");
    setJustChanged(`${action}-${kind}`);

    if (added > 1 || dupes > 0) {
      toast.success(t("rules_bulk_added", { added, dupes }));
    } else if (conflict) {
      toast.success(t("rule_conflict_other_action"));
    } else {
      toast.success(t("add_success", "Added successfully"));
    }
  };

  const handleRemove = async (rule: FlatRule) => {
    const next = removeRule(sets, rule.action, rule.kind, rule.value);
    if (!await persist(next, [rule.action])) return;
    toast.success(t("delete_success", "Deleted successfully"));
  };

  const openEdit = (rule: FlatRule) => {
    setEditOriginal(rule);
    setEditAction(rule.action);
    setEditKind(rule.kind);
    setEditValue(rule.value);
    setAddOpen(false);
    setEditOpen(true);
  };

  const handleEditSave = async () => {
    if (!editOriginal) return;
    const value = editValue.trim();
    if (!value) {
      toast.error(t("input_empty", "Input cannot be empty"));
      return;
    }
    if (editKind === "ip_cidr" && !isValidIpCidr(value)) {
      toast.error("CIDR: IPv4 /0–/32 · IPv6 /0–/128");
      return;
    }
    const out = updateRule(sets, editOriginal, editAction, editKind, value);
    if (out.unchanged) {
      setEditOpen(false);
      return;
    }
    if (!out.sets) {
      toast.error(t("rule_exists", "Rule already exists"));
      return;
    }
    if (!await persist(out.sets, [editOriginal.action, editAction])) return;
    setJustChanged(`${editAction}-${editKind}`);
    toast.success(
      out.conflictAction
        ? t("rule_conflict_other_action")
        : t("save_success", "Saved successfully"),
    );
    setEditOpen(false);
  };

  const openAdd = () => {
    setEditOpen(false);
    setAddOpen(true);
  };

  return (
    <PageLayout>
      <HelpModal isOpen={showHelp} onClose={() => setShowHelp(false)} />

      <PageContent className="!pb-6">
        {/* List header — count + help. */}
        <SectionLabel
          className="mb-1.5"
          trailing={
            <div className="flex items-center gap-2">
              {isSaving && (
                <span
                  role="status"
                  className="text-[11px] font-medium"
                  style={{ color: "var(--onebox-blue)" }}
                >
                  {t("saving", "Saving...")}
                </span>
              )}
              <button
                type="button"
                onClick={() => setShowHelp(true)}
                className="p-1 rounded-full transition-colors active:bg-[var(--onebox-blue-fill-subtle)]"
                aria-label={t("rule_info_title", "Rule Information")}
              >
                <QuestionCircle
                  size={13}
                  style={{ color: "var(--onebox-label-secondary)" }}
                />
              </button>
            </div>
          }
        >
          {t("custom_rules_count_label", "Custom Rules")}
          {` · ${allRules.length}`}
        </SectionLabel>

        {allRules.length > SEARCH_THRESHOLD && (
          <div className="mb-2">
            <IOSTextField
              label={t("filter_placeholder", "Filter keyword...")}
              value={search}
              onChange={setSearch}
              placeholder={t("filter_placeholder", "Filter keyword...")}
              compact
              monospace
            />
          </div>
        )}

        {/* The list always ends with an "add rule" row — the only add entry. */}
        <div
          className="onebox-grouped-card"
          aria-busy={loadState === "loading" || isSaving}
        >
          {loadState === "loading" && (
            <div
              className="px-4 py-3 text-[13px]"
              style={{ color: "var(--onebox-label-secondary)" }}
            >
              {t("loading")}
            </div>
          )}
          {loadState === "error" && (
            <div className="flex items-center gap-3 px-4 py-3">
              <span
                className="min-w-0 flex-1 text-[13px]"
                style={{ color: "var(--onebox-label-secondary)" }}
              >
                {t("load_rules_failed", "Failed to load rules")}
              </span>
              <button
                type="button"
                className="text-[13px] font-medium"
                style={{ color: "var(--onebox-blue)" }}
                onClick={() => setLoadAttempt((value) => value + 1)}
              >
                {t("retry")}
              </button>
            </div>
          )}
          {loadState === "ready" && visibleRules.map((rule) => (
            <RuleRow
              key={`${rule.action}-${rule.kind}-${rule.value}`}
              rule={rule}
              fresh={justChanged === `${rule.action}-${rule.kind}`}
              disabled={isSaving}
              onEdit={() => openEdit(rule)}
              onRemove={() => void handleRemove(rule)}
            />
          ))}
          {loadState === "ready" && search.trim().length > 0 &&
            visibleRules.length === 0 && (
            <div
              className="px-3 py-3 text-center text-[13px]"
              style={{ color: "var(--onebox-label-tertiary)" }}
            >
              {t("no_matching_rules", "No matching rules")}
            </div>
          )}
          {loadState === "ready" && (
            <AddRuleRow disabled={isSaving} onClick={openAdd} />
          )}
        </div>

        <p
          className="px-1 mt-3 text-[11px] leading-snug"
          style={{ color: "var(--onebox-label-secondary)" }}
        >
          {t(
            "rules_effective_info",
            "Applies live while connected in Rules mode; otherwise on next connection",
          )}
        </p>
      </PageContent>

      <AddRuleSheet
        open={addOpen}
        onClose={() => setAddOpen(false)}
        action={action}
        onActionChange={setAction}
        kind={kind}
        onKindChange={setKind}
        input={input}
        onInputChange={setInput}
        onAdd={handleAdd}
        saving={isSaving}
      />
      <EditRuleSheet
        open={editOpen}
        onClose={() => setEditOpen(false)}
        original={editOriginal}
        action={editAction}
        onActionChange={setEditAction}
        kind={editKind}
        onKindChange={setEditKind}
        value={editValue}
        onValueChange={setEditValue}
        onSave={handleEditSave}
        saving={isSaving}
      />
    </PageLayout>
  );
}

function RuleRow({
  rule,
  fresh,
  disabled,
  onEdit,
  onRemove,
}: {
  rule: FlatRule;
  fresh: boolean;
  disabled: boolean;
  onEdit: () => void;
  onRemove: () => void;
}) {
  return (
    <motion.div
      className="group flex items-center gap-2 px-3 py-2.5"
      initial={fresh ? { backgroundColor: ACTION_TINT[rule.action] } : false}
      animate={{ backgroundColor: "transparent" }}
      transition={{ duration: 1.2, ease: "easeOut" }}
    >
      <ActionBadge action={rule.action} />
      <KindChip kind={rule.kind} />
      <span
        className="flex-1 min-w-0 text-[13px] truncate"
        style={{
          color: "var(--onebox-label)",
          fontFamily: '"SF Mono", ui-monospace, "Menlo", monospace',
        }}
      >
        {rule.value}
      </span>
      {/* Edit and delete use neutral gray so they stay secondary to the rule action. */}
      <button
        type="button"
        disabled={disabled}
        onClick={onEdit}
        className="shrink-0 p-1 rounded-full transition-colors active:bg-[var(--onebox-row-active)] disabled:opacity-30 disabled:cursor-not-allowed"
        aria-label={t("edit")}
      >
        <Pencil
          size={13}
          className="opacity-55 hover:opacity-95"
          style={{ color: "var(--onebox-label-secondary)" }}
        />
      </button>
      <button
        type="button"
        disabled={disabled}
        onClick={onRemove}
        className="shrink-0 p-1 rounded-full transition-colors active:bg-[var(--onebox-red-fill-subtle)] disabled:opacity-30 disabled:cursor-not-allowed"
        aria-label={t("delete")}
      >
        <XCircleFill
          size={16}
          className="opacity-55 hover:opacity-95"
          style={{ color: "var(--onebox-label-secondary)" }}
        />
      </button>
    </motion.div>
  );
}

/** The add entry — the last row of the list, styled to match a rule row. */
function AddRuleRow({
  disabled,
  onClick,
}: {
  disabled: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      disabled={disabled}
      onClick={onClick}
      className="w-full flex items-center gap-2.5 px-4 py-2.5 transition-colors active:bg-[var(--onebox-blue-fill-subtle)] disabled:opacity-40 disabled:cursor-not-allowed"
    >
      <span
        className="inline-flex items-center justify-center size-5 rounded-md shrink-0"
        style={{
          background: "var(--onebox-blue-fill)",
          color: "var(--onebox-blue)",
        }}
      >
        <Plus size={14} />
      </span>
      <span
        className="text-[13px] font-medium"
        style={{ color: "var(--onebox-blue)" }}
      >
        {t("add_rule", "Add Rule")}
      </span>
    </button>
  );
}

// ── Add composer ──────────────────────────────────────────────────────────
// Owns: all-action picker, all-kind picker, bulk-paste input, add-and-stay.
function AddRuleSheet({
  open,
  onClose,
  action,
  onActionChange,
  kind,
  onKindChange,
  input,
  onInputChange,
  onAdd,
  saving,
}: {
  open: boolean;
  onClose: () => void;
  action: RuleAction;
  onActionChange: (a: RuleAction) => void;
  kind: RuleKind;
  onKindChange: (k: RuleKind) => void;
  input: string;
  onInputChange: (v: string) => void;
  onAdd: () => void;
  saving: boolean;
}) {
  return (
    <BottomSheet
      open={open}
      onClose={onClose}
      title={t("add_rule", "Add Rule")}
      busy={saving}
    >
      <div className="px-4 pb-4 space-y-3">
        <div>
          <Label text={t("rule_action", "Action")} />
          <ActionSegmented
            value={action}
            onChange={onActionChange}
            disabled={saving}
          />
        </div>

        <div>
          <Label text={t("rule_match", "Match")} />
          <Segmented
            options={RULE_KINDS.map((k) => ({ id: k, label: t(`kind_${k}`) }))}
            value={kind}
            onChange={(v) => onKindChange(v as RuleKind)}
            ariaLabel={t("rule_match", "Match")}
            disabled={saving}
          />
        </div>

        <div className="flex gap-2">
          <IOSTextField
            label={t("rule_match", "Match")}
            className="flex-1"
            value={input}
            onChange={onInputChange}
            placeholder={KIND_META[kind].placeholder}
            onSubmit={onAdd}
            disabled={saving}
            monospace
            autoFocus
          />
          <button
            type="button"
            onClick={onAdd}
            disabled={saving || !input.trim()}
            className="shrink-0 size-10 rounded-xl flex items-center justify-center transition-all active:brightness-95 disabled:opacity-40 disabled:cursor-not-allowed"
            style={{
              background: ACTION_COLOR[action],
              color: "var(--onebox-on-accent)",
            }}
            aria-label={saving ? t("saving") : t("add")}
          >
            {saving
              ? <span className="onebox-spinner onebox-spinner-ring onebox-spinner-sm" />
              : <Plus size={20} />}
          </button>
        </div>

        <PreviewLine action={action} kind={kind} value={input} />
        <PriorityHint />
      </div>
    </BottomSheet>
  );
}

// ── Edit composer ─────────────────────────────────────────────────────────
// Owns: seeded fields, class-constrained kind (domain↔suffix; ip_cidr locked),
// single-value replace via Save.
function EditRuleSheet({
  open,
  onClose,
  original,
  action,
  onActionChange,
  kind,
  onKindChange,
  value,
  onValueChange,
  onSave,
  saving,
}: {
  open: boolean;
  onClose: () => void;
  original: FlatRule | null;
  action: RuleAction;
  onActionChange: (a: RuleAction) => void;
  kind: RuleKind;
  onKindChange: (k: RuleKind) => void;
  value: string;
  onValueChange: (v: string) => void;
  onSave: () => void;
  saving: boolean;
}) {
  // Only kinds in the same class as the original are offered; a single-member
  // class (ip_cidr) renders as a locked chip — no cross-class conversion.
  const kindOptions = original ? kindsInClass(original.kind) : RULE_KINDS;

  return (
    <BottomSheet
      open={open}
      onClose={onClose}
      title={t("edit_rule", "Edit Rule")}
      busy={saving}
    >
      <div className="px-4 pb-4 space-y-3">
        <div>
          <Label text={t("rule_action", "Action")} />
          <ActionSegmented
            value={action}
            onChange={onActionChange}
            disabled={saving}
          />
        </div>

        <div>
          <Label text={t("rule_match", "Match")} />
          {kindOptions.length > 1
            ? (
              <Segmented
                options={kindOptions.map((k) => ({
                  id: k,
                  label: t(`kind_${k}`),
                }))}
                value={kind}
                onChange={(v) => onKindChange(v as RuleKind)}
                ariaLabel={t("rule_match", "Match")}
                disabled={saving}
              />
            )
            : <LockedKindChip kind={kind} />}
        </div>

        <div className="flex gap-2">
          <IOSTextField
            label={t("rule_match", "Match")}
            className="flex-1"
            value={value}
            onChange={onValueChange}
            placeholder={KIND_META[kind].placeholder}
            onSubmit={onSave}
            disabled={saving}
            monospace
            autoFocus
          />
          <button
            type="button"
            onClick={onSave}
            disabled={saving || !value.trim()}
            className="shrink-0 h-10 px-4 rounded-xl flex items-center justify-center text-[14px] font-semibold transition-all active:brightness-95 disabled:opacity-40 disabled:cursor-not-allowed"
            style={{
              background: ACTION_COLOR[action],
              color: "var(--onebox-on-accent)",
            }}
          >
            {saving ? t("saving", "Saving...") : t("save", "Save")}
          </button>
        </div>

        <PreviewLine action={action} kind={kind} value={value} />
        <PriorityHint />
      </div>
    </BottomSheet>
  );
}

// ── Shared presentational shell + atoms ───────────────────────────────────

/** Bottom-sheet chrome: backdrop, slide-up panel, grabber, title, close. */
function BottomSheet({
  open,
  onClose,
  title,
  children,
  busy,
}: {
  open: boolean;
  onClose: () => void;
  title: string;
  children: ReactNode;
  busy: boolean;
}) {
  return (
    <AppDialog
      open={open}
      onClose={onClose}
      dismissOnBackdrop={!busy}
      closeOnEscape={!busy}
      ariaLabel={title}
      placement="bottom"
      surface="sheet"
      containerClassName="!px-0"
      panelStyle={{
        paddingBottom: "env(safe-area-inset-bottom)",
      }}
      panelMotion={BOTTOM_SHEET_MOTION}
      busy={busy}
    >
      <DialogHeader
        title={title}
        onClose={onClose}
        closeDisabled={busy}
        grabber
      />
      {children}
    </AppDialog>
  );
}

/** Action picker — active label tints to the action color. */
function ActionSegmented({
  value,
  onChange,
  disabled,
}: {
  value: RuleAction;
  onChange: (a: RuleAction) => void;
  disabled: boolean;
}) {
  return (
    <Segmented
      options={RULE_ACTIONS.map((a) => ({ id: a, label: t(`action_${a}`) }))}
      value={value}
      onChange={(v) => onChange(v as RuleAction)}
      activeColor={(id) => ACTION_COLOR[id as RuleAction]}
      ariaLabel={t("rule_action", "Action")}
      disabled={disabled}
    />
  );
}

/** Live preview — reads back what this rule will do, in the action color. */
function PreviewLine({
  action,
  kind,
  value,
}: {
  action: RuleAction;
  kind: RuleKind;
  value: string;
}) {
  return (
    <p
      className="px-1 text-[12px] leading-snug"
      style={{ color: ACTION_COLOR[action] }}
    >
      {`${t(`action_${action}`)}: ${
        t(`preview_${kind}`, { v: value.trim() || KIND_META[kind].placeholder })
      }`}
    </p>
  );
}

/** First-match-wins priority reminder, shared by both composers. */
function PriorityHint() {
  return (
    <p
      className="px-1 text-[11px] leading-snug"
      style={{ color: "var(--onebox-label-tertiary)" }}
    >
      {t("rule_priority_hint")}
    </p>
  );
}

/** A non-interactive kind chip — used when the kind can't change (ip_cidr). */
function LockedKindChip({ kind }: { kind: RuleKind }) {
  return (
    <div
      className="h-7 px-3 rounded-xl inline-flex items-center gap-1.5 text-[13px]"
      style={{
        background: "var(--onebox-fill)",
        color: "var(--onebox-label-secondary)",
      }}
    >
      <span
        style={{ fontFamily: '"SF Mono", ui-monospace, "Menlo", monospace' }}
      >
        {KIND_META[kind].glyph} {KIND_META[kind].abbr}
      </span>
      <span className="opacity-50">·</span>
      <span>{t(`kind_${kind}`)}</span>
    </div>
  );
}

function Label({ text }: { text: string }) {
  return <SectionLabel>{text}</SectionLabel>;
}

/**
 * iOS-style segmented control. Single-row track with a sliding white pill
 * behind the active option. `activeColor` optionally tints the active
 * option's label (used to teach the action→color map at choice time).
 */
function Segmented<T extends string>({
  options,
  value,
  onChange,
  activeColor,
  ariaLabel,
  disabled = false,
}: {
  options: { id: T; label: string }[];
  value: T;
  onChange: (v: T) => void;
  activeColor?: (id: T) => string | undefined;
  ariaLabel: string;
  disabled?: boolean;
}) {
  return (
    <div
      className="grid gap-1 p-0.75 rounded-xl"
      role="radiogroup"
      aria-label={ariaLabel}
      aria-disabled={disabled || undefined}
      style={{
        background: "var(--onebox-card-muted)",
        gridTemplateColumns: `repeat(${options.length}, 1fr)`,
      }}
    >
      {options.map(({ id, label }) => {
        const active = value === id;
        const tint = active ? activeColor?.(id) : undefined;
        return (
          <button
            key={id}
            type="button"
            disabled={disabled}
            role="radio"
            aria-checked={active}
            tabIndex={active ? 0 : -1}
            onClick={() => onChange(id)}
            onKeyDown={(event) => {
              const isBackward = event.key === "ArrowLeft" ||
                event.key === "ArrowUp";
              const isForward = event.key === "ArrowRight" ||
                event.key === "ArrowDown";
              if (!isBackward && !isForward) return;
              event.preventDefault();
              const currentIndex = options.findIndex((option) =>
                option.id === id
              );
              const direction = isBackward ? -1 : 1;
              const nextIndex = (currentIndex + direction + options.length) %
                options.length;
              onChange(options[nextIndex].id);
              const radios = event.currentTarget.parentElement
                ?.querySelectorAll<HTMLButtonElement>('[role="radio"]');
              radios?.[nextIndex]?.focus();
            }}
            className={`h-7 text-[13px] rounded-lg tracking-[-0.005em] transition-colors disabled:opacity-50 disabled:cursor-not-allowed ${
              active ? "font-semibold" : ""
            }`}
            style={{
              background: active ? "var(--onebox-card)" : "transparent",
              color: tint
                ? tint
                : active
                ? "var(--onebox-label)"
                : "var(--onebox-label-secondary)",
              boxShadow: active ? "var(--onebox-shadow-card)" : "none",
            }}
          >
            {label}
          </button>
        );
      })}
    </div>
  );
}
