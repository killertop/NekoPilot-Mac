import type { ReactNode } from "react";
import { ArrowClockwise, ChevronRight } from "react-bootstrap-icons";
import { RULE_ACTIONS, RULE_KINDS } from "../../config/merger/custom-rules";
import { t } from "../../utils/helper";
import { AppDialog } from "../common/app-dialog";
import { DialogHeader } from "../common/dialog-header";
import { SectionLabel } from "../common/section-label";
import { ActionBadge, KIND_META, KindChip } from "./rule-badges";

interface HelpModalProps {
  isOpen: boolean;
  onClose: () => void;
}

// iOS-style legend for the rules page. Three grouped sections — Action /
// Match / Priority — render the EXACT colored action badges and mono
// glyph-chips the user sees on rule rows (shared from rule-badges.tsx, so the
// legend can't drift from the list), plus a quiet restart footnote.
export function HelpModal({ isOpen, onClose }: HelpModalProps) {
  return (
    <AppDialog
      open={isOpen}
      onClose={onClose}
      labelledBy="rule-info-title"
      surface="regular"
      panelClassName="flex flex-col"
      panelStyle={{ maxHeight: "calc(100dvh - 80px)" }}
    >
      <DialogHeader
        title={t("rule_info_title", "Rule Information")}
        titleId="rule-info-title"
        onClose={onClose}
      />

      <div className="onebox-scrollbar-hidden flex-1 min-h-0 px-4 pb-4 space-y-4 overflow-y-auto">
        {/* Action — color-coded, in priority order. */}
        <Section label={t("rule_section_action", "Action")}>
          {RULE_ACTIONS.map((a) => (
            <div key={a} className="flex items-center gap-2.5 px-3 py-2.5">
              <ActionBadge action={a} />
              <span
                className="text-[12px] leading-snug"
                style={{ color: "var(--onebox-label-secondary)" }}
              >
                {t(`${a}_rules_info`)}
              </span>
            </div>
          ))}
        </Section>

        {/* Match — monochrome glyph-chips + example. */}
        <Section label={t("rule_section_match", "Match")}>
          {RULE_KINDS.map((k) => (
            <div key={k} className="flex items-center gap-2.5 px-3 py-2.5">
              <KindChip kind={k} />
              <span
                className="text-[13px] shrink-0"
                style={{ color: "var(--onebox-label)" }}
              >
                {t(`kind_${k}`)}
              </span>
              <span className="opacity-40 text-[12px]">·</span>
              <span
                className="text-[12px] min-w-0 truncate"
                style={{
                  color: "var(--onebox-label-tertiary)",
                  fontFamily: '"SF Mono", ui-monospace, "Menlo", monospace',
                }}
              >
                {KIND_META[k].placeholder}
              </span>
            </div>
          ))}
        </Section>

        {/* Priority — the colored order IS the lesson. */}
        <Section label={t("rule_section_priority", "Priority")}>
          <div className="px-3 py-2.5 space-y-1.5">
            <div className="flex items-center gap-1.5">
              {RULE_ACTIONS.map((a, i) => (
                <div key={a} className="flex items-center gap-1.5">
                  {i > 0 && (
                    <ChevronRight
                      size={10}
                      style={{ color: "var(--onebox-label-tertiary)" }}
                    />
                  )}
                  <ActionBadge action={a} />
                </div>
              ))}
            </div>
            <p
              className="text-[12px] leading-snug"
              style={{ color: "var(--onebox-label-secondary)" }}
            >
              {t("rule_priority_hint")}
            </p>
          </div>
        </Section>

        {/* Effect — neutral restart footnote (uncolored on purpose). */}
        <p
          className="flex items-center gap-1.5 px-1 text-[11px] leading-snug"
          style={{ color: "var(--onebox-label-secondary)" }}
        >
          <ArrowClockwise size={12} className="shrink-0" />
          {t("rules_effective_info")}
        </p>
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
        {t("close", "Close")}
      </button>
    </AppDialog>
  );
}

// A labeled grouped card — uppercase section header over a fill card whose
// rows carry the app-wide inset hairline separator.
function Section({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div>
      <SectionLabel>{label}</SectionLabel>
      <div
        className="onebox-grouped-list rounded-xl overflow-hidden"
        style={{ background: "var(--onebox-fill)" }}
      >
        {children}
      </div>
    </div>
  );
}
