<!--
SPDX-FileCopyrightText: 2026 AbiliSoft
SPDX-License-Identifier: Apache-2.0
-->

# Security policy

## Supported versions

No stable release has been published yet. Security fixes are applied to the
protected `main` branch. Until a stable release exists, consumers should pin a
Git commit that GitHub marks as verified and track security updates manually.

## Report privately

Do not open a public issue for a suspected vulnerability.

Use one of these channels:

1. [GitHub private vulnerability reporting](https://github.com/abilisoft/rules_elixir_mix/security/advisories/new)
   (preferred).
2. Email `support@abilisoft.com` with subject `rules_elixir_mix security`.

Include the affected commit or version, a minimal reproducer, the expected and
observed behavior, impact, and any known workaround. Remove credentials and
personal data from logs before attaching them.

## In scope

- A rule action reading undeclared host state, credentials, tools, runtimes, or
  network resources.
- Sandbox, runfiles, repository-rule, archive-extraction, or path-traversal
  behavior that crosses the declared Bazel boundary.
- Checksum, lockfile, dependency, toolchain, or execution-platform validation
  that can be bypassed or silently downgraded.
- Generated releases loading undeclared native libraries, provider modules,
  configuration, or executables.
- A FIPS-required path starting without FIPS, dynamically falling back, or
  reporting success when the shared runtime contract fails.
- Leakage of repository, CI, BuildBuddy, Hex, or release credentials caused by
  this ruleset or its maintained workflows.

## Out of scope

- Vulnerabilities in Erlang/OTP, Elixir, Hex packages, browsers, databases, or
  native SDKs that reproduce without this ruleset. Report those upstream.
- Provider identity, validation certificates, source provenance, and service
  indicators owned by a crypto SDK producer such as `rules_fips`.
- Vulnerabilities in an application merely built with these rules.
- General correctness bugs with no security impact; use the bug form instead.
- Claims that require an undeclared host dependency or unsupported platform.

If the ownership boundary is unclear, report privately and let the maintainers
route it.

Reports are handled on a best-effort basis while the project is pre-release.
We will coordinate disclosure with the reporter and avoid publishing exploit
details before users have a reasonable upgrade path.
