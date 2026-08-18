# Testing

What is verified, what is not, and how the difference was established rather
than assumed. The summary is in the [root README](../README.md); this is the
reasoning behind it.

Nothing here touches Azure. Every suite uses `mock_provider`, so the whole of
it runs with no credentials, no backend and nothing created.

| Where | Covers |
|---|---|
| `terraform/modules/*/tests/` | 296 runs — each module against its own contract |
| `terraform/environments/*/tests/` | 63 runs — the composition, and the NSG rule matrices |
| `bootstrap/tests/` | 10 runs — Phase 0, the state backend |
| [`scripts/README.md`](../scripts/README.md) | `mutation-test.py`, which measures whether the above actually guard anything |
| [`CONTRIBUTING.md`](../CONTRIBUTING.md) | The conventions for writing a new test or mutation |

---

## The three layers do different jobs

**Module tests** prove a module honours its contract. They test the
preconditions, not the provider: a test asserting that `azurerm_storage_account`
sets a name is testing HashiCorp's code.

**Environment tests** prove the composition wires those modules to each other
— that a name derived in one place reaches every consumer, that a subnet which
must not carry a default route does not, that the profile's decision reaches the
resource it governs. That layer is invisible to a module test. For `qa`, `stage`
and `prod` it is also the *only* verification available at all: none of the
three can be applied on this subscription, so a mocked plan is the whole of it.
`stage`'s suite is the only thing that executes the Azure Firewall egress path
anywhere.

**Bootstrap tests** cover the one configuration that is actually deployed and
the only one on local state, where a mistake is not recoverable by reading state
back — because the account is what holds the state.

### The NSG rule matrices

1,472 lines that are the security policy of the platform, and they had no test
of their own. The environment suites assert **reach rather than verdict**: which
source is admitted to which port, since "Allow 443 inbound" reads identically
whether the source is one subnet or the whole internet.

The tier boundary, SSH arriving only via Bastion, and the private-endpoint data
ports are each pinned. That last one is the rule that named port 6380 for months
while the platform's Managed Redis listens on 10000, silently refusing every
call from a pod to the cache.

### Plan-only, plus one apply against the mocks

Most runs are plan-only, and each environment adds one that **applies against
the mocks**. That is not for realism — the values are generated — but for reach:
anything derived from a provider-computed value is unknown at plan, so roughly
two thirds of each environment's outputs cannot be asserted there at all, and
preconditions that depend on a data source are never evaluated. The
`diagnostics` module discovers what a resource can emit before refusing to
create a setting that would enable nothing, and that check is unreachable until
apply.

Apply mode needs the mocks shaped like Azure, because the provider parses IDs
client-side before any API call. The `mock_resource` blocks at the top of each
environment's test file supply syntactically valid IDs per resource type, and
`override_resource` gives each subnet a distinct one.

### What none of it proves

That Azure accepts the plan. A mocked plan shows the configuration is
internally coherent, not that the API agrees.

---

## Measuring the tests

A passing test proves nothing on its own — it may pass whether or not the thing
it names is true. Both layers were therefore measured by breaking something and
checking that a test noticed.

### Modules: weaken the precondition

Every precondition in the repository was weakened to an always-true expression
in turn, with the suite re-run each time. **105 of 110 are confirmed that way.
The other 5 cannot fire at all**, and each is written up in its own test file:

| Precondition | Why it can never fire |
|---|---|
| `bastion`, `load-balancer` — public IP name | The public IP resource rejects a null `name` first, so Terraform stops before preconditions are evaluated |
| `monitor` — cap warning window | The variable is validated to `P1D` or `P2D`, 1440 and 2880 minutes. Every permitted value already clears the 1440 bar |
| `naming` — generated name constraints | The upstream validations bound every input, so no constructible input produces an invalid name |
| `recovery-services` — file share retention alignment | `azurerm_backup_policy_file_share` accepts `Daily` or `Hourly` only; the provider refuses `Weekly`, so there is no weekly schedule to misalign against |

None is a missing test. Each is a guard made redundant by a stricter check
earlier in the chain — worth keeping, worth not counting as coverage.

Note that "always-true" cannot mean the literal `true`. Terraform refuses both
`condition = true` in a `precondition` — *"the condition expression must refer
to at least one object from elsewhere in the configuration, or else its result
would not be checking anything"* — and a variable `validation` that does not
mention its own variable. Weakening has to keep a reference that cannot fail:
`var.days >= 0`, or `can(regex("^.*$", var.name))`.

### Environments and bootstrap: break the configuration

A composition root declares no resources, so it has no preconditions of its own
to weaken. [`scripts/mutation-test.py`](../scripts/mutation-test.py) breaks the
**configuration** instead — 84 mutations, each naming the `run` block that
claims to guard it.

**72 are caught by that run block. The other 12 are caught first by a
precondition inside a child module.** The second group is a real result rather
than a pass: the property holds, but the environment assertion is not what holds
it, which is worth knowing about an assertion whose error message says
otherwise. None is unguarded.

Two limits shape what a mutation can measure here, and both push the same way:

- **`terraform test` halts a file at the first run that *errors***, as opposed
  to one that merely fails an assertion. Any mutation that invalidates the plan
  is therefore attributed to the first run block and no later one executes. That
  is why the twelve above land where they do.
- **`expect_failures` only accepts checkable objects in the root module under
  test**, so a failure raised inside a child module cannot be named from an
  environment test at all.

Failure modes therefore stay with the module that owns them, and the environment
suites assert the positive wiring.

---

## What the measurement found

Writing the tests found five real defects, four of one kind: expressions relying
on `&&` and `||` to short-circuit, which Terraform 1.9.8 does not do. Most were
invisible to `terraform validate`, which does not evaluate those paths, and to
every environment plan, which needs credentials this repository does not have.

Measuring them afterwards found three more, which is the argument for measuring:

| Found by mutation | What was actually happening |
|---|---|
| A WAF assertion that tested nothing | `waf_posture` read the profile's *intention*, not the mode wired into the gateway. Set prod's WAF to Detection and the suite stayed green while the output still said `Prevention: matching requests are BLOCKED` |
| Two environments' next hops, transposed | `stage` pinned `10.30.0.4` against its own `10.40.0.0/16`, and `prod` the mirror image. Azure accepts an out-of-VNet next hop — that is how you reach an appliance across a peering — so the plan is clean and every workload packet leaves for an address that does not exist in that network |
| An assertion weaker than its message | bootstrap asserts its summary reports 30 days while its own input is 30, so it cannot tell a derived value from a hardcoded one |

---

## Known gaps

Stated rather than left to be discovered.

| Gap | Status |
|---|---|
| Nothing is validated against real Azure | `dev` was, and was destroyed on 2026-08-14. `qa`, `stage` and `prod` have never been applied and cannot be on this subscription |
| A UDR next hop outside its own VNet | **Closed.** The `route-table` module now checks every VirtualAppliance next hop against the VNet address space each environment passes it, and reports `next_hop_containment_checked` so a skipped check cannot read as a passed one |
| Output assertion coverage is roughly 43% | The remainder are pass-throughs where an assertion would test the provider rather than this repository |
| The mock ID scaffolding encodes provider ID parsing | A provider upgrade could still break it. Partly mitigated: the conformance checker verifies every mock id is a well-formed ARM ID and that the four environments mock the same resource types, so the common failures name the file and line instead of surfacing as "the number of segments didn't match" |
