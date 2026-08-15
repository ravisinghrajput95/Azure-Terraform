# cloudcart — developer entrypoints
#
# Every target here runs a check that CI also runs, so a green `make check` is
# a good predictor of a green pipeline. The point is that nobody has to
# remember which flags each tool needs.
#
# ENV selects the environment root module. Default dev, because it is the only
# one currently deployable on this subscription.

SHELL := /bin/bash
.DEFAULT_GOAL := help

ENV      ?= dev
ENV_DIR  := terraform/environments/$(ENV)
MODULES  := $(wildcard terraform/modules/*)
TFVARS   := -var-file=terraform.tfvars

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# Checks — these mirror .github/workflows/terraform-ci.yml
# ---------------------------------------------------------------------------

.PHONY: fmt
fmt: ## Rewrite all Terraform to canonical format
	terraform fmt -recursive terraform/ bootstrap/

.PHONY: fmt-check
fmt-check: ## Fail if anything is unformatted (what CI runs)
	terraform fmt -check -recursive terraform/ bootstrap/

.PHONY: validate
validate: ## terraform validate every module and environment
	@set -euo pipefail; \
	for dir in terraform/modules/*/ terraform/environments/*/ bootstrap/; do \
	  [ -n "$$(ls $$dir*.tf 2>/dev/null)" ] || continue; \
	  echo "==> $$dir"; \
	  ( cd $$dir && terraform init -backend=false -input=false >/dev/null && terraform validate ); \
	done

.PHONY: test
test: ## Run terraform test for every module that has tests
	@set -euo pipefail; \
	failed=0; \
	for dir in terraform/modules/*/; do \
	  [ -d "$${dir}tests" ] || continue; \
	  echo "==> $$dir"; \
	  ( cd $$dir && terraform init -backend=false -input=false >/dev/null && terraform test ) || failed=1; \
	done; \
	exit $$failed

.PHONY: lint
lint: lint-tf lint-sh ## Lint everything — Terraform and shell

.PHONY: lint-tf
lint-tf: ## TFLint every module and environment
	@set -euo pipefail; \
	tflint --init >/dev/null; \
	for dir in terraform/modules/*/ terraform/environments/*/; do \
	  echo "==> $$dir"; \
	  tflint --chdir=$$dir --config=$$(pwd)/.tflint.hcl; \
	done

# Check selection is in .shellcheckrc, not here — see that file for why.
#
# Discovery is by shebang as well as by extension, because a script added
# without a .sh suffix would otherwise be skipped silently, and the linter
# would go on reporting success over a file it never opened. For the same
# reason an empty file list is a failure rather than a no-op.
#
# The executable-bit check exists because this target and the pre-commit hook
# do NOT discover files the same way, and the difference is invisible.
# pre-commit's `shell` type is satisfied by a .sh suffix, or by a shebang on a
# file that is executable — a shebang alone is not enough. So a script with
# neither the suffix nor the bit is linted here and in CI, and skipped by the
# commit hook without saying so. Rather than let the two drift, the condition
# is refused outright.
.PHONY: lint-sh
lint-sh: ## ShellCheck every shell script in the repository
	@set -euo pipefail; \
	shellcheck --version | awk '/^version:/ {print "==> shellcheck " $$2}'; \
	files=$$( { git ls-files -- '*.sh'; \
	  git ls-files | while read -r f; do \
	    if [ -f "$$f" ] && head -n1 "$$f" 2>/dev/null | grep -qE '^#!.*(bash|/sh$$|env sh$$)'; then printf '%s\n' "$$f"; fi; \
	  done; } | sort -u ); \
	if [ -z "$$files" ]; then \
	  echo "no shell scripts found — shellcheck would have passed over nothing" >&2; \
	  exit 1; \
	fi; \
	echo "$$files" | sed 's/^/    /'; \
	unhookable=$$( { echo "$$files" | grep -v '\.sh$$' || true; } | while read -r f; do \
	  if [ -n "$$f" ] && [ ! -x "$$f" ]; then printf '%s\n' "$$f"; fi; \
	done ); \
	if [ -n "$$unhookable" ]; then \
	  echo "$$unhookable" | sed 's/^/    /' >&2; \
	  echo "the files above have neither a .sh suffix nor the executable bit, so the" >&2; \
	  echo "pre-commit hook will skip them silently while this target lints them." >&2; \
	  echo "chmod +x them, or give them a .sh suffix." >&2; \
	  exit 1; \
	fi; \
	echo "$$files" | xargs shellcheck

.PHONY: security
security: ## Trivy misconfiguration scan
	trivy config --exit-code 1 --severity HIGH,CRITICAL terraform/ bootstrap/

.PHONY: check
check: fmt-check validate test lint ## Everything CI checks, in CI's order

# ---------------------------------------------------------------------------
# Environment operations
#
# plan and apply need credentials and touch real infrastructure. They are
# deliberately NOT part of `check`.
# ---------------------------------------------------------------------------

.PHONY: init
init: ## terraform init for ENV (default dev)
	cd $(ENV_DIR) && terraform init -backend-config=backend.conf

.PHONY: plan
plan: ## terraform plan for ENV, saved to tfplan
	cd $(ENV_DIR) && terraform plan $(TFVARS) -out=tfplan

.PHONY: apply
apply: ## Apply the saved plan for ENV — run `make plan` first
	cd $(ENV_DIR) && terraform apply tfplan

.PHONY: drift
drift: ## Report drift for ENV without writing a plan file
	cd $(ENV_DIR) && terraform plan $(TFVARS) -detailed-exitcode

.PHONY: output
output: ## Show outputs for ENV
	cd $(ENV_DIR) && terraform output

# ---------------------------------------------------------------------------
# Housekeeping
# ---------------------------------------------------------------------------

.PHONY: clean
clean: ## Remove .terraform directories and saved plans
	find . -type d -name '.terraform' -prune -exec rm -rf {} +
	find . -type f -name 'tfplan' -delete
