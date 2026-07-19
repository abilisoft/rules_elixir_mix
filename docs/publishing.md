<!--
SPDX-FileCopyrightText: 2026 AbiliSoft
SPDX-License-Identifier: Apache-2.0
-->

# Publishing

[Documentation home](README.md) · [Prebuilt toolchains](prebuilt_toolchains.md) ·
[Source toolchains](source_toolchains.md)

There are two independent products:

1. the `rules_elixir_mix` Bazel module published to the Bazel Central Registry;
2. platform-specific OTP and Elixir runtime archives consumed by
   `prebuilt_toolchain`.

A BCR module release does not need Chrome, Postgres, OTP binaries, Elixir
binaries, or a crypto SDK. Runtime archives do need a fully declared source
toolchain and platform closure.

## Current publication state

- [`v0.1.0`](https://github.com/abilisoft/rules_elixir_mix/releases/tag/v0.1.0)
  is a signed GitHub release whose verified target commit is
  `ea6194a031302ee7a1a40539cd78f3f280d3bfd3`.
- The module is not published to BCR. Consumers should use the direct commit
  override in [Getting started](getting_started.md#1-pin-the-ruleset).
- No official OTP or Elixir runtime archives are published. The rules accept
  producer-owned, checksum-pinned archives, while the real crypto-backed
  producer matrix remains pending.

These are independent gates. Deferring BCR publication or official runtime
archives does not prevent testing the signed ruleset through an exact commit.

## Bazel Central Registry release

The checked-in BCR templates publish the signed GitHub tag archive and run the
consumer module in `e2e/bcr`. The presubmit matrix is Bazel 9 on Debian 13 for
Linux x86-64 and ARM64. Its smoke target resolves the public OTP and Elixir
toolchains without executing fixture binaries.

For each version:

1. set `module(version = ...)` in `MODULE.bazel`;
2. merge the release-preparation change through protected `main`;
3. create a signed annotated tag whose `v`-stripped version matches the module;
4. push the tag and let the Release workflow create the GitHub release;
5. run **Publish to BCR** with that tag;
6. open the manual pull-request URL printed by the workflow and wait for BCR
   validation and review.

```sh
git tag -s v0.1.0 -m "rules_elixir_mix v0.1.0"
git push origin v0.1.0
```

The workflow rejects lightweight tags, unverified tag signatures, tags outside
`main`, and a tag/module version mismatch. `publish-to-bcr` is pinned by commit
and runs with attestations disabled because this repository does not use the
shell-based bazel-contrib release-preparation workflow.

The BCR workflow needs `BCR_PUBLISH_TOKEN` with write access to the
`abilisoft/bazel-central-registry` fork. It deliberately sets
`open_pull_request: false`, so a fine-grained token can push the proposal branch
without permission to create pull requests in the upstream registry. The
workflow prints the upstream PR URL for a maintainer to open explicitly.

## Linux runtime archives

The supported producer matrix is Linux x86-64 and ARM64. Each architecture is
a separate runtime artifact and must independently satisfy all of the
following:

- a digest-pinned execution image and dedicated `runtime_abi` constraint;
- checksum-pinned pristine OTP and Elixir sources;
- declared Bash, Make, Perl, POSIX, and C/C++ toolchains;
- a normalized `crypto_sdk` from its owning producer;
- source-built `otp` and `runtime` targets;
- two `beam_runtime_archive` targets;
- a second clean build proving the archives are reproducible and cacheable;
- prebuilt-toolchain consumption and release boot tests on the same ABI;
- FIPS/static-link tests when `fips = "required"`;
- producer-owned backend provenance and policy tests.

The GitHub matrix uses native Ubuntu 24.04 runners for both architectures; BCR
uses native Debian 13 workers. ARM64 is not emulated, and an x86-64 success does
not stand in for the ARM64 gate.

Do not publish the current no-crypto source-integration runtime as a general
OTP/Elixir prebuilt. It intentionally configures OTP with `--without-ssl` to
prove the generic source path and is not a Phoenix/TLS runtime. Official
archives remain blocked until a real hermetic crypto SDK supplies the complete
closure and the archive/consume/boot matrix passes.

The archive metadata gives the exact `otp_strip_prefix`, `erlexec`,
`otp_version_marker`, `elixir_strip_prefix`, `elixir_home_marker`,
`elixir_version_marker`, and SHA-256 values to copy into
`prebuilt_toolchain`. URLs must identify immutable release assets; never use a
moving `latest` URL.

## Browser and database tests

Chrome/ChromeDriver and Postgres are ordinary declared test tools, not BEAM
toolchains or release inputs:

- `mix_wallaby_test` requires executable targets for the browser and driver;
- `mix_ecto_test` requires executable targets for `initdb`, `postgres`, and
  `createdb`.

Those labels let Bazel include the exact binaries and runtime closures in the
test action and cache key. If no target uses those rules, declare none of them.
