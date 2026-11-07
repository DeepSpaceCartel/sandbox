# Environment lifecycle for disposable sbx-<ENV> clusters in the Hetzner "sandbox-dev" project.
# Phase −1 implements these; see docs/plan.md ("Before phase 0").

OP_RUN := op run --env-file=$(CURDIR)/.env.1password --
# Default ENV from the branch name, so parallel worktrees/sessions get separate environments.
ENV ?= $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null | tr '/_' '--' | tr -cd 'a-z0-9-' | cut -c1-20)

.PHONY: help env-up env-down env-list deploy e2e check-env

help:
	@echo "ENV=$(ENV)"
	@echo "targets: env-up env-down env-list deploy e2e"

check-env:
	@test -n "$(ENV)" || { echo "ENV is empty"; exit 1; }
	@echo "$(ENV)" | grep -Eq '^[a-z0-9][a-z0-9-]{0,19}$$' || { echo "ENV must match [a-z0-9-]{1,20}"; exit 1; }

env-up env-down env-list deploy e2e: check-env
	@echo "make $@: not implemented yet (phase -1)"; exit 2
