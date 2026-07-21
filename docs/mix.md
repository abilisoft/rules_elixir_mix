<!--
SPDX-FileCopyrightText: 2026 AbiliSoft
SPDX-License-Identifier: Apache-2.0
-->

# Mix rules

[Documentation home](README.md) · [Getting started](getting_started.md) ·
[Rule catalog](rules.md) · [Agent playbook](agents/README.md)

Use this guide after the OTP/Elixir toolchain and `mix.lock` import resolve.
It explains how application inputs, dependency edges, tests, native packages,
Phoenix assets, and writable developer workflows fit into the Bazel graph.

## Application compilation

`mix_library` invokes Mix directly through the selected Elixir toolchain. It
sets action-local Mix/Hex/home directories, disables dependency fetching, and
publishes a tree artifact containing `_build/<env>/lib/<app>`.

Dependencies are separate Bazel targets exposed through `ERL_LIBS`. Each Mix
action materializes only the declared compiled OTP applications into private,
writable action state, then removes them from the consumer output. Dependency
compilation therefore stays independently cacheable while Mix still sees the
filesystem layout it expects.

Important attributes:

- `mix_config`: the mandatory `mix.exs` target for this application.
- `srcs`: `.ex`, `.exs`, and Mix-managed Erlang sources.
- `config`: build-time `.exs` configuration.
- `data`: templates and files read while evaluating/compiling the project.
- `priv`: runtime application files and generated assets.
- `compile_deps`: dependencies visible only while compiling this application.
- `type_deps`: compile-only dependencies whose remote types are referenced by
  this application. Dialyzer includes this closure but excludes unrelated
  build tools that may intentionally omit debug information.
- `runtime_deps`: dependencies propagated into the runtime application graph.
- `deps`: compatibility spelling for `runtime_deps`.
- `mix_env`: `prod`, `dev`, or `test`.
- `hex`: optional explicit offline Hex application label, normally
  `@hex_pm//:lib`. Repository mapping is resolved in the caller.
- `precompiled_native_artifacts`: checksum-pinned archives staged in an
  isolated `ELIXIR_MAKE_CACHE_DIR` before compilation.
- `precompiled_native_files`: exact, checksum-owned native files mapped
  directly to package-relative destinations such as `priv/native.so`.
- `native_build`: opt one application into the selected execution platform's
  registered C/C++ toolchain and declared Bash/Make/Perl/POSIX closure.

All inputs must be declared. Network access during compilation and tests is a
build error; add packages to `mix.lock` instead of calling `mix deps.get`.

## Native dependencies

Native dependencies stay selective for cache performance. Prefer an upstream
precompiled NIF when the producer publishes one for the exact OTP NIF ABI,
CPU, OS, and libc. Pin it with a Bazel repository checksum and map it by Hex
package name:

```starlark
http_file = use_repo_rule(
    "@bazel_tools//tools/build_defs/repo:http.bzl",
    "http_file",
)
http_file(
    name = "native_nif_linux_x86_64_musl",
    downloaded_file_path = "package-nif.tar.gz",
    sha256 = "...",
    urls = ["https://producer.example/package-nif.tar.gz"],
)

packages.mix_lock(
    name = "mix_deps",
    lockfile = "//:mix.lock",
    precompiled_native_artifacts = {
        "package": "@native_nif_linux_x86_64_musl//file",
    },
)
```

When the producer publishes a known library directly inside a larger archive,
prefer a topology-validated `prebuilt_archive` projection and map that file to
its package-relative destination:

```starlark
prebuilt_archive = use_repo_rule(
    "@rules_elixir_mix//repositories:prebuilt_archive.bzl",
    "prebuilt_archive",
)
prebuilt_archive(
    name = "native_nif_linux_x86_64_musl",
    exported_files = ["lib/package_nif.so"],
    sha256 = "...",
    urls = ["https://producer.example/package-nif.tar.gz"],
)

packages.mix_lock(
    name = "mix_deps",
    lockfile = "//:mix.lock",
    precompiled_native_files = {
        "package": {
            "@native_nif_linux_x86_64_musl//:lib/package_nif.so": "priv/package_nif.so",
        },
    },
)
```

Both forms remain checksum-pinned and the Mix action stays offline. Direct
files avoid package-specific extraction logic when the producer's archive
layout is already known. For a package that must compile native sources, list
its Hex package name in `native_build_packages`. The lockfile's advertised
build-tool list is not used as an automatic signal because packages often
advertise multiple alternative managers. Native flags and tools affect only
the selected package action, not every BEAM dependency:

```starlark
packages.mix_lock(
    name = "mix_deps",
    lockfile = "//:mix.lock",
    native_build_packages = ["package"],
)
```

The registered Elixir toolchain must then expose declared native tools, and a
matching Bazel C/C++ toolchain must resolve on the same execution platform.
`rules_fips` may produce that musl/glibc compiler and POSIX closure;
`rules_elixir_mix` only consumes it. There is no fallback to `/usr/bin`, the
host `PATH`, a host compiler, or a host crypto library.

A fully static OTP runtime cannot dynamically load application NIFs. Static
crypto-NIF linkage is independent: it may embed OTP's crypto NIF while the BEAM
runtime itself remains a wrapped dynamic executable capable of loading
LazyHTML, Rustler, and other application NIFs. Select that wrapped dynamic
profile for Phoenix LiveView applications that depend on native packages.

Optional Hex dependencies do not enter another package's compile or runtime
closure automatically. Select the optional package explicitly through the
generated dependency hub when the application enables the corresponding
feature. The lock remains the sole version and integrity authority.

## Tests and analysis

`mix_test` shards `_test.exs` inputs deterministically with Bazel's standard
test shard variables. `dialyzer_plt` builds a separate cacheable PLT artifact;
pass it to `elixir_dialyzer_test`. `mix_dialyzer_test` is the distinct
Dialyxir-managed workflow and may use Dialyxir's own project configuration.
Format, Credo, Sobelow, Xref, coverage, and Wallaby targets use Bazel's test
cache and the same compiled application graph.

Framework and analysis helpers remain thin symbolic macros over that graph:

- `mix_typecheck_test` forces an Elixir 1.20+ compilation with warnings as
  errors, exercising the compiler-integrated type analysis rather than a
  parallel type system.
- `mix_coverage_test` enables Mix's console coverage; `mix_lcov_test` invokes
  ExCoveralls and copies its declared LCOV output to Bazel's
  `COVERAGE_OUTPUT_FILE`.
- `mix_ecto_test` starts declared `initdb`, `postgres`, and `createdb`
  executables against a fresh cluster below `TEST_TMPDIR`, then exposes only
  its loopback `DATABASE_URL` to ExUnit.
- `mix_wallaby_test` adds declared Chrome and ChromeDriver executables and
  exposes their runfile paths. Chrome itself is not downloaded or discovered
  by these rules.
- `rustler_nif` is an alias of `elixir_nif`: build the native shared library
  with `rules_rust`, then stage that declared artifact under the OTP
  application's `priv` directory. Rustler's internal Cargo build must be
  disabled for Bazel builds.
- `mix_phx_assets` (also exported as `mix_phx_digest`) runs `phx.digest` as a
  cacheable action and publishes the digested static tree as an
  `ElixirPrivInfo` mapping for `priv/static`; consume it through
  `mix_library(priv_entries = [...])`. JavaScript and CSS compilation remains
  owned by the appropriate Bazel JS rules. Map generated file or tree outputs
  to stable project-relative `priv/static/...` destinations with
  `elixir_generated_source`, then pass those mappings through
  `generated_srcs`; `srcs` is for files already below the Mix source root.

Postgres, Chrome, and ChromeDriver are required only by those two service-test
rules. They are not dependencies of `mix_library`, Phoenix, LiveView, releases,
the BCR module, or OTP/Elixir prebuilt archives. Requiring executable labels on
the test target prevents undeclared host discovery and makes the selected
service binaries part of the test cache key.

## Locked package assets

Generated dependency targets carry the identity and complete source mapping of
their checksum-pinned Hex archive. Use `hex_package_assets` when another Bazel
ecosystem needs a file from that archive:

```starlark
load("@rules_elixir_mix//:defs.bzl", "hex_package_assets")

hex_package_assets(
    name = "live_view_javascript",
    package = "@mix_deps//:phoenix_live_view",
    paths = ["priv/static/phoenix_live_view.esm.js"],
)
```

The public dependency-hub label remains stable; consumers never address the
module extension's private canonical repository name. A missing or normalized-
path-escaping asset fails during analysis. The selected file and its package
checksum identity remain owned by `mix.lock`, so a JavaScript or CSS rule does
not need a duplicate package-manager dependency.

## Escript tools

`mix_escript` turns an already compiled `mix_library` into an executable Bazel
tool. It stages the declared compile closure only to evaluate the project's
existing `escript` configuration, embeds the runtime dependency closure, and
runs `mix escript.build` offline without recompiling the application:

```starlark
load("@rules_elixir_mix//:defs.bzl", "mix_escript")

mix_escript(
    name = "schema_generator",
    lib = "@mix_deps//:schema_generator",
    output_name = "schema-gen",
)
```

`output_name` is optional and defaults to the Bazel target name. The result has
an executable `FilesToRunProvider`, so another rule may declare it as
`attr.label(executable = True, cfg = "exec")` and pass
`ctx.attr.tool[DefaultInfo].files_to_run` in `tools`. The output uses the
selected OTP runtime from runfiles, not `/usr/bin/env`, a host Elixir/Mix
installation, or a shell adapter. Sources, package locks, compiled dependency
artifacts, OTP/Elixir toolchains, FIPS policy, and provider runtime files are
all action inputs or configuration, so their changes invalidate the cache.

An escript used as a build tool is analyzed in the execution configuration.
Register an execution platform on which its OTP toolchain resolves; do not
pretend a target musl ABI is the worker ABI. A fully bundled runtime wrapper
may make the runtime independent of the worker libc, but CPU and OS constraints
still apply.

## Phoenix and local development

Writable Phoenix servers, code reloaders, and generators are intentionally
outside hermetic build actions. `mix_local` and `mix_phx_server` are explicit
`bazel run` workflows that use the real workspace and keep mutable Mix state in
`.bazel/elixir_mix`. They still use the selected hermetic OTP/Elixir toolchain
and fingerprinted dependency applications; an unchanged `bazel run` does not
recompile dependencies. Separate deterministic fingerprints cover compiled
artifacts and staged source projects, including logical paths, file types,
modes, and contents. Source patches, configuration/template changes,
executable-bit changes, toolchain changes, and rule changes therefore cannot
reuse stale local state. They do not create a second fake Mix project.
Explicitly mapped Bazel-generated project inputs are materialized at their
logical workspace destinations for local development. The workflow refuses to
overwrite a pre-existing or user-modified destination and removes a stale
generated file only when its last staged content is still unchanged.
`mix_iex` and `elixir_ls` use the same local graph; the latter expects the
caller to provide ElixirLS as an ordinary Mix dependency and runs its
language-server CLI without maintaining a second build tree.

Dependency maintenance is the one deliberately online local workflow. Declare
it explicitly so network policy is visible in the BUILD graph:

```starlark
load("@rules_elixir_mix//:defs.bzl", "mix_deps_update")

mix_deps_update(
    name = "update_mix_dependencies",
    hex = "@hex_pm//:lib",
    lib = ":app",
)
```

`bazel run //:update_mix_dependencies` executes `mix deps.update --all` against
the writable workspace with `HEX_OFFLINE=false`, using only the selected
declared OTP, Elixir, Mix, Hex, and dependency inputs. Ordinary `mix_local`
targets default to `HEX_OFFLINE=true`; build and test actions remain
network-blocked regardless of this local-only API. The explicit `hex` label is
mandatory so the workflow cannot invoke Mix's ambient Hex installer or borrow a
host archive.
