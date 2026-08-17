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

# Failures are collected rather than fatal, matching the CI job. Stopping at
# the first one means a change touching five modules reports the first break,
# gets fixed, reports the second, and so on — while CI, which does collect,
# shows all five at once. The two must agree or `make check` stops predicting
# the pipeline, which is the only reason this target exists.
#
# TF_DATA_DIR points somewhere other than .terraform on purpose, and it is the
# difference between this target working locally and only working in CI.
# `terraform init -backend=false` still READS the backend recorded in an
# existing .terraform, so in any environment directory where a real init has
# been run it tries to reach the state account and fails — "Error loading
# state" — before validation happens at all. CI never sees this because a fresh
# checkout has no .terraform to read.
#
# A separate data directory means validation neither reads nor writes the one
# `make plan` depends on, so running this can never disturb a configured
# environment. Validation should not care whether you have ever run init.
TF_VALIDATE_DIR := .terraform-validate

.PHONY: validate
validate: ## terraform validate every module and environment
	@set -uo pipefail; \
	failed=0; \
	for dir in terraform/modules/*/ terraform/environments/*/ bootstrap/; do \
	  [ -n "$$(find $$dir -maxdepth 1 -name '*.tf' -print -quit)" ] || continue; \
	  echo "==> $$dir"; \
	  ( cd $$dir && export TF_DATA_DIR=$(TF_VALIDATE_DIR) && \
	    terraform init -backend=false -input=false >/dev/null && terraform validate ) || failed=1; \
	done; \
	exit $$failed

# Environments are included, not just modules. Their tests are the only
# verification qa, stage and prod can be given at all — none of the three can be
# applied on this subscription, so a mocked plan is the whole of it.
#
# TF_DATA_DIR for the same reason validate needs it: `terraform init
# -backend=false` still READS the backend recorded in an existing .terraform, so
# in an environment directory where a real init has been run it tries to reach
# the state account and fails before any test runs. A separate data directory
# also means this target can never disturb the one `make plan` depends on.
#
# Every test file mocks the provider, so nothing here authenticates to Azure,
# reads state, or creates a resource.
.PHONY: test
test: ## Run terraform test for every module and environment that has tests
	@set -uo pipefail; \
	failed=0; \
	for dir in terraform/modules/*/ terraform/environments/*/; do \
	  [ -d "$${dir}tests" ] || continue; \
	  echo "==> $$dir"; \
	  ( cd $$dir && export TF_DATA_DIR=$(TF_VALIDATE_DIR) && \
	    terraform init -backend=false -input=false >/dev/null && terraform test ) || failed=1; \
	done; \
	exit $$failed

.PHONY: lint
lint: lint-tf lint-sh ## Lint everything — Terraform and shell

# Collects failures for the same reason validate does.
.PHONY: lint-tf
lint-tf: ## TFLint every module and environment
	@set -uo pipefail; \
	command -v tflint >/dev/null || { echo "tflint is not installed — see terraform/README.md" >&2; exit 1; }; \
	tflint --init >/dev/null; \
	failed=0; \
	for dir in terraform/modules/*/ terraform/environments/*/; do \
	  echo "==> $$dir"; \
	  tflint --chdir=$$dir --config=$$(pwd)/.tflint.hcl || failed=1; \
	done; \
	exit $$failed

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

# `trivy config` takes exactly ONE target. Passing two made it exit 2 on a
# usage error every time, which looks like a scan that ran and failed — so this
# target had never actually scanned anything.
#
# It now scans each directory SEPARATELY rather than passing the tree, because
# the two do not give the same answer. Scanning terraform/ as a tree reported
# nothing while scanning terraform/modules/aks alone reported a CRITICAL, which
# is why the pre-commit hook — which works per directory — failed on a finding
# this target called clean. A module is what gets reused, so a module is the
# unit that has to be clean on its own.
#
# bootstrap/ is included deliberately: CI's scan-ref is terraform/, so the
# state backend is the one thing no automated scan was ever looking at.
.PHONY: security
security: ## Trivy misconfiguration scan, per directory
	@set -uo pipefail; \
	failed=0; \
	for dir in terraform/modules/*/ terraform/environments/*/ bootstrap/; do \
	  [ -n "$$(find $$dir -maxdepth 1 -name '*.tf' -print -quit)" ] || continue; \
	  out=$$(trivy config --exit-code 1 --severity HIGH,CRITICAL "$$dir" 2>/dev/null) || { \
	    echo "==> $$dir"; echo "$$out" | grep -E '^AZU-|^AVD-' | sed 's/^/    /'; failed=1; }; \
	done; \
	if [ $$failed -eq 0 ]; then echo "trivy: clean at HIGH,CRITICAL in every directory"; fi; \
	exit $$failed

# The version CI pins, read from the workflow so there is one source of truth.
TF_CI_VERSION := $(shell grep -m1 'TF_VERSION:' .github/workflows/terraform-ci.yml | tr -d ' "' | cut -d: -f2)

# Terraform versions do not evaluate identically, and the difference is not
# cosmetic. `&&` and `||` short-circuit on newer versions and do NOT on 1.9.8,
# so an expression like `x != null && x > 0` passes locally on a recent build
# and fails outright on the pinned one — which is how qa, stage and prod came
# to fail `terraform validate` in CI while `make check` was green for days.
#
# A warning rather than a hard failure: the pinned version is what the gate
# uses, but forcing every developer onto it to run any target at all is worse
# than telling them their result may not match.
.PHONY: tf-version
tf-version: ## Warn when local terraform differs from the version CI pins
	@have=$$(terraform version | head -1 | awk '{print $$2}' | tr -d 'v'); \
	if [ "$$have" != "$(TF_CI_VERSION)" ]; then \
	  echo ""; \
	  echo "  WARNING  terraform $$have here, CI pins $(TF_CI_VERSION)."; \
	  echo "           These do not evaluate the same. && and || short-circuit on"; \
	  echo "           newer versions and not on $(TF_CI_VERSION), so a green run here"; \
	  echo "           does not prove a green pipeline. CI is the gate."; \
	  echo ""; \
	fi

# The terraform-docs version bundled in terraform-docs/gh-actions@v1. Output
# differs between versions in ways that look trivial and are not: 0.24.0 writes
# a table separator as `| ---- |` where 0.20.0 writes `|------|`. The docs job
# regenerates and fails on ANY diff, so generating with the wrong version turns
# the pipeline red for whitespace.
TFDOCS_CI_VERSION := 0.20.0

.PHONY: docs
docs: ## Regenerate the module README tables, the way CI generates them
	@set -uo pipefail; \
	command -v terraform-docs >/dev/null || { echo "terraform-docs is not installed" >&2; exit 1; }; \
	have=$$(terraform-docs --version | awk '{print $$3}' | tr -d 'v'); \
	if [ "$$have" != "$(TFDOCS_CI_VERSION)" ]; then \
	  echo ""; \
	  echo "  WARNING  terraform-docs $$have here, CI bundles $(TFDOCS_CI_VERSION)."; \
	  echo "           Table formatting differs between them and the docs job fails"; \
	  echo "           on any diff, so this will turn CI red for whitespace."; \
	  echo ""; \
	fi; \
	for dir in terraform/modules/*/; do \
	  terraform-docs markdown table --indent 2 --output-mode inject \
	    --output-file README.md "$$dir" >/dev/null; \
	done; \
	echo "regenerated $$(ls -d terraform/modules/*/ | wc -l | tr -d ' ') module READMEs"

.PHONY: check
check: tf-version fmt-check validate test lint ## Everything CI checks, in CI's order

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
	find . -type d -name '$(TF_VALIDATE_DIR)' -prune -exec rm -rf {} +
	find . -type f -name 'tfplan' -delete
