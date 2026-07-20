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

function normalizedStrings(value: unknown): string[] {
    if (!Array.isArray(value)) return [];
    return Array.from(new Set(
        value
            .filter((entry): entry is string => typeof entry === 'string')
            .map((entry) => entry.trim())
            .filter(Boolean),
    ));
}

/** Normalize untrusted persisted rule data before the UI sorts or edits it. */
export function normalizeRuleSet(value: unknown): RuleSet {
    const candidate = value && typeof value === 'object' && !Array.isArray(value)
        ? value as Partial<Record<RuleKind, unknown>>
        : {};
    return {
        domain: normalizedStrings(candidate.domain),
        domain_suffix: normalizedStrings(candidate.domain_suffix),
        ip_cidr: normalizedStrings(candidate.ip_cidr).filter(isValidIpCidr),
    };
}

export function isRuleSetEmpty(set: RuleSet): boolean {
    return set.domain.length === 0
        && set.domain_suffix.length === 0
        && set.ip_cidr.length === 0;
}

function isValidIpv4Address(address: string): boolean {
    const parts = address.split('.');
    return parts.length === 4 && parts.every((part) => {
        if (!/^\d{1,3}$/.test(part)) return false;
        if (part.length > 1 && part.startsWith('0')) return false;
        const value = Number(part);
        return value >= 0 && value <= 255;
    });
}

function isValidIpv6Address(address: string): boolean {
    if (!address || address.includes('%')) return false;
    if (address.includes('.')) {
        const ipv4Tail = address.slice(address.lastIndexOf(':') + 1);
        if (!isValidIpv4Address(ipv4Tail)) return false;
    }
    try {
        // URL's bracketed-host parser implements the complete IPv6 grammar,
        // including compressed and IPv4-mapped forms, without accepting an
        // IPv4 address followed by an invalid `::` suffix.
        return new URL(`http://[${address}]/`).hostname.length > 0;
    } catch {
        return false;
    }
}

/** Validate an IP network exactly as sing-box expects it. */
export function isValidIpCidr(value: string): boolean {
    const match = value.trim().match(/^(.+)\/(\d{1,3})$/);
    if (!match) return false;
    const address = match[1];
    const prefix = Number(match[2]);
    if (address.includes(':')) {
        return prefix <= 128 && isValidIpv6Address(address);
    }
    return prefix <= 32 && isValidIpv4Address(address);
}
