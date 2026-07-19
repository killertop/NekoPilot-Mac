// Shared shape + injection logic for user custom routing rules.
//
// A custom rule is a (action, kind, value) triple:
//   action ∈ direct | proxy   — what to do with matched traffic
//   kind   ∈ domain | domain_suffix | ip_cidr — how to match it
//
// Per action we keep one RuleSet (three string arrays). Native config writing
// applies each set to the matching route rule.

export type RuleAction = 'direct' | 'proxy';
export type RuleKind = 'domain' | 'domain_suffix' | 'ip_cidr';

export interface RuleSet {
    domain: string[];
    domain_suffix: string[];
    ip_cidr: string[];
}

// Fixed iteration / display order = match priority: direct → proxy.
// sing-box is first-match-wins, so the list, action pickers, and help legend
// all follow that order.
export const RULE_ACTIONS: readonly RuleAction[] = ['direct', 'proxy'];
export const RULE_KINDS: readonly RuleKind[] = ['domain', 'domain_suffix', 'ip_cidr'];

// A kind belongs to one class. Editing may change a kind only within its
// class: domain ↔ domain_suffix is fine (both match hostnames), but neither
// can become ip_cidr (which matches addresses). The single source of truth
// for that constraint.
export type KindClass = 'domain' | 'ip';

export function kindClass(kind: RuleKind): KindClass {
    return kind === 'ip_cidr' ? 'ip' : 'domain';
}

export function kindsInClass(kind: RuleKind): RuleKind[] {
    return RULE_KINDS.filter((k) => kindClass(k) === kindClass(kind));
}

export function emptyRuleSet(): RuleSet {
    return { domain: [], domain_suffix: [], ip_cidr: [] };
}

export function isRuleSetEmpty(set: RuleSet): boolean {
    return set.domain.length === 0
        && set.domain_suffix.length === 0
        && set.ip_cidr.length === 0;
}
