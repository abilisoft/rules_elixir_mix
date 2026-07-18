# rules_elixir_mix

Hermetic, Mix-first Bazel rules for Elixir, Phoenix, LiveView, and ExUnit.

This ruleset is Bzlmod-only and targets Bazel 9.2.0 or newer. The checked-in
`.bazelversion` pins the current Bazel 9 LTS release for Bazelisk.

The design is deliberately small:

- Bazel owns pinned inputs, OTP+Elixir toolchains, isolation, and caching.
- Mix owns Elixir/Erlang compilation, compiler plugins, ExUnit, and releases.
- Hex packages come from `mix.lock` and are downloaded by checksum.
- Phoenix, LiveView, Wallaby, Credo, Dialyxir, and Sobelow are ordinary Mix
  dependencies—not toolchains.
- OTP can be built from source with a declared C/C++ toolchain and declared
  bootstrap tools, or consumed as a checksum-pinned prebuilt runtime.
- An OTP source build may consume an optional generic static crypto SDK.
  Building, validating, and certifying that SDK belongs to its producer (for
  example, `rules_fips`), not to this repository. That producer may also own
  the matching musl/glibc C/C++ and POSIX execution-tool closure.
- FIPS-required SDKs may be fully static or carry a normalized provider
  runtime/activation contract; rules never branch on backend identity.

Rule implementations are Starlark. They invoke declared Elixir/Erlang
executables directly; ordinary Mix actions have no generated shell scripts or
shell actions. OTP source construction uses an Erlang action driver to invoke
declared Bash and Make executables because those are OTP's upstream build
interface. It does not generate or maintain a shell wrapper.

## Toolchain

Build OTP 29 from source when its native/crypto configuration is part of the
artifact identity:

```starlark
elixir_config = use_extension(
    "@rules_elixir_mix//bzlmod:toolchains.bzl",
    "elixir_config",
)
elixir_config.source_toolchain(
    name = "linux_x86_64",
    bootstrap_otp_version = "29.0.3",
    bootstrap_otp_url = "https://artifacts.example/otp-bootstrap.tar.zst",
    bootstrap_otp_sha256 = "...",
    bootstrap_erlexec = "erts-17.0.3/bin/erlexec",
    otp_version = "29.0.3",
    otp_url = "https://github.com/erlang/otp/releases/download/OTP-29.0.3/otp_src_29.0.3.tar.gz",
    otp_sha256 = "...",
    otp_strip_prefix = "otp_src_29.0.3",
    elixir_version = "1.20.2",
    elixir_url = "https://github.com/elixir-lang/elixir/archive/refs/tags/v1.20.2.tar.gz",
    elixir_sha256 = "...",
    elixir_strip_prefix = "elixir-1.20.2",
    bash = "@hermetic_posix//:bash",
    make = "@hermetic_posix//:make",
    perl = "@hermetic_posix//:perl",
    posix_tools = ["@hermetic_posix//:tools"],
    exec_compatible_with = [
        "@platforms//cpu:x86_64",
        "@platforms//os:linux",
    ],
    runtime_abi = "//platforms:otp29_elixir120_glibc239",
)
use_repo(elixir_config, "elixir_config")
register_toolchains(
    "@elixir_config//linux_x86_64:otp_toolchain",
    "@elixir_config//linux_x86_64:toolchain",
)
```

The bootstrap runtime is only the declared executable for the Erlang build
driver; the registered runtime is the OTP output built from `otp_url`. The
selected Bazel C/C++ toolchain, Bash, Make, POSIX tools, source archives, and
bootstrap runtime are all action inputs. There is no host-runtime mode.

For the fastest CI and remote execution path, publish that result once and use
checksum-pinned, already-extracted OTP and Elixir archives:

```starlark
bazel_dep(name = "platforms", version = "1.1.0")

elixir_config.prebuilt_toolchain(
    name = "linux_x86_64",
    otp_version = "29.0.3",
    otp_url = "https://artifacts.example/otp-29.0.3-linux-x86_64.tar.zst",
    otp_sha256 = "...",
    erlexec = "erts-17.0.3/bin/erlexec",
    elixir_version = "1.20.2",
    elixir_url = "https://artifacts.example/elixir-1.20.2-otp-29.tar.gz",
    elixir_sha256 = "...",
    exec_compatible_with = [
        "@platforms//cpu:x86_64",
        "@platforms//os:linux",
    ],
    runtime_abi = "//platforms:otp29_elixir120_glibc239",
)
register_toolchains(
    "@elixir_config//linux_x86_64:otp_toolchain",
    "@elixir_config//linux_x86_64:toolchain",
)
```

`runtime_abi` is a caller-defined constraint value shared by the toolchain and
its execution platform. It identifies the complete native ABI/runtime-image
contract (libc, loader, NIF ABI, and any dynamically linked system closure),
so an archive cannot resolve on an incompatible worker merely because OS and
CPU match. Pin the execution platform's container image by digest as well.

Both archives are repository inputs. Nothing is extracted into `/tmp`, and no
runtime installation action runs during the build. See [source toolchains](docs/source_toolchains.md)
and [prebuilt toolchains](docs/prebuilt_toolchains.md).

## Mix dependencies

Use the checked-in `mix.lock` as the dependency graph and checksum source:

```starlark
packages = use_extension(
    "@rules_elixir_mix//bzlmod:packages.bzl",
    "elixir_packages",
)
packages.mix_lock(
    name = "mix_deps",
    lockfile = "//:mix.lock",
    repositories = {
        "hexpm": "https://repo.hex.pm",
    },
)
use_repo(packages, "hex_pm", "mix_deps")
```

The pure-Starlark lock parser creates one immutable repository per Hex package
and a single `@mix_deps` alias hub. Mix actions run with `HEX_OFFLINE=true` and
network access blocked.

For native Hex dependencies, prefer a checksum-pinned producer archive through
`precompiled_native_artifacts`. If source compilation is required, name only
those packages in `native_build_packages`; their actions resolve the standard
Bazel C/C++ toolchain and the Bash/Make/Perl/POSIX targets declared on the
selected Elixir toolchain. A platform producer such as `rules_fips` owns that
musl/glibc closure. These rules consume it without rebuilding it or adding it
to pure-BEAM action inputs. See [Mix details](docs/mix.md).

## Elixir application

```starlark
load(
    "@rules_elixir_mix//:defs.bzl",
    "elixir_generated_source",
    "mix_format_test",
    "mix_library",
    "mix_phx_assets",
    "mix_test",
)

mix_library(
    name = "app",
    app_name = "my_app",
    mix_config = "mix.exs",
    srcs = glob(["lib/**/*.ex"]),
    config = glob(["config/**/*.exs"]),
    data = glob(["lib/**/*.eex", "lib/**/*.heex"]),
    priv = glob(["priv/**/*"]),
    deps = [
        "@mix_deps//:jason",
    ],
)

mix_library(
    name = "app_test",
    app_name = "my_app",
    mix_config = "mix.exs",
    mix_env = "test",
    srcs = glob(["lib/**/*.ex", "test/support/**/*.ex"]),
    config = glob(["config/**/*.exs"]),
    data = glob(["lib/**/*.eex", "lib/**/*.heex"]),
    priv = glob(["priv/**/*"]),
    deps = ["@mix_deps//:jason"],
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
```

Elixir 1.20's gradual set-theoretic type inference runs in the normal compiler,
so `mix_library` is the type-checking boundary. Warnings fail first-party
compilation by default.

## Direct Erlang applications

`erlang_app` compiles one OTP application without Mix or Rebar while retaining
the same toolchain, dependency, deterministic-BEAM, `priv`, include, and
runfiles model:

```starlark
load(
    "@rules_elixir_mix//:defs.bzl",
    "erlang_app",
    "erlang_common_test",
    "erlang_eunit_test",
)

erlang_app(
    name = "worker",
    app_name = "worker",
    version = "1.0.0",
    srcs = glob([
        "src/*.erl",
        "src/*.xrl",
        "src/*.yrl",
    ]) + ["src/worker.app.src"],
    hdrs = glob(["include/*.hrl"]),
    defines = {"FEATURE_FLAG": "true"},
    erlc_opts = ["warn_export_all"],
    compile_deps = [":parse_transform"],
    type_deps = [":public_types"],
    runtime_deps = [":runtime_support"],
)

erlang_eunit_test(
    name = "unit",
    apps = [":worker"],
)

erlang_common_test(
    name = "common",
    apps = [":worker"],
    suites = ["worker_SUITE"],
    groups = ["integration"],
    config = ["test/common_test.config"],
    suite_data = {
        "test/worker_SUITE_data/payload.json": "worker_SUITE/payload.json",
    },
)
```

Compiler options are Erlang terms, parsed without a shell. The rule owns
deterministic/debug-info/output options so callers cannot accidentally disable
reproducibility or Dialyzer input. Common Test supports explicit suites,
groups, cases, hooks, repeat count, verbosity, config files, and suite data;
Bazel supplies isolation, runfiles, caching, and test logs.

## Phoenix and LiveView

Phoenix and LiveView use the same `mix_library` rule. Include `.heex`/`.eex`
templates in `data`, `test/support` in the test library's `srcs`, configuration
files in `config`, and generated/static assets under `priv`. Declare the direct
Mix dependencies through the lock hub, for example:

```starlark
deps = [
    "@mix_deps//:bandit",
    "@mix_deps//:jason",
    "@mix_deps//:phoenix",
    "@mix_deps//:phoenix_html",
    "@mix_deps//:phoenix_live_view",
]
```

JavaScript and CSS compilation belongs to the relevant Bazel JS rules; pass
their declared outputs to `mix_phx_assets` for cacheable `phx.digest` output,
then map that provider into `priv/static` through `priv_entries` before
`mix_release` assembles the OTP release:

```starlark
elixir_generated_source(
    name = "compiled_js_project_input",
    src = ":compiled_js",
    destination = "priv/static/assets/app.js",
)

elixir_generated_source(
    name = "compiled_css_project_input",
    src = ":compiled_css",
    destination = "priv/static/assets/app.css",
)

mix_phx_assets(
    name = "digested_assets",
    lib = ":app",
    generated_srcs = [
        ":compiled_css_project_input",
        ":compiled_js_project_input",
    ],
)

mix_library(
    name = "release_app",
    app_name = "my_app",
    mix_config = "mix.exs",
    srcs = glob(["lib/**/*.ex"]),
    priv_entries = [":digested_assets"],
)
```

## Analysis and browser tests

The public API includes cached Bazel test targets for:

- `mix_ex_unit_test` / `mix_test`
- `mix_coverage_test`
- `mix_format_test`
- `mix_credo_test`
- `mix_dialyzer_test`
- `mix_sobelow_test` for Phoenix security analysis
- `mix_xref_test` with an explicit current Xref mode
- `mix_wallaby_test`

Wallaby's Chrome and ChromeDriver binaries are target-platform runtime tools:

```starlark
mix_wallaby_test(
    name = "features",
    lib = ":app_test",
    chrome = "@chrome_for_testing//:chrome",
    chromedriver = "@chrome_for_testing//:chromedriver",
    srcs = glob(["test/features/**/*_test.exs"]),
)
```

Configure `Wallaby.Chrome` in `config/test.exs` from `WALLABY_CHROME` and
`WALLABY_CHROMEDRIVER`. Wallaby may use localhost; the Bazel `block-network`
tag denies external networking without preventing loopback browser traffic.

See [Mix details](docs/mix.md) and [releases](docs/releases.md).

## FIPS crypto profiles

`source_toolchain(fips = "required", static_crypto_nif = True)` builds pristine
OTP 29+ with its upstream static-crypto/FIPS flags. Every subsequent Erlang
invocation receives `-crypto fips_mode true` before Elixir, Mix, Hex, Rebar, or
application dependencies can load crypto. `mix_release` persists the policy in
`sys.config`, and `elixir_fips_runtime_test` checks the backend-neutral runtime
and ELF linkage contract.

`otp_crypto_sdk` normalizes two runtime shapes without coupling this module to
`rules_fips`:

- a fully static SDK has no runtime files, environment, or activation tool;
- a provider-backed SDK declares its packaged payload, environment templates,
  direct activation executable/arguments, and opaque producer metadata.

The provider-backed form is an OpenSSL-3-shaped, backend-neutral contract: each
build/test action generates its own activation state, while a release invokes
its packaged activation tool from `runtime.exs` immediately before applications
start. A producer-backed OpenSSL matrix is required before claiming a specific
OpenSSL/FIPS combination is verified. Ambient OpenSSL paths are cleared, so
neither path can silently use the host installation.
BoringCrypto certification data, OpenSSL provider identity, source digests,
and backend-specific service indicators remain entirely with the SDK producer.
See [source toolchains](docs/source_toolchains.md) for the complete contract.
