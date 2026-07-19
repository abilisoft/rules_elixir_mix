<!--
SPDX-FileCopyrightText: 2026 AbiliSoft
SPDX-License-Identifier: Apache-2.0
-->

# Contributing to rules_elixir_mix

Thanks for helping improve hermetic Elixir builds.

## Before changing code

- Use an issue form for bugs, feature proposals, or support questions.
- Report vulnerabilities privately through [SECURITY.md](SECURITY.md).
- Open an issue first when a change adds or breaks a public rule, provider, or
  toolchain field.

## Design rules

Keep contributions aligned with four boundaries:

1. Bazel owns downloads, tools, platforms, declared inputs, isolation, and
   cache keys.
2. Mix owns Elixir application semantics, compilation, tests, and releases.
3. OTP and Elixir come from registered toolchains; host-runtime fallback is not
   supported.
4. Native and crypto producers own their artifacts and provenance; this
   ruleset consumes declared contracts.

Ordinary rules should use Starlark actions and declared Erlang or Elixir
executables. Do not add generated shell wrappers, `run_shell`, hidden network
access, or a monolithic `mix deps.get && mix compile` action.

## Make the change

- Keep targets at OTP-application granularity.
- Pin downloaded inputs with checksums.
- Preserve compile, type, and runtime dependency edges.
- Add focused analysis coverage for rule/provider behavior and an integration
  target when runtime behavior changes.
- Update the relevant guide or example without claiming untested support.

The public API is in `defs.bzl`; implementation code is in `private/`; Bzlmod
extensions are in `bzlmod/`; analysis fixtures are in `test/`; runtime coverage
is in `integration/` and `source_integration/`.

## Validate

At minimum, run:

```sh
git diff --check
bazel test //:buildifier_test
```

Also run the affected integration or source-toolchain targets. For
cache-sensitive work, repeat an identical build and confirm the second run
reuses the expected cache entries. GitHub Actions is the complete required
matrix.

## Submit

- Work on a branch and open a pull request.
- Use a Conventional Commit subject and cryptographically sign every commit.
- Do not add co-author, AI, agent, or generated-attribution trailers.
- Do not commit credentials, generated outputs, caches, personal identities,
  absolute local paths, or machine-local configuration.
- Explain compatibility, hermeticity, and cache-key consequences in the pull
  request when relevant.

Contributions are accepted under [Apache License 2.0](LICENSE). Preserve SPDX
headers on files that already use them and add the project header to new
source, workflow, and policy files.
