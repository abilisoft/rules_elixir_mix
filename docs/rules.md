<!--
SPDX-FileCopyrightText: 2026 AbiliSoft
SPDX-License-Identifier: Apache-2.0
-->

# Rule catalog

[Documentation home](README.md) · [Getting started](getting_started.md) ·
[Mix details](mix.md)

Load public APIs from `@rules_elixir_mix//:defs.bzl`. Module extensions live in
`bzlmod/toolchains.bzl` and `bzlmod/packages.bzl`.

## Build graph

| API | Use it for |
| --- | --- |
| `mix_library` | Compile one Mix/OTP application from explicit sources and dependencies |
| `elixir_library`, `elixir_app` | Compatibility aliases of `mix_library` |
| `erlang_app` | Compile one direct Erlang/OTP application without Mix/Rebar |
| `rebar_library` | Compile an imported Rebar application as an OTP application |
| `elixir_generated_source` | Give a generated file/tree a stable project-relative destination |
| `elixir_priv` | Map one declared artifact into an application's `priv` tree |
| `elixir_nif`, `rustler_nif` | Map a Bazel-built shared library below `priv/native` |
| `elixir_protocols`, `mix_protocols` | Consolidate declared protocol implementations |
| `hex_package_assets` | Project exact package-relative files from a checksum-pinned Hex dependency |
| `mix_escript` | Build a compiled Mix application into an executable escript Bazel tool |

## Tests and analysis

| API | Use it for |
| --- | --- |
| `mix_test`, `mix_ex_unit_test` | ExUnit with deterministic Bazel sharding |
| `erlang_eunit_test` | Direct EUnit execution |
| `erlang_common_test` | Common Test suites, groups, cases, hooks, config, and suite data |
| `mix_format_test` | `mix format --check-formatted` |
| `mix_credo_test` | Credo, strict by default |
| `mix_sobelow_test` | Phoenix security analysis |
| `mix_xref_test` | Explicit supported Xref mode |
| `mix_typecheck_test` | Elixir 1.20+ compiler-integrated gradual type analysis |
| `dialyzer_plt` | Separately cacheable native PLT |
| `elixir_dialyzer_test` | Native Dialyzer against a declared PLT |
| `mix_dialyzer_test` | Dialyxir-managed project analysis |
| `mix_coverage_test` | Mix console coverage |
| `mix_lcov_test` | ExCoveralls LCOV through Bazel's coverage protocol |
| `mix_ecto_test` | ExUnit with a fresh declared Postgres cluster |
| `mix_wallaby_test` | ExUnit/Wallaby with declared Chrome and ChromeDriver |

## Phoenix, releases, and local development

| API | Use it for |
| --- | --- |
| `mix_phx_assets`, `mix_phx_digest` | Cacheable `phx.digest`; JS/CSS compilation stays in JS rules |
| `mix_release` | Assemble a Mix release from declared applications/config/data |
| `elixir_release_test` | Boot the packaged release with build-time paths removed |
| `mix_local` | Writable local Mix workflow over the real workspace |
| `mix_deps_update` | Explicit online `mix deps.update --all` workflow over the real workspace |
| `mix_phx_server` | Local-only Phoenix server/code reload workflow |
| `mix_iex` | IEx with the selected runtime and application graph |
| `elixir_ls` | ElixirLS over the same graph instead of a second fake Mix build |

## Toolchains and crypto

| API | Layer | Use it for |
| --- | --- | --- |
| `elixir_config.prebuilt_toolchain` | Module extension | Fetch/register checksum-pinned OTP and Elixir archives |
| `elixir_config.source_toolchain` | Module extension | Build pristine OTP and Elixir sources from the immutable catalog or explicit pinned overrides |
| `otp_toolchain`, `elixir_toolchain` | Low-level rule | Assemble custom toolchain registrations |
| `otp_prebuilt_release`, `elixir_prebuilt_release` | Low-level rule | Validate/expose extracted runtime trees |
| `otp_source_release`, `elixir_source_release` | Low-level rule | Build source runtime trees |
| `beam_runtime_archive` | Producer rule | Package a crypto-enabled source runtime with deterministic metadata and SHA-256 |
| `otp_crypto_sdk` | Rule/provider | Normalize static or provider-backed crypto SDK payloads |
| `elixir_fips_runtime_test` | Test | Verify shared fail-closed OTP FIPS/static-link behavior |

Most consumers should use the module-extension toolchain APIs. The low-level
rules exist for producers and advanced repository integration.

## Providers

| Provider | Carries |
| --- | --- |
| `ErlangAppInfo` | Compiled OTP application, metadata, dependency closures, runfiles |
| `OtpInfo` | OTP runtime, executables, version, FIPS/runtime state |
| `ElixirInfo` | Elixir runtime and OTP relationship |
| `OtpCryptoSdkInfo` | Normalized SDK sysroot, runtime payload, activation, metadata |
| `HexPackageInfo` | Lock-owned Hex archive identity and complete source mapping |
| `HexPackageAssetsInfo` | Selected Hex source assets plus their package/version/checksum identity |
| `MixEscriptInfo` | Built escript and any declared provider-runtime sidecar |
| `ElixirPrivInfo` | Stable mappings into an OTP application's `priv` tree |
| `ElixirSourceInfo` | Generated input with a stable logical destination |
| `ElixirProtocolInfo` | Protocol consolidation inputs/output |
| `DialyzerPltInfo` | Cacheable PLT artifact and application closure |
| `BeamRuntimeArchiveInfo` | Runtime archive, SHA-256, release metadata, version, and strip prefix |

Do not pass raw filesystem paths between rules when one of these providers
expresses the contract. Providers make runfiles, cache keys, and transitive
semantics visible to Bazel analysis.

## Choosing a rule quickly

```text
Is it an OTP application?
├─ Mix project ───────────────> mix_library
├─ direct Erlang source ──────> erlang_app
└─ imported Rebar package ────> rebar_library

Is it a check?
├─ ExUnit/EUnit/Common Test ──> language test rule
├─ Mix task with known output > focused mix_*_test macro
└─ packaged runtime behavior ─> elixir_release_test / elixir_fips_runtime_test

Does it need a writable checkout?
├─ dependency lock update ────> mix_deps_update
├─ other writable workflow ───> mix_local / mix_phx_server / mix_iex / elixir_ls
└─ no ────────────────────────> ordinary hermetic build/test action
```

For attributes and dependency behavior, continue with [Mix details](mix.md),
[Prebuilt toolchains](prebuilt_toolchains.md), or
[Source toolchains](source_toolchains.md).
