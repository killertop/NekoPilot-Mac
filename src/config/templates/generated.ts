// Generated snapshot committed with NekoPilot for Mac.
// Validate: deno task sync-templates
//
// Source:  https://github.com/killertop/NekoPilot-Mac/blob/main/src/config/templates/generated.ts
// Branch:  main
// Commit:  aff3945e8c97add816707f258a75482797d400e2
// Built:   2026-07-18T08:51:03.809Z
// sing-box: v1.13.14

import type { configType } from '../common';

export const BUILD_TIME_TEMPLATE_SOURCE = {
    repo: 'killertop/NekoPilot-Mac',
    branch: 'main',
    commit: 'aff3945e8c97add816707f258a75482797d400e2',
    versionPath: '1.13.8',
    singBoxVersion: 'v1.13.14',
    generatedAt: '2026-07-18T08:51:03.811Z',
} as const;

export const MIXED_TEMPLATE = {
    "log": {
        "disabled": false,
        "level": "debug",
        "timestamp": false
    },
    "dns": {
        "servers": [
            {
                "tag": "system",
                "type": "udp",
                "server": "119.29.29.29",
                "server_port": 53,
                "connect_timeout": "5s"
            },
            {
                "tag": "dns_proxy",
                "type": "tcp",
                "server": "1.0.0.1",
                "server_port": 53,
                "detour": "ExitGateway",
                "connect_timeout": "5s"
            }
        ],
        "rules": [
            {
                "query_type": [
                    "HTTPS",
                    "SVCB",
                    "PTR"
                ],
                "action": "reject"
            },
            {
                "domain": [
                    "captive.apple.com",
                    "captive.apple.com",
                    "nmcheck.gnome.org",
                    "www.msftconnecttest.com",
                    "connectivitycheck.gstatic.com",
                    "sequoia.apple.com",
                    "seed-sequoia.siri.apple.com"
                ],
                "rule_set": [
                    "geoip-cn",
                    "geosite-cn",
                    "geosite-apple",
                    "geosite-microsoft-cn",
                    "geosite-samsung",
                    "geosite-private"
                ],
                "strategy": "prefer_ipv4",
                "server": "system"
            }
        ],
        "final": "dns_proxy",
        "strategy": "prefer_ipv4"
    },
    "inbounds": [
        {
            "tag": "mixed",
            "type": "mixed",
            "listen": "127.0.0.1",
            "listen_port": 6789,
            "set_system_proxy": false
        }
    ],
    "route": {
        "rules": [
            {
                "action": "sniff"
            },
            {
                "type": "logical",
                "mode": "or",
                "rules": [
                    {
                        "protocol": "dns"
                    },
                    {
                        "port": 53
                    }
                ],
                "action": "hijack-dns"
            },
            {
                "protocol": "quic",
                "action": "reject"
            },
            {
                "ip_is_private": true,
                "outbound": "direct"
            },
            {
                "domain": [
                    "direct-tag.nekopilot.invalid"
                ],
                "domain_suffix": [],
                "ip_cidr": [],
                "outbound": "direct"
            },
            {
                "domain": [
                    "proxy-tag.nekopilot.invalid"
                ],
                "domain_suffix": [],
                "ip_cidr": [],
                "outbound": "ExitGateway"
            },
            {
                "domain_suffix": [
                    ".oaiusercontent.com",
                    ".tiktok.com"
                ],
                "rule_set": [
                    "geosite-tiktok",
                    "geosite-linkedin",
                    "geosite-linkedin-cn"
                ],
                "outbound": "ExitGateway"
            },
            {
                "domain": [
                    "captive.apple.com",
                    "captive.apple.com",
                    "nmcheck.gnome.org",
                    "www.msftconnecttest.com",
                    "connectivitycheck.gstatic.com",
                    "sequoia.apple.com",
                    "seed-sequoia.siri.apple.com"
                ],
                "domain_suffix": [
                    "local",
                    "lan",
                    "localdomain",
                    "localhost",
                    "bypass.local",
                    ".nekopilot.invalid",
                    ".ksjhaoka.com",
                    ".mixcapp.com"
                ],
                "outbound": "direct",
                "rule_set": [
                    "geoip-cn",
                    "geosite-cn",
                    "geosite-apple",
                    "geosite-microsoft-cn",
                    "geosite-samsung",
                    "geosite-private"
                ]
            },
            {
                "process_path": [
                    "/Applications/WeChat.app/Contents/MacOS/WeChat"
                ],
                "process_path_regex": [
                    "^/System/Applications/.+"
                ],
                "outbound": "direct"
            }
        ],
        "final": "ExitGateway",
        "default_domain_resolver": "system",
        "auto_detect_interface": true,
        "rule_set": [
            {
                "tag": "geoip-cn",
                "type": "remote",
                "format": "binary",
                "url": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip/cn.srs"
            },
            {
                "tag": "geosite-linkedin",
                "type": "remote",
                "format": "binary",
                "url": "https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-linkedin.srs"
            },
            {
                "tag": "geosite-linkedin-cn",
                "type": "remote",
                "format": "binary",
                "url": "https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-linkedin@cn.srs"
            },
            {
                "tag": "geosite-cn",
                "type": "remote",
                "format": "binary",
                "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs"
            },
            {
                "tag": "geosite-apple",
                "type": "remote",
                "format": "binary",
                "url": "https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-apple.srs"
            },
            {
                "tag": "geosite-microsoft-cn",
                "type": "remote",
                "format": "binary",
                "url": "https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-microsoft@cn.srs"
            },
            {
                "tag": "geosite-samsung",
                "type": "remote",
                "format": "binary",
                "url": "https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-samsung.srs"
            },
            {
                "tag": "geosite-private",
                "type": "remote",
                "format": "binary",
                "url": "https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-private.srs"
            },
            {
                "tag": "geosite-tiktok",
                "type": "remote",
                "format": "binary",
                "url": "https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-tiktok.srs"
            }
        ]
    },
    "experimental": {
        "clash_api": {},
        "cache_file": {}
    },
    "outbounds": [
        {
            "tag": "direct",
            "type": "direct",
            "domain_resolver": "system"
        },
        {
            "tag": "ExitGateway",
            "type": "selector",
            "outbounds": [],
            "interrupt_exist_connections": true
        }
    ]
} as const;

/**
 * Built-in template fallbacks, baked at build time from a snapshot of the
 * NekoPilot repository snapshot. Values are real JS objects — the runtime consumer
 * (`src/config/templates/index.ts::getBuiltInTemplate`) stringifies them
 * when seeding the cache, so the store sees the same JSON-string form
 * every other read path does.
 *
 * Clients that can reach the network pick up fresher templates via the
 * SWR prime hook in `hooks/useSwr.ts`, so this snapshot is the floor,
 * not the ceiling — its age matches the app binary's ship date.
 */
export const BUILT_IN_TEMPLATE_OBJECTS: Record<configType, unknown> = {
    'mixed': MIXED_TEMPLATE,
};
