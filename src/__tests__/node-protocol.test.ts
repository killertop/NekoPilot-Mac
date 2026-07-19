import { describe, expect, it } from 'vitest';
import {
    buildNodeProtocolMap,
    formatNodeProtocol,
    nodeDisplayName,
    nodeProtocolLabel,
} from '../components/home/node-protocol';

describe('node protocol helpers', () => {
    it('normalizes server proxy protocol types for display', () => {
        expect(formatNodeProtocol('VLESS')).toBe('vless');
        expect(formatNodeProtocol(' AnyTLS ')).toBe('anytls');
    });

    it('hides selector-like entries because they are not node protocols', () => {
        expect(formatNodeProtocol('Selector')).toBeUndefined();
        expect(formatNodeProtocol('URLTest')).toBeUndefined();
        expect(formatNodeProtocol('Direct')).toBeUndefined();
    });

    it('keeps internal imported-tag prefixes out of the node label', () => {
        expect(nodeDisplayName('VLESS · Tokyo 01', 'vless')).toBe('Tokyo 01');
        expect(nodeDisplayName('ANYTLS · HK', 'anytls')).toBe('HK');
        expect(nodeDisplayName('VLESS · Custom name', 'trojan')).toBe('VLESS · Custom name');
        expect(nodeDisplayName('My node', 'vless')).toBe('My node');
    });

    it('uses consistent protocol labels for the optional badge', () => {
        expect(nodeProtocolLabel('vless')).toBe('VLESS');
        expect(nodeProtocolLabel('vmess')).toBe('VMess');
        expect(nodeProtocolLabel('anytls')).toBe('AnyTLS');
    });

    it('builds a protocol map for the visible node list', () => {
        const response = {
            proxies: {
                auto: { type: 'URLTest' },
                node1: { type: 'VLESS' },
                node2: { type: 'AnyTLS' },
                hidden: { type: 'TUIC' },
            },
        };

        expect(buildNodeProtocolMap(['auto', 'node1', 'node2'], response)).toEqual({
            node1: 'vless',
            node2: 'anytls',
        });
    });

    it('tolerates malformed proxy responses', () => {
        expect(buildNodeProtocolMap(['node1'], null)).toEqual({});
        expect(buildNodeProtocolMap(['node1'], { proxies: { node1: {} } })).toEqual({});
    });
});
