<!--
SPDX-FileCopyrightText: 2026 AbiliSoft
SPDX-License-Identifier: Apache-2.0
-->

# Support

rules_elixir_mix is an early-stage open-source ruleset. Support is
best-effort; there is currently no commercial support contract or guaranteed
response time.

## Where to ask

- Use the **usage question** issue form for help choosing a toolchain, modeling
  a Mix application, importing dependencies, or understanding a rule.
- Use the **bug report** form when documented behavior fails with a minimal
  reproducer.
- Use the **feature request** form for a new rule or ownership contract.
- Follow [SECURITY.md](SECURITY.md) for private vulnerability reports.
- Follow [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for conduct concerns.

Start with the [documentation map](docs/README.md) and include the exact Bazel,
OTP, and Elixir versions; execution platform; relevant `MODULE.bazel` and BUILD
targets; command; and complete error output.

## Support boundaries

Maintainers can help with the ruleset's analysis, action inputs, providers,
toolchain selection, generated release layout, and documented integration
contracts. They cannot debug an arbitrary application, certify a crypto
provider, publish a third-party runtime archive, or support an undeclared host
environment.

Questions with a small public reproduction are much more likely to receive a
useful answer.
