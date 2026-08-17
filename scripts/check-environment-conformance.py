#!/usr/bin/env python3
"""Check that the four environments agree where they are supposed to.

The environments are near-copies of each other by design: the same modules
composed with different variable values. That is what makes them cheap to add
and what makes them drift. Every copy-paste defect found in this repository so
far was found by a person reading two files side by side, which does not scale
and does not run in CI.

Three of them reached Azure rather than staying in a comment. A rule
`description` is a real attribute of `azurerm_network_security_rule`, so
prod's NSG would have documented itself as qa's ingress path in the portal.

What this cannot do is judge whether prose is true. It checks three mechanical
properties instead:

  1. No description names a DIFFERENT environment without naming its own.
     "Empty in dev by design" sitting in prod/outputs.tf is the whole class.
     Deliberate contrasts are allowed with an explicit marker, so an exception
     is a decision someone wrote down rather than an oversight.

  2. Variables that must share a default actually do. dev's `location` said
     eastus while its three siblings said centralus, and dev is the only
     environment ever deployed — every name would have read "-eus", which
     dev/main.tf itself calls out as a bug that went unnoticed for months.

  3. The environments declare the same variables, except where the difference
     is recorded below.

Exit status is 0 when clean, 1 when anything is found. No Azure access, no
Terraform invocation: it reads the .tf files.
"""

import re
import sys
from pathlib import Path

ENVIRONMENTS = ["dev", "qa", "stage", "prod"]

ENV_ROOT = Path(__file__).resolve().parent.parent / "terraform" / "environments"

# A description that deliberately contrasts this environment with another is
# legitimate — "False means any pod can reach any internet address, which is
# dev's and qa's posture" is the point of the sentence. Mark those in the
# source rather than listing them here, so the exception lives next to the
# text it excuses and moves with it.
OPT_OUT = "conformance:cross-env-ok"

# Variables whose default must be identical in every environment. A divergence
# here is not a policy difference, it is a file someone forgot to update.
SHARED_DEFAULTS = ["location", "workload"]

# Variables that legitimately exist in some environments and not others, with
# the reason. Anything outside this map is reported.
EXPECTED_VARIABLE_DIFFERENCES = {
    "log_analytics_daily_cap_reset_hour_utc": {
        "envs": {"dev"},
        "why": "only dev caps ingestion; the others run uncapped workspaces",
    },
    "application_gateway_certificate_secret_id": {
        "envs": {"qa", "stage", "prod"},
        "why": "dev fronts the tier with a public load balancer, not an Application Gateway",
    },
}


# Resource types legitimately mocked in some environments and not others, with
# the reason. Anything outside this map is reported, because mock_resource
# defaults are per type and a forgotten one is invisible until the provider
# refuses to parse a random string.
EXPECTED_MOCK_DIFFERENCES = {
    "azurerm_firewall": {
        "envs": {"stage", "prod"},
        "why": "only stage and prod egress through an Azure Firewall",
    },
    "azurerm_firewall_policy": {
        "envs": {"stage", "prod"},
        "why": "the policy exists only where the firewall does",
    },
    "azurerm_application_gateway": {
        "envs": {"qa", "stage", "prod"},
        "why": "dev fronts the tier with a public load balancer",
    },
    "azurerm_web_application_firewall_policy": {
        "envs": {"qa", "stage", "prod"},
        "why": "the WAF policy exists only where the Application Gateway does",
    },
    "azurerm_nat_gateway": {
        "envs": {"dev", "qa"},
        "why": "stage and prod egress through the firewall instead",
    },
}


def read_descriptions(path):
    """Yield (line_number, text, opted_out) for every description in a file.

    Handles both forms Terraform allows: a quoted one-liner and a heredoc. The
    heredoc matters — the quota descriptions that claimed qa's vCPU figure in
    stage and prod were heredocs, so a check that only read quoted strings
    would have missed exactly the defect that motivated this.
    """
    lines = path.read_text().splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]

        # An opt-out marker applies to the description that follows it.
        opted_out = OPT_OUT in line or (i > 0 and OPT_OUT in lines[i - 1])

        heredoc = re.search(r"description\s*=\s*<<-?(\w+)", line)
        if heredoc:
            terminator = heredoc.group(1)
            start = i
            body = []
            i += 1
            while i < len(lines) and lines[i].strip() != terminator:
                body.append(lines[i])
                i += 1
            yield start + 1, " ".join(body), opted_out
            i += 1
            continue

        quoted = re.search(r'description\s*=\s*"((?:[^"\\]|\\.)*)"', line)
        if quoted:
            yield i + 1, quoted.group(1), opted_out

        i += 1


def check_cross_environment_names(problems):
    for env in ENVIRONMENTS:
        for path in sorted((ENV_ROOT / env).glob("*.tf")):
            for lineno, text, opted_out in read_descriptions(path):
                if opted_out:
                    continue
                others = [
                    o for o in ENVIRONMENTS
                    if o != env and re.search(rf"\b{o}\b", text)
                ]
                if others and not re.search(rf"\b{env}\b", text):
                    rel = path.relative_to(ENV_ROOT.parent.parent)
                    problems.append(
                        f"{rel}:{lineno}: description names "
                        f"{', '.join(others)} but not {env}\n"
                        f"    {text.strip()[:120]}\n"
                        f"    If the contrast is deliberate, put "
                        f"`# {OPT_OUT}` on the line above."
                    )


def variable_blocks(env):
    """Map variable name to its default literal, or None when it has none."""
    text = (ENV_ROOT / env / "variables.tf").read_text()
    found = {}
    for match in re.finditer(r'^variable\s+"([^"]+)"\s*\{', text, re.MULTILINE):
        name = match.group(1)
        # The block ends at the first line that is a closing brace in column 0.
        rest = text[match.end():]
        end = re.search(r"^\}", rest, re.MULTILINE)
        block = rest[: end.start()] if end else rest
        default = re.search(r"^\s*default\s*=\s*(.+?)\s*$", block, re.MULTILINE)
        found[name] = default.group(1) if default else None
    return found


def check_shared_defaults(problems, declared):
    for name in SHARED_DEFAULTS:
        seen = {}
        for env in ENVIRONMENTS:
            if name in declared[env]:
                seen.setdefault(declared[env][name], []).append(env)
        if len(seen) > 1:
            rendered = "; ".join(
                f"{value} in {', '.join(envs)}" for value, envs in seen.items()
            )
            problems.append(
                f"variable \"{name}\": defaults disagree across environments "
                f"({rendered}). These must match — a divergence here is a file "
                f"that was not updated, not a policy difference."
            )


def check_variable_parity(problems, declared):
    everywhere = set.intersection(*(set(declared[e]) for e in ENVIRONMENTS))
    anywhere = set.union(*(set(declared[e]) for e in ENVIRONMENTS))

    for name in sorted(anywhere - everywhere):
        present = {e for e in ENVIRONMENTS if name in declared[e]}
        expected = EXPECTED_VARIABLE_DIFFERENCES.get(name)
        if expected and expected["envs"] == present:
            continue
        if expected:
            problems.append(
                f"variable \"{name}\": expected in "
                f"{', '.join(sorted(expected['envs']))} "
                f"({expected['why']}) but found in {', '.join(sorted(present))}."
            )
        else:
            missing = sorted(set(ENVIRONMENTS) - present)
            problems.append(
                f"variable \"{name}\": declared in "
                f"{', '.join(sorted(present))} but not {', '.join(missing)}. "
                f"If that is deliberate, record it in "
                f"EXPECTED_VARIABLE_DIFFERENCES in this script."
            )


# An ARM resource ID, as the azurerm provider parses it CLIENT-SIDE before any
# API call: a subscription GUID, a resource group, and then EITHER nothing — a
# resource group ID is a scope in its own right, which is what role assignments
# and alert rules are attached to — or a provider namespace followed by one or
# more type/name pairs.
#
# The resource-group form is not a special case to be tolerated. Requiring
# /providers here reported all four environments' rg-mock as malformed on the
# first run, which is the checker being wrong about a shape the test files
# already document as deliberate.
ARM_ID = re.compile(
    r"^/subscriptions/[0-9a-fA-F-]{36}"
    r"/resourceGroups/[^/]+"
    r"(?:/providers/[A-Za-z][A-Za-z0-9.]*(?:/[^/]+/[^/]+)+)?$"
)

MOCK_RESOURCE = re.compile(r'mock_resource\s+"([a-z0-9_]+)"')
MOCK_ID = re.compile(r'\bid\s*=\s*"(/subscriptions/[^"]*)"')


def check_mock_scaffolding(problems):
    """Check the mock IDs in the environment test files.

    This is the least durable thing in the suites and the one whose failure is
    least legible. The azurerm provider parses IDs client-side, so a mock that is
    not shaped like a real ID fails with "the number of segments didn't match" —
    an error that names neither the file, the resource type, nor the mock, and
    reads as a bug in the configuration under test.

    Two things are checked, both of which turn that into a named, one-second
    failure:

      1. Every mock id that looks like an ARM ID actually is one. A typo in a
         scaffolding ID currently surfaces as a parse error against whichever
         resource happened to consume it.

      2. The four environments mock the same resource TYPES. mock_resource
         defaults are per type, so a type mocked in three environments and
         forgotten in the fourth leaves that one receiving Terraform's random
         8-character strings — which is exactly the input the provider cannot
         parse, in the environment nobody was looking at.

    What this cannot do is predict the provider's parser. If a provider upgrade
    tightens what it accepts, these mocks may still break — but the READMEs say
    so, and the mutation catalogue names the scaffolding, so the failure has
    somewhere to point.
    """
    by_env = {}

    for env in ENVIRONMENTS:
        test_dir = ENV_ROOT / env / "tests"
        types = set()

        for path in sorted(test_dir.glob("*.tftest.hcl")):
            text = path.read_text()
            types.update(MOCK_RESOURCE.findall(text))

            for line_no, line in enumerate(text.splitlines(), start=1):
                for ident in MOCK_ID.findall(line):
                    if not ARM_ID.match(ident):
                        problems.append(
                            f"{path.relative_to(ENV_ROOT.parent.parent)}:{line_no}: "
                            f"mock id is not a well-formed ARM resource ID: {ident}. "
                            f"The azurerm provider parses IDs before any API call, "
                            f"so this fails as \"the number of segments didn't "
                            f"match\" against whichever resource consumes it."
                        )

        by_env[env] = types

    everywhere = set.intersection(*(by_env[e] for e in ENVIRONMENTS))
    anywhere = set.union(*(by_env[e] for e in ENVIRONMENTS))

    for resource_type in sorted(anywhere - everywhere):
        present = sorted(e for e in ENVIRONMENTS if resource_type in by_env[e])
        absent = sorted(set(ENVIRONMENTS) - set(present))
        expected = EXPECTED_MOCK_DIFFERENCES.get(resource_type)
        if expected and set(expected["envs"]) == set(present):
            continue
        problems.append(
            f"mock_resource \"{resource_type}\": mocked in {', '.join(present)} "
            f"but not {', '.join(absent)}. mock_resource defaults are per TYPE, so "
            f"the environments without it receive random strings where a parseable "
            f"ID is needed. If the difference is deliberate, record it in "
            f"EXPECTED_MOCK_DIFFERENCES in this script."
        )


def main():
    missing = [e for e in ENVIRONMENTS if not (ENV_ROOT / e).is_dir()]
    if missing:
        print(f"environment directory not found: {', '.join(missing)}", file=sys.stderr)
        return 2

    declared = {env: variable_blocks(env) for env in ENVIRONMENTS}

    problems = []
    check_cross_environment_names(problems)
    check_shared_defaults(problems, declared)
    check_variable_parity(problems, declared)
    check_mock_scaffolding(problems)

    if problems:
        print(f"Environment conformance: {len(problems)} problem(s)\n")
        for problem in problems:
            print(f"  {problem}\n")
        return 1

    print(
        f"Environment conformance: {', '.join(ENVIRONMENTS)} agree "
        f"(descriptions, shared defaults, variable sets, mock scaffolding)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
