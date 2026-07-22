<!--
SPDX-FileCopyrightText: 2026 AbiliSoft
SPDX-License-Identifier: Apache-2.0
-->

# Changelog

All notable user-facing changes are recorded here. Signed Git tags and GitHub
releases identify the exact source; this project is not yet published to the
Bazel Central Registry.

## 0.3.5 - 2026-07-22

### Added

- Prebuilt and source OTP providers expose explicit target OS, architecture,
  and libc ABI metadata for target-aware native-package selection.
- Checksum-pinned archive bootstraps declare their libc explicitly instead of
  inheriting the produced runtime ABI.
- The source matrix covers an AMD64 GNU execution/bootstrap VM cross-building
  an Arm64 musl OTP runtime.
- RustlerPrecompiled archive providers record their selected architecture, OS,
  and ABI tuple; AMD64 and Arm64 source integration stages the matching
  checksum-owned musl payload with action networking blocked.

### Fixed

- ARM64 OTP cross-builds keep every BEAM compilation step on the declared
  build-machine bootstrap VM, including upstream rules that invoke bare
  `escript`. They no longer enter OTP's native secondary bootstrap through the
  target runtime paths.
- RustlerPrecompiled receives `TARGET_ARCH`, `TARGET_OS`, `TARGET_ABI`, and
  `TARGET_VENDOR` from the Bazel target platform before selecting its locked
  archive.
- `mix_format` remains source-only while staging declared dependency formatter
  metadata for offline `.formatter.exs` `import_deps` evaluation. All Mix,
  Hex, dependency, and build scratch state lives in a cleaned temporary
  directory outside the source checkout.
- Provider-backed `mix_escript` outputs use a cwd-independent shell-free
  launcher with the complete OTP/SDK environment, payload, and adjacent
  runtime sidecar in `DefaultInfo.files` and runfiles.
- Source-build integration consumes checksum-pinned `rules_fips` v0.3.8. Its
  launcher keeps fixed arguments and explicit process names scoped to one
  invocation, so OTP's declared `escript` frontend can re-enter the wrapped
  emulator without duplicated arguments, host lookup, or widened `PATH`
  access. The normalized SDK also publishes a complete runnable OpenSSL tool
  without shifting crypto ownership into these rules.
- Elixir source builds use the declared OTP execution overlay's single public
  `erl` directly; they no longer add a duplicate private `erl` symlink to the
  closed build `PATH`. The source driver now rejects zero or multiple declared
  `erl` candidates before upstream compilation begins.
- The cross-toolchain gate executes its AMD64 bootstrap smoke test under both
  Bazel's Linux `sandboxed` strategy and the explicit
  `processwrapper-sandbox` strategy before the remote ARM64 musl source build.
- Source integration reuses each GNU glibc platform as both its native target
  and execution platform. `mix_escript` tools resolve the matching runtime
  without claiming the produced musl ABI, relying on platform ordering, or
  maintaining a duplicate execution-platform definition.
- Runtime path normalization uses a deterministic single-line `ERL_AFLAGS`
  expression, allowing provider-backed escript launchers to retain the strict
  newline-free sidecar format.
- Source OTP runtimes always expose the real `escript` frontend under the
  declared Erlang home, whether or not that executable itself required the SDK
  runtime wrapper.

## 0.3.4 - 2026-07-22

### Added

- `mix_format`, a source-only writable formatter that uses the selected
  OTP/Elixir toolchain without depending on or compiling a `mix_library`.
- Target-configured `rustler_precompiled_archive` selection and offline cache
  staging for checksum-owned RustlerPrecompiled archives, including generated
  Hex dependency targets.

### Changed

- FIPS-capable OTP/OpenSSL toolchains no longer activate FIPS during
  application, Rebar, protocol, Dialyzer, escript, bootstrap, or writable local
  compilation workflows. OTP/runtime tests and FIPS-required releases activate
  and validate FIPS explicitly.

## 0.3.3 - 2026-07-22

### Changed

- Protected CI now analyzes the public, explicitly online
  `mix_deps_update` workflow on both supported architectures while keeping
  build and test actions offline.
- The Hex package extension now reports generated repositories as development
  dependencies when its root usage is development-only, matching Bazel's
  module-extension metadata contract.
- The source-build integration now pins `rules_fips` v0.3.4, whose native SDK
  paths remain valid across nested build-system directory changes and whose
  pkg-config metadata is carried as declared toolchain input.
- OTP source builds preserve compiler-driver linker selectors such as
  `-fuse-ld=lld`; only linker values containing a declared path are rebased to
  the action execution root.
- The integration lock reflects the canonical metadata emitted by current
  Hex for `ssl_verify_fun` without changing the package version or checksums.
- Source-toolchain documentation now distinguishes a fully static musl VM
  from the wrapped-dynamic musl profile required by OpenSSL FIPS providers
  and applications that load NIFs.

## 0.3.2 - 2026-07-22

### Changed

- The source-build integration now consumes the checksum-pinned
  `rules_fips` v0.3.2 SDK, including its stable target-native Rust/Cargo tool
  paths across working-directory changes.
- GitHub workflows now pin `actions/checkout` v7.0.1 and
  `github/codeql-action` v4.37.2 by immutable commit.

## 0.3.1 - 2026-07-21

### Fixed

- Expected OTP ABI-rejection coverage is now a successful Bazel test driven by
  a compatible declared OTP toolchain, so BES providers do not publish an
  intentional child-process rejection as a failed commit status.

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
- Source-built OTP emulators retain OTP's upstream dynamic-symbol export flag
  under hermetic linkers and fail the build if representative NIF API symbols
  are absent from the emulator's dynamic symbol table.
- Hex, Rebar, OTP, Elixir, Bazel, and rule dependencies were refreshed to the
  versions documented by the repository.

### Removed

- Arbitrary host/runtime launcher hooks and implicit dynamic OTP archive
  acceptance.
- Runtime ABI constraints from source-toolchain execution compatibility.

## 0.2.1 - 2026-06-26

- Published the signed source release preceding the stricter bootstrap,
  runtime-wrapper, asset, and escript contracts above.
