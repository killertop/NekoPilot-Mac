.PHONY: update dev build bump check-versions linux-check proxy-info help

PROXY_HOST ?= 127.0.0.1
PORT ?=
PROXY_PORT ?= $(PORT)

ifneq ($(strip $(PROXY_PORT)),)
UPDATE_PROXY_ENV = HTTP_PROXY=http://$(PROXY_HOST):$(PROXY_PORT) HTTPS_PROXY=http://$(PROXY_HOST):$(PROXY_PORT) ALL_PROXY=socks5://$(PROXY_HOST):$(PROXY_PORT) http_proxy=http://$(PROXY_HOST):$(PROXY_PORT) https_proxy=http://$(PROXY_HOST):$(PROXY_PORT) all_proxy=socks5://$(PROXY_HOST):$(PROXY_PORT)
else
UPDATE_PROXY_ENV =
endif

help:
	@echo "Available targets:"
	@echo "  update       Update JS and Rust dependencies"
	@echo "               Optional: make update PORT=7890 [PROXY_HOST=127.0.0.1]"
	@echo "  dev          Start Tauri dev server"
	@echo "  build        Build the unsigned Tauri application"
	@echo "  bump         Bump the synchronized application patch version (no commit)"
	@echo "  check-versions  Verify package, Tauri, and Cargo versions match"
	@echo "  proxy-info   Print Makefile and inherited proxy environment"
	@echo "  linux-check  Run cargo check on the Linux VM with local WIP patched"

bump:
	@deno task version:bump

check-versions:
	@deno task check:versions

update:
	@$(MAKE) --no-print-directory proxy-info
	$(UPDATE_PROXY_ENV) deno task download-binaries
	$(UPDATE_PROXY_ENV) deno outdated --update
	$(UPDATE_PROXY_ENV) deno install
	cd src-tauri && $(UPDATE_PROXY_ENV) cargo update

proxy-info:
	@echo "Proxy settings:"
	@if [ -n "$(strip $(PROXY_PORT))" ]; then \
		echo "  Makefile proxy: enabled ($(PROXY_HOST):$(PROXY_PORT))"; \
	else \
		echo "  Makefile proxy: disabled (set PORT=... or PROXY_PORT=... to enable)"; \
	fi
	@echo "  Inherited environment:"
	@env | grep -E '^(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|http_proxy|https_proxy|all_proxy|NO_PROXY|no_proxy)=' || echo "    <none>"

dev:
	deno task tauri dev

build:
	deno task tauri build

# Sync the Linux VM to local HEAD, apply any WIP as a patch, and run
# cargo check on the VM. Does NOT commit or push. If the VM is offline
# the script prompts to start it manually and exits. Override the
# target host via NEKOPILOT_LINUX_VM=user@host.
linux-check:
	@scripts/linux-check.sh
