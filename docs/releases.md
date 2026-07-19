<!--
SPDX-FileCopyrightText: 2026 AbiliSoft
SPDX-License-Identifier: Apache-2.0
-->

# Mix releases

[Documentation home](README.md) · [Mix rules](mix.md) ·
[Source toolchains](source_toolchains.md) · [Agent playbook](agents/README.md)

Use `mix_release` after the production application graph and runtime platform
are explicit. The rule invokes `mix release` directly with compilation and
dependency checks disabled because Bazel supplies the already-compiled
applications.

## Assemble a release

```starlark
load(
    "@rules_elixir_mix//:defs.bzl",
    "elixir_release_test",
    "mix_release",
)

mix_release(
    name = "release",
    application = ":app",
    configs = glob(["config/**/*.exs"]),
    data = glob(["rel/**/*"]),
    lockfile = "mix.lock",
    release_name = "my_app",
)

elixir_release_test(
    name = "release_test",
    release = ":release",
)
```

`mix_release` produces one immutable release tree artifact. Mix still owns boot
scripts, overlays, runtime configuration, protocol consolidation, and ERTS
inclusion; the rule does not post-process the tree with shell commands.

| Input | Purpose |
| --- | --- |
| `application` | Production `mix_library` target and its runtime closure |
| `deps` | Additional release applications not already in that closure |
| `configs` | Declared Mix/release configuration files |
| `data` | Overlays and other release inputs |
| `lockfile` | Declared lockfile when release evaluation reads it |
| `protocols` | Optional separately consolidated protocol artifact |
| `env` | Explicit release-build environment values |

`mix_env` defaults to `prod` and must match the environment used to compile the
application target. Build on an execution platform matching the deployment
ABI, especially when ERTS or any dependency contains native code.

Static assets should already be mapped into `priv/static` by their owning Bazel
rules. `mix_phx_assets` can produce the digested `ElixirPrivInfo` mapping; JS
and CSS compilation remains outside Mix release assembly.

## Boot-test the artifact

`elixir_release_test` starts the packaged release through its native VM and
removes build-time runtime paths from the test environment. Use
`required_paths`, `required_file_contents`, and `consolidated_protocols` to
check the payload that matters to the application.

This test proves the declared artifact can boot on the selected execution
platform. It does not prove compatibility with a different deployment image.

## FIPS-required releases

For a FIPS-required toolchain, `mix_release` merges
`{crypto, [{fips_mode, true}]}` into generated `sys.config`. A fully static
crypto SDK needs no provider payload.

A normalized provider-backed SDK is packaged below
`.rules_elixir_mix/crypto_sdk`. The rule prepends a checked-in Elixir activation
hook to the declared `config/runtime.exs`; the release then:

1. clears ambient OpenSSL-related configuration;
2. runs the packaged activation executable without a shell;
3. applies only normalized release-relative SDK paths;
4. aborts before application startup if activation fails.

Provider-backed releases must declare `config/runtime.exs` on the application
target. Deployment must set `RULES_ELIXIR_MIX_CRYPTO_STATE` to a writable,
deployment-local directory. Generated provider state is created there from
packaged inputs rather than copied from the build host.

Backend identity, certificate/version metadata, and source provenance remain
the SDK producer's responsibility. See the
[backend-neutral crypto SDK contract](source_toolchains.md#backend-neutral-crypto-sdk).

## Release checklist

- the production application was compiled with the intended `mix_env`;
- execution and deployment share the same declared runtime ABI;
- assets, overlays, runtime config, and native payloads are declared inputs;
- `elixir_release_test` boots the artifact and checks critical paths;
- FIPS-required releases fail closed and use only producer-supplied SDK files;
- no deployment step depends on a build-worker path or host-installed runtime.
