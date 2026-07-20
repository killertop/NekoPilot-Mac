import { describe, expect, it } from 'vitest';
import {
    isRuleSetEmpty,
    isValidIpCidr,
    kindClass,
    kindsInClass,
    normalizeRuleSet,
    RULE_ACTIONS,
} from '../config/merger/custom-rules';
import {
    addRule,
    emptyRuleSets,
    flattenRules,
    removeRule,
    updateRule,
    type FlatRule,
    type RuleSets,
} from '../page/router-rules';

describe('isRuleSetEmpty', () => {
    it('is true only when all three arrays are empty', () => {
        expect(isRuleSetEmpty({ domain: [], domain_suffix: [], ip_cidr: [] })).toBe(true);
        expect(isRuleSetEmpty({ domain: [], domain_suffix: [], ip_cidr: ['10.0.0.0/8'] })).toBe(false);
    });
});

describe('CIDR validation', () => {
    it('accepts valid IPv4 and IPv6 networks', () => {
        expect(isValidIpCidr('10.240.31.0/24')).toBe(true);
        expect(isValidIpCidr('2001:db8::/32')).toBe(true);
        expect(isValidIpCidr('::ffff:192.168.1.1/128')).toBe(true);
    });

    it('rejects out-of-range prefixes and invalid addresses', () => {
        expect(isValidIpCidr('10.240.31.0/255')).toBe(false);
        expect(isValidIpCidr('10.240.31.999/24')).toBe(false);
        expect(isValidIpCidr('010.240.31.0/24')).toBe(false);
        expect(isValidIpCidr('2001:db8::/129')).toBe(false);
        expect(isValidIpCidr('192.168.1.1::/64')).toBe(false);
        expect(isValidIpCidr('10.240.31.0')).toBe(false);
    });
});

describe('persisted rule normalization', () => {
    it('drops malformed entries, trims values and removes duplicates', () => {
        expect(normalizeRuleSet({
            domain: [' example.com ', 42, '', 'example.com'],
            domain_suffix: null,
            ip_cidr: ['10.0.0.0/8', 'invalid', { value: '::/0' }],
        })).toEqual({
            domain: ['example.com'],
            domain_suffix: [],
            ip_cidr: ['10.0.0.0/8'],
        });
    });
});

describe('rule actions', () => {
    it('supports direct and proxy only', () => {
        expect(RULE_ACTIONS).toEqual(['direct', 'proxy']);
    });
});

describe('router-rules list helpers', () => {
    function seeded(): RuleSets {
        const s = emptyRuleSets();
        s.proxy.domain_suffix = ['.openai.com'];
        s.proxy.domain = ['github.com'];
        s.direct.domain = ['intranet.local'];
        return s;
    }

    it('flattens and sorts by action → kind → value (priority order)', () => {
        const flat = flattenRules(seeded());
        expect(flat.map((r) => `${r.action}/${r.kind}/${r.value}`)).toEqual([
            'direct/domain/intranet.local',
            'proxy/domain/github.com',
            'proxy/domain_suffix/.openai.com',
        ]);
    });

    it('addRule appends and reports no conflict for a fresh value', () => {
        const out = addRule(emptyRuleSets(), 'direct', 'domain', 'example.com');
        expect(out.sets?.direct.domain).toEqual(['example.com']);
        expect(out.conflictAction).toBeNull();
    });

    it('addRule rejects an exact duplicate triple (sets=null)', () => {
        const out = addRule(seeded(), 'proxy', 'domain', 'github.com');
        expect(out.sets).toBeNull();
    });

    it('addRule flags a cross-action conflict but still adds', () => {
        const s = seeded(); // github.com is under proxy/domain
        const out = addRule(s, 'direct', 'domain', 'github.com');
        expect(out.sets?.direct.domain).toContain('github.com');
        expect(out.conflictAction).toBe('proxy');
    });

    it('addRule does not mutate the input sets', () => {
        const s = emptyRuleSets();
        addRule(s, 'direct', 'domain', 'example.com');
        expect(s.direct.domain).toEqual([]);
    });

    it('removeRule deletes by value, not by display index', () => {
        const s = seeded();
        const next = removeRule(s, 'proxy', 'domain', 'github.com');
        expect(next.proxy.domain).toEqual([]);
        expect(next.proxy.domain_suffix).toEqual(['.openai.com']);
        // original untouched
        expect(s.proxy.domain).toEqual(['github.com']);
    });
});

describe('kind class', () => {
    it('groups domain and domain_suffix together, ip_cidr alone', () => {
        expect(kindClass('domain')).toBe('domain');
        expect(kindClass('domain_suffix')).toBe('domain');
        expect(kindClass('ip_cidr')).toBe('ip');
    });

    it('kindsInClass returns interchangeable kinds for editing', () => {
        expect(kindsInClass('domain')).toEqual(['domain', 'domain_suffix']);
        expect(kindsInClass('domain_suffix')).toEqual(['domain', 'domain_suffix']);
        expect(kindsInClass('ip_cidr')).toEqual(['ip_cidr']);
    });
});

describe('updateRule', () => {
    function seeded(): RuleSets {
        const s = emptyRuleSets();
        s.direct.domain = ['intranet.local'];
        s.proxy.domain = ['github.com'];
        return s;
    }
    const at = (action: FlatRule['action'], kind: FlatRule['kind'], value: string): FlatRule => ({ action, kind, value });

    it('no-ops when the triple is unchanged', () => {
        const out = updateRule(seeded(), at('direct', 'domain', 'intranet.local'), 'direct', 'domain', 'intranet.local');
        expect(out.unchanged).toBe(true);
        expect(out.sets).not.toBeNull();
    });

    it('moves a rule between action sets when only the action changes', () => {
        const out = updateRule(seeded(), at('direct', 'domain', 'intranet.local'), 'proxy', 'domain', 'intranet.local');
        expect(out.unchanged).toBe(false);
        expect(out.sets?.direct.domain).toEqual([]);
        expect(out.sets?.proxy.domain).toEqual(['github.com', 'intranet.local']);
    });

    it('changes kind within the domain class and edits the value', () => {
        const out = updateRule(seeded(), at('direct', 'domain', 'intranet.local'), 'direct', 'domain_suffix', '.lan');
        expect(out.sets?.direct.domain).toEqual([]);
        expect(out.sets?.direct.domain_suffix).toEqual(['.lan']);
    });

    it('rejects an edit that collides with a different existing rule', () => {
        // proxy/github.com already exists; editing intranet.local into it collides.
        const out = updateRule(seeded(), at('direct', 'domain', 'intranet.local'), 'proxy', 'domain', 'github.com');
        expect(out.sets).toBeNull();
    });

    it('flags a cross-action conflict but still applies the edit', () => {
        // proxy/10.0.0.0/8 exists; add a direct CIDR for it via edit of another rule.
        const s = seeded();
        s.proxy.ip_cidr = ['10.0.0.0/8'];
        s.direct.ip_cidr = ['192.168.0.0/16'];
        const out = updateRule(s, at('direct', 'ip_cidr', '192.168.0.0/16'), 'direct', 'ip_cidr', '10.0.0.0/8');
        expect(out.sets?.direct.ip_cidr).toContain('10.0.0.0/8');
        expect(out.conflictAction).toBe('proxy');
    });

    it('does not mutate the input sets', () => {
        const s = seeded();
        updateRule(s, at('direct', 'domain', 'intranet.local'), 'proxy', 'domain', 'intranet.local');
        expect(s.direct.domain).toEqual(['intranet.local']);
    });
});
