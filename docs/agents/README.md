<!--
SPDX-FileCopyrightText: 2026 AbiliSoft
SPDX-License-Identifier: Apache-2.0
-->

# AI agent playbook

[Documentation home](../README.md) · [Getting started](../getting_started.md) ·
[Core concepts](../concepts.md) · [Rule catalog](../rules.md)

Use this playbook when an AI coding agent is adding `rules_elixir_mix` to an
Elixir repository or changing that repository's Bazel model. It is deliberately
procedural: inspect the project, choose the supported rule, declare every
input, and verify the result.

This is documentation, not an executable agent package. Agent systems may load
this file as project context without installing a plugin or copying a skill.

## Source-of-truth order

Do not infer APIs from the repository name or from another Elixir ruleset. Use
the first applicable source below:

1. the version of [`defs.bzl`](../../defs.bzl) pinned by the consumer;
2. the module-extension tag classes in
   [`bzlmod/toolchains.bzl`](../../bzlmod/toolchains.bzl) and
   [`bzlmod/private/elixir_packages.bzl`](../../bzlmod/private/elixir_packages.bzl);
3. the focused guide linked from the [rule catalog](../rules.md);
4. checked-in examples and integration targets using the same API;
5. current upstream Bazel, Elixir, Erlang/OTP, or package documentation.

If an attribute is absent from the pinned Starlark, do not emit it. If a
capability is not documented or tested, describe the gap instead of inventing
support.

## Inspect before editing

Read these files in the consumer repository when they exist:

- `MODULE.bazel`, `.bazelversion`, platform definitions, and Bazel config;
- every relevant `mix.exs`, `mix.lock`, and `config/*.exs`;
- umbrella child applications and their OTP application names;
- existing `BUILD.bazel` files and package boundaries;
- release configuration, `priv/`, templates, generated-source declarations,
  and asset entry points;
- native dependencies, NIFs, runtime libraries, Postgres, Chrome, and other
  external tools used by builds or tests.

Record these facts before proposing targets:

| Fact | Why it matters |
| --- | --- |
| OTP and Elixir versions | Selects the runtime and language behavior |
| Execution OS, CPU, libc, loader, and NIF closure | Defines the runtime ABI constraint |
| Mix application names and environments | Defines application-granularity targets |
| Locked package managers and checksums | Defines immutable external repositories |
| Compile-only, type-only, and runtime dependencies | Defines Bazel dependency edges |
| Native build inputs and executables | Prevents host discovery |
| Services required by tests | Determines whether a focused service test rule applies |
| Writable development tasks | Keeps local workflows out of hermetic actions |

## Integration procedure

### 1. Pin the ruleset

Use a released module version when one exists. Until this repository publishes
its first stable release, use a full, verified commit SHA as shown in
[Getting started](../getting_started.md#1-pin-the-ruleset). Never track a branch.

### 2. Define the execution platform

Define a dedicated `runtime_abi` constraint value and put it on both the
toolchain and its execution platform. OS and CPU alone are insufficient for a
native BEAM runtime. Pin any remote-execution container by immutable digest.

Stop if the runtime archive's libc, loader, NIF ABI, or native library closure
is unknown. Do not label an unverified archive as compatible.

### 3. Choose one toolchain path

| Input available | Use |
| --- | --- |
| Verified, relocatable OTP and Elixir archives | `elixir_config.prebuilt_toolchain` |
| Pristine source archives plus declared bootstrap/runtime build tools | `elixir_config.source_toolchain` |

Prefer prebuilt archives for normal CI latency. Use source toolchains when OTP
configure flags, the C/C++ toolchain, or the crypto SDK are part of the desired
artifact identity. Both paths require checksum-pinned archives and explicit
platform constraints. See [Prebuilt toolchains](../prebuilt_toolchains.md) and
[Source toolchains](../source_toolchains.md).

Never use a host OTP, Elixir, Bash, Make, Perl, compiler, or OpenSSL as an
undeclared fallback.

### 4. Import locked packages

Use `elixir_packages.mix_lock` with the checked-in `mix.lock`, then expose the
generated `hex_pm` and dependency hub repositories with `use_repo`. Ordinary
build and test actions are offline; they must not run `mix deps.get`.

Use `native_build_packages` only for specifically named locked packages that
must compile native source. Prefer `precompiled_native_artifacts` when a
checksum-pinned producer already owns the native artifact.

### 5. Model one OTP application per target

Map each application to one of these public APIs:

| Project shape | Rule |
| --- | --- |
| Mix application | `mix_library` |
| Direct Erlang/OTP application | `erlang_app` |
| Imported Rebar application | `rebar_library` |

For an umbrella, create separate targets for the child applications. Do not
stage an entire repository into one action and invoke a catch-all Mix build.

Declare source-shaped inputs explicitly:

- Elixir/Erlang sources in `srcs`;
- Mix configuration in `mix_config` and `config`;
- templates and other compile inputs in `data`;
- runtime application payload in `priv`;
- generated files through `elixir_generated_source` when they need a stable
  project-relative destination;
- NIF artifacts through `elixir_nif` or `rustler_nif`.

Follow the pinned rule definition for the exact attributes available.

### 6. Classify dependencies

| Edge | Put an application here when it is needed for |
| --- | --- |
| `compile_deps` | macros, parse transforms, compiler plugins, or compilation only |
| `type_deps` | remote type information without runtime propagation |
| `runtime_deps` | application startup, execution, tests, or release assembly |

The compatibility `deps` attribute is appended to `runtime_deps`; prefer the
specific edge in new code. Do not add everything to every edge to silence a
missing-dependency error.

Create distinct production and test `mix_library` targets when `MIX_ENV`,
configuration, support sources, or dependencies differ.

### 7. Add focused verification

Choose only checks the project actually configures:

| Need | Public API |
| --- | --- |
| ExUnit | `mix_test` or `mix_ex_unit_test` |
| EUnit / Common Test | `erlang_eunit_test` / `erlang_common_test` |
| Formatting | `mix_format_test` |
| Elixir 1.20+ compiler type analysis | `mix_typecheck_test` |
| Native cached Dialyzer | `dialyzer_plt` + `elixir_dialyzer_test` |
| Dialyxir task | `mix_dialyzer_test` |
| Credo / Sobelow / Xref | matching `mix_*_test` rule |
| Mix or LCOV coverage | `mix_coverage_test` / `mix_lcov_test` |
| Isolated Postgres | `mix_ecto_test` with declared executables |
| Wallaby | `mix_wallaby_test` with declared Chrome and ChromeDriver |

Do not add Credo, Sobelow, Dialyxir, ExCoveralls, Wallaby, or ElixirLS merely
because a rule exists. The corresponding Mix dependency and project
configuration must also exist.

### 8. Add Phoenix and release behavior deliberately

Phoenix and LiveView remain locked Mix dependencies, not toolchains.

- Build JavaScript and CSS with the appropriate Bazel ecosystem rules.
- Use `mix_phx_assets` or `mix_phx_digest` for cacheable `phx.digest` output.
- Feed the digested `priv` payload into the application graph.
- Use `mix_release` for immutable release assembly.
- Use `elixir_release_test` to boot the packaged release without build-time
  runtime paths.

Use [Releases](../releases.md) for the packaging contract.

### 9. Keep writable workflows local

Use `mix_local`, `mix_phx_server`, `mix_iex`, or `elixir_ls` for generators,
code reload, IEx, Phoenix development, and language-server workflows over the
real checkout. These are explicit `bazel run` developer paths, not cacheable
build or test actions.

Do not make a hermetic action write generated project files back into the
source tree.

### 10. Keep native and FIPS ownership outside this ruleset

`rules_elixir_mix` consumes declared native outputs and a normalized crypto SDK.
It does not fetch, patch, validate, certify, or silently select a crypto
backend. A producer ruleset owns those artifacts and their provenance.

For a FIPS-required OTP toolchain, use the generic SDK contract described in
[Source toolchains](../source_toolchains.md#backend-neutral-crypto-sdk). Do not
invent backend-specific attributes or claim FIPS validation from a successful
OTP build alone.

## Hermeticity and cache review

Before calling the integration complete, verify all of the following:

- all archives are pinned by checksum and all toolchains are registered;
- source versions resolve from the pinned ruleset catalog or a complete
  URL/SHA-256 override, never a moving `latest` lookup;
- catalog maintenance discovers stable upstream releases outside Bazel, hashes
  their immutable archives, and submits reviewable signed pull requests;
- the action does not discover executables through the host `PATH`;
- build and test actions do not access the network;
- no action runs `mix deps.get` or mutates `mix.lock`;
- all read files, environment values, tools, native libraries, and service
  executables affect the action inputs or configuration;
- the runtime resolves only on a matching OS, CPU, and `runtime_abi` platform;
- generated sources have stable logical destinations;
- `priv`, templates, configuration, protocol output, and runtime dependencies
  reach runfiles or releases through providers;
- an identical second invocation reuses the expected cache entries;
- a clean or remote execution does not depend on files left by the first run;
- local writable workflows are not presented as hermetic build artifacts.

When remote execution is available, exercise it. A local sandbox alone cannot
prove compatibility with an undeclared worker image.

## Reject these patterns

- one giant action that runs `mix deps.get && mix compile`;
- `ctx.actions.run_shell`, generated shell launchers, or embedded shell programs
  for ordinary rules;
- machine-specific workspace/home paths, usernames, hostnames, or local
  configuration in tracked files;
- Phoenix, LiveView, Wallaby, or analysis packages modeled as toolchains;
- hidden Chrome, ChromeDriver, Postgres, OpenSSL, compiler, or system-library
  discovery;
- raw path strings passed between rules where a provider carries the artifact;
- network access justified as a cache warm-up;
- live release discovery or an unpinned `latest` toolchain alias;
- claims of platform, FIPS, backend, release, or cross-compilation support that
  are not backed by the pinned implementation and a relevant test.

## Agent completion report

Finish with evidence, not a generic success statement. Report:

1. the ruleset revision and OTP/Elixir toolchain selected;
2. the execution platform and `runtime_abi` assumption;
3. the application targets and dependency-edge decisions;
4. the build, test, analysis, release, and local-workflow targets added;
5. the exact validation commands that passed;
6. whether the second run reused the cache and whether remote execution ran;
7. any capability not tested or any producer contract still required.

If any of those facts are unknown, say so plainly. Unknown is safer than a
fabricated guarantee.
