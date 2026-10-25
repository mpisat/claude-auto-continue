SHELL := /bin/bash
.DEFAULT_GOAL := help

LABEL := io.github.claude-ac.macos-watcher
DOMAIN := gui/$(shell id -u)
SERVICE := $(DOMAIN)/$(LABEL)
APP := $(HOME)/Applications/Claude Auto Continue.app
PLIST := $(HOME)/Library/LaunchAgents/$(LABEL).plist
MENU_LABEL := io.github.claude-ac.macos-menu
MENU_APP := $(HOME)/Applications/Claude Auto Continue Menu.app
MENU_PLIST := $(HOME)/Library/LaunchAgents/$(MENU_LABEL).plist
LOG_DIR := $(HOME)/Library/Logs/Claude Auto Continue

.PHONY: help status start stop restart logs doctor sessions menu menu-install

help:
	@printf '%s\n' \
	  'Claude Desktop auto-continue controls (macOS)' \
	  '' \
	  '  make menu      Show the menu-bar controller' \
	  '  make menu-install  Build and install the menu-bar controller' \
	  '  make status    Show whether the watcher is running and enabled at login' \
	  '  make start     Start it now and enable it at future logins' \
	  '  make stop      Stop it now and keep it off at future logins' \
	  '  make restart   Stop and start it, enabling it at future logins' \
	  '  make logs      Follow activity and error logs; Ctrl-C stops viewing' \
	  '  make doctor    Check the app, discovery and foreground permissions' \
	  '  make sessions  List available Claude Code sessions' \
	  '' \
	  'Start here: CONTROL.md. Session selection is preserved by start/stop.'

status:
	@set -euo pipefail; \
	if [[ ! -f "$(PLIST)" ]]; then \
	  printf '%s\n' 'Watcher: NOT INSTALLED' 'See mac/README.md for installation.'; exit 0; \
	fi; \
	if info="$$(launchctl print "$(SERVICE)" 2>/dev/null)"; then \
	  state="$$(printf '%s\n' "$$info" | awk '$$1 == "state" && $$2 == "=" {print $$3; exit}')"; \
	  pid="$$(printf '%s\n' "$$info" | awk '$$1 == "pid" && $$2 == "=" {print $$3; exit}')"; \
	  if [[ "$$state" == running ]]; then \
	    printf 'Watcher: ON (PID %s)\n' "$$pid"; \
	  else printf 'Watcher: NOT RUNNING (loaded, state: %s)\n' "$$state"; fi; \
	else printf '%s\n' 'Watcher: OFF (not loaded)'; fi; \
	disabled="$$(launchctl print-disabled "$(DOMAIN)" | awk '$$1 == "\"$(LABEL)\"" {print $$3}')"; \
	at_login="$$(/usr/libexec/PlistBuddy -c 'Print :RunAtLoad' "$(PLIST)")"; \
	if [[ "$$disabled" == true || "$$disabled" == disabled || "$$at_login" != true ]]; then \
	  printf '%s\n' 'Start at login: OFF'; \
	else printf '%s\n' 'Start at login: ON'; fi; \
	count="$$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$(PLIST)" | awk '$$1 == "--session" {n++} END {print n+0}')"; \
	printf 'Selected sessions: %s\n' "$$count"

start:
	@set -euo pipefail; \
	[[ -x "$(APP)/Contents/MacOS/ClaudeResume" && -f "$(PLIST)" ]] || \
	  { printf '%s\n' 'Watcher is not installed. See mac/README.md.' >&2; exit 1; }; \
	launchctl enable "$(SERVICE)"; \
	if ! launchctl print "$(SERVICE)" >/dev/null 2>&1; then \
	  launchctl bootstrap "$(DOMAIN)" "$(PLIST)"; \
	fi; \
	launchctl kickstart "$(SERVICE)"; \
	for _ in {1..25}; do \
	  state="$$(launchctl print "$(SERVICE)" 2>/dev/null | awk '$$1 == "state" && $$2 == "=" {print $$3; exit}')" || state=''; \
	  [[ "$$state" == running ]] && break; \
	  sleep 0.2; \
	done; \
	[[ "$$state" == running ]] || { printf '%s\n' 'Watcher did not start within five seconds. Check make logs.' >&2; exit 1; }
	@$(MAKE) --no-print-directory status

stop:
	@set -euo pipefail; \
	launchctl disable "$(SERVICE)"; \
	if launchctl print "$(SERVICE)" >/dev/null 2>&1; then \
	  launchctl bootout "$(SERVICE)"; \
	fi; \
	for _ in {1..25}; do \
	  if ! launchctl print "$(SERVICE)" >/dev/null 2>&1; then break; fi; \
	  sleep 0.2; \
	done; \
	if launchctl print "$(SERVICE)" >/dev/null 2>&1; then \
	  printf '%s\n' 'Watcher is still unloading after five seconds. Check make status.' >&2; exit 1; \
	fi
	@$(MAKE) --no-print-directory status

restart:
	@$(MAKE) --no-print-directory stop
	@$(MAKE) --no-print-directory start

logs:
	@tail -n 30 -F "$(LOG_DIR)/watcher.log" "$(LOG_DIR)/watcher-error.log"

doctor:
	@"$(APP)/Contents/MacOS/ClaudeResume" doctor

sessions:
	@"$(APP)/Contents/MacOS/ClaudeResume" list

menu:
	@set -euo pipefail; \
	[[ -x "$(MENU_APP)/Contents/MacOS/ClaudeMenu" && -f "$(MENU_PLIST)" ]] || \
	  { printf '%s\n' 'Menu app is not installed. Run make menu-install.' >&2; exit 1; }; \
	launchctl enable "$(DOMAIN)/$(MENU_LABEL)"; \
	if ! launchctl print "$(DOMAIN)/$(MENU_LABEL)" >/dev/null 2>&1; then \
	  launchctl bootstrap "$(DOMAIN)" "$(MENU_PLIST)"; \
	fi; \
	launchctl kickstart "$(DOMAIN)/$(MENU_LABEL)"

menu-install:
	@bash mac/install-menu.sh
