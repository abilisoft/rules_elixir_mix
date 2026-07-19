<!--
SPDX-FileCopyrightText: 2026 AbiliSoft
SPDX-License-Identifier: Apache-2.0
-->

# Getting started

[Documentation home](README.md) · [Core concepts](concepts.md) ·
[Rule catalog](rules.md)

This guide takes one Mix application from pinned inputs to a Bazel library and
ExUnit test. You will provide an OTP archive and an Elixir archive that match
your execution platform.

> [!NOTE]
> There is no official prebuilt archive matrix yet. For production use, publish
> your own verified archives or build them once with
> [`source_toolchain`](source_toolchains.md), then consume the result through
> [`prebuilt_toolchain`](prebuilt_toolchains.md).

## 1. Pin the ruleset

The signed [`v0.1.0` GitHub release](https://github.com/abilisoft/rules_elixir_mix/releases/tag/v0.1.0)
is intentionally not published to BCR yet. Consume it through the full,
GitHub-verified commit referenced by that tag:

```starlark
module(
    name = "my_app",
    bazel_compatibility = [">=9.2.0"],
)

bazel_dep(
    name = "rules_elixir_mix",
    version = "0.1.0",
)

git_override(
    module_name = "rules_elixir_mix",
    remote = "https://github.com/abilisoft/rules_elixir_mix.git",
    commit = "ea6194a031302ee7a1a40539cd78f3f280d3bfd3",
)

bazel_dep(name = "platforms", version = "1.1.0")
```

That commit is the immutable target of the verified `v0.1.0` tag. For a later
release, replace both the declared version and commit with that release's
values. Never track a branch or movable tag. Repository downloads, toolchains,
and package archives must remain content-addressed.

## 2. Name the runtime ABI

OS and CPU are not enough when BEAM or a dependency contains native code.
Create a constraint for the exact runtime closure:

```starlark
# platforms/BUILD.bazel
constraint_setting(name = "runtime_abi")

constraint_value(
    name = "otp29_elixir120_glibc239",
    constraint_setting = ":runtime_abi",
)

platform(
    name = "beam_linux_x86_64",
    constraint_values = [
        "@platforms//cpu:x86_64",
        "@platforms//os:linux",
        ":otp29_elixir120_glibc239",
    ],
)
```

For remote execution, bind the platform to an immutable container image digest
using the property understood by your executor. The name should describe the
real libc/loader/NIF closure, not a wishful compatibility range.

For Linux ARM64, define a separate platform using
`@platforms//cpu:arm64`, a separately verified ARM64 `runtime_abi`, and ARM64
runtime archives. Register both toolchain pairs when a repository builds on
both architectures. With multiple tags, set exactly one tag's `default = True`
and add `@elixir_config//:runtime_<tag_name>` to each matching platform so
Bazel selects the intended tuple as well as the correct CPU and ABI.

## 3. Register OTP and Elixir

The fast path uses already-extracted, checksum-pinned archives:

```starlark
# MODULE.bazel
beam = use_extension(
    "@rules_elixir_mix//bzlmod:toolchains.bzl",
    "elixir_config",
)

beam.prebuilt_toolchain(
    name = "linux_x86_64",
    otp_version = "29.0.3",
    otp_url = "https://artifacts.example/otp-29.0.3-linux-x86_64.tar.zst",
    otp_sha256 = "<64-hex-sha256>",
    erlexec = "erts-17.0.3/bin/erlexec",
    elixir_version = "1.20.2",
    elixir_url = "https://artifacts.example/elixir-1.20.2-otp-29.tar.gz",
    elixir_sha256 = "<64-hex-sha256>",
    exec_compatible_with = [
        "@platforms//cpu:x86_64",
        "@platforms//os:linux",
    ],
    runtime_abi = "//platforms:otp29_elixir120_glibc239",
)

use_repo(beam, "elixir_config")

register_toolchains(
    "@elixir_config//linux_x86_64:otp_toolchain",
    "@elixir_config//linux_x86_64:toolchain",
)

register_execution_platforms("//platforms:beam_linux_x86_64")
```

The archive must run from its extracted location. The ruleset does not relocate
it, invoke an installer, or borrow a host library. Read
[Prebuilt toolchains](prebuilt_toolchains.md) for the complete archive contract.

## 4. Import `mix.lock`

Keep `mix.exs` and `mix.lock` in the repository. Bzlmod turns each locked Hex
package into its own immutable Bazel repository:

```starlark
# MODULE.bazel
packages = use_extension(
    "@rules_elixir_mix//bzlmod:packages.bzl",
    "elixir_packages",
)

packages.mix_lock(
    name = "mix_deps",
    lockfile = "//:mix.lock",
)

use_repo(packages, "hex_pm", "mix_deps")
```

Compilation runs with Hex offline and networking blocked. If the lockfile does
not describe the dependency, the build does not fetch it as a side effect.

## 5. Model the application

Create separate production and test compilations because `MIX_ENV`, config,
support sources, and dependencies differ:

```starlark
# BUILD.bazel
load(
    "@rules_elixir_mix//:defs.bzl",
    "mix_format_test",
    "mix_library",
    "mix_test",
    "mix_typecheck_test",
)

mix_library(
    name = "app",
    app_name = "my_app",
    mix_config = "mix.exs",
    srcs = glob(["lib/**/*.ex"]),
    config = glob(["config/**/*.exs"]),
    data = glob(["lib/**/*.eex", "lib/**/*.heex"]),
    priv = glob(["priv/**/*"]),
    runtime_deps = [
        "@mix_deps//:jason",
    ],
)

mix_library(
    name = "app_test",
    app_name = "my_app",
    mix_config = "mix.exs",
    mix_env = "test",
    srcs = glob([
        "lib/**/*.ex",
        "test/support/**/*.ex",
    ]),
    config = glob(["config/**/*.exs"]),
    data = glob(["lib/**/*.eex", "lib/**/*.heex"]),
    priv = glob(["priv/**/*"]),
    runtime_deps = [
        "@mix_deps//:jason",
    ],
)

mix_test(
    name = "test",
    lib = ":app_test",
    srcs = glob(["test/**/*.exs"]),
)

mix_format_test(
    name = "format",
    lib = ":app_test",
    srcs = glob(["**/*.ex", "**/*.exs"]),
)

mix_typecheck_test(
    name = "typecheck",
    lib = ":app_test",
    srcs = glob(["lib/**/*.ex", "test/**/*.exs"]),
)
```

Use `compile_deps` for macros, parse transforms, and compiler-only applications;
`type_deps` for remote type references needed by Dialyzer; and `runtime_deps`
for applications propagated into execution and releases. See
[Core concepts](concepts.md#three-dependency-edges).

## 6. Build and test

```sh
bazel build //:app
bazel test //:test //:format //:typecheck
```

Run the same command twice while developing cache-sensitive integrations. The
second invocation should reuse the compiled application and unchanged package
graph.

## Where next?

- Add Phoenix, LiveView, Ecto, Wallaby, or analysis tools in
  [Mix and dependencies](mix.md).
- Build and test an OTP release in [Releases](releases.md).
- Choose the expensive source path in [Source toolchains](source_toolchains.md).
- Give an AI coding agent the [agent playbook](agents/README.md).
