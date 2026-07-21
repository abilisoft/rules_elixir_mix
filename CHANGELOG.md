<!--
SPDX-FileCopyrightText: 2026 AbiliSoft
SPDX-License-Identifier: Apache-2.0
-->

# Changelog

All notable user-facing changes are recorded here. Signed Git tags and GitHub
releases identify the exact source; this project is not yet published to the
Bazel Central Registry.

## 0.3.0 - 2026-07-21

### Added

- Provider-backed and checksum-pinned archive forms for prebuilt and bootstrap
  OTP runtimes, including explicit pre-install `.boot` files.
- Focused OTP ABI/JIT smoke tests generated beside source toolchains.
- Public lock-owned Hex asset projection for non-BEAM rule graphs.
- Hermetic `mix_escript` outputs with executable providers and complete BEAM
  runtime runfiles.
- An explicit online `mix_deps_update` workflow; builds and tests remain
  offline.
- Automated pull requests for new stable OTP and Elixir source releases.
- Direct projections of checksum-owned precompiled native files, including
  profile-selectable application NIFs.
- Deterministic release staging for crypto SDKs whose declared runtime
  directory and provider payload have nested destinations.

### Changed

- Execution-platform ABI and produced-runtime ABI are independent toolchain
  constraints, enabling glibc workers to build musl runtimes. Generated Bazel
  test toolchains preserve that separation for test execution.
- Optional Hex packages remain addressable through the public dependency hub
  without entering unrelated compile or runtime closures.
- Checksum-pinned source, prebuilt runtime, and Hex archives reject dangling or
  escaping symlinks during repository extraction.
- Prebuilt runtime fixtures and generated toolchains constrain native OTP
  verification to the archive's real execution OS/CPU, so incompatible
  bootstraps fail platform selection before an OS shell fallback is possible.
- Every native executable in a source-built OTP tree must be static or carry an
  adjacent declared static runtime wrapper; dynamic execroot loaders are not
  accepted. Every executable, NIF, and shared object also has its recursive ELF
  dependency closure proven against the declared runtime and SDK inputs.
- FIPS mode is enabled before every BEAM entry point and persisted in release
  configuration. Static-NIF linkage and approved/prohibited operations are
  verified through the backend-neutral crypto SDK contract.
- A declared pre-install OTP boot file is applied through shell-free
  `ERL_AFLAGS` during archive verification, source-driver startup, and every
  nested bootstrap `erl`, `erlc`, and `escript` invocation.
- Source toolchains require the explicit non-JIT profile for x86-64 musl,
  avoiding host-dependent signal-stack failures.
- Hex, Rebar, OTP, Elixir, Bazel, and rule dependencies were refreshed to the
  versions documented by the repository.

### Removed

- Arbitrary host/runtime launcher hooks and implicit dynamic OTP archive
  acceptance.
- Runtime ABI constraints from source-toolchain execution compatibility.

## 0.2.1 - 2026-06-26

- Published the signed source release preceding the stricter bootstrap,
  runtime-wrapper, asset, and escript contracts above.
