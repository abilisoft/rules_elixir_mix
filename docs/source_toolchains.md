<!--
SPDX-FileCopyrightText: 2026 AbiliSoft
SPDX-License-Identifier: Apache-2.0
-->

# Source toolchains

[Documentation home](README.md) · [Getting started](getting_started.md) ·
[Prebuilt toolchains](prebuilt_toolchains.md) ·
[Agent playbook](agents/README.md)

Use this path when OTP configure flags, the selected C/C++ toolchain, or a
crypto SDK must be part of the runtime artifact. Build a variant once, publish
it by digest, and prefer the prebuilt path for repeated consumers.

## Build contract

`source_toolchain` builds Erlang/OTP through its upstream `configure` and
`make install` interface. The Bazel rule itself is Starlark and its action
driver is Erlang. It runs declared Bash and Make executables directly and never
uses `run_shell`, a generated wrapper, the host `PATH`, or the network.

Source construction requires:

- a checksum-pinned OTP source archive;
- a checksum-pinned bootstrap OTP runtime for the Erlang action driver;
- a checksum-pinned Elixir source archive;
- a hermetic Bazel C/C++ toolchain;
- declared Bash, Make, POSIX-tool, and Perl targets.

The bootstrap OTP does not become part of the registered runtime. It is an
ordinary action input, just as a bootstrap compiler is for any self-hosting
language.

## Known source versions

The pinned ruleset carries an immutable catalog of source archive URLs,
SHA-256 digests, extraction metadata, and one latest-tested default tuple.
Omitting `otp_version` and `elixir_version` selects that fixed tuple. This is a
local Starlark lookup: it never discovers a moving release during repository
evaluation.

```starlark
beam = use_extension(
    "@rules_elixir_mix//bzlmod:toolchains.bzl",
    "elixir_config",
)

beam.source_toolchain(
    name = "beam_source",
    bootstrap_otp_version = "29.0.3",
    bootstrap_otp_url = "https://artifacts.example/otp-bootstrap.tar.gz",
    bootstrap_otp_sha256 = "<64-hex-sha256>",
    bootstrap_erlexec = "erts-17.0.3/bin/erlexec",
    bootstrap_boot_file = "releases/29/start_clean.boot",
    bootstrap_otp_fully_static = True,
    bash = "@native_platform//:bash",
    make = "@native_platform//:make",
    otp_fully_static = True,
    perl = "@native_platform//:perl",
    posix_tools = ["@native_platform//:tools"],
    exec_compatible_with = [
        "@platforms//cpu:x86_64",
        "@platforms//os:linux",
    ],
    libc = "glibc",
    runtime_abi = "//platforms:otp29_elixir120_linux_x86_64",
)
```

`bootstrap_boot_file` supports pre-install archives that contain
`releases/<major>/start_clean.boot` but no installed `bin/start.boot`. Its
extensionless declared path is passed through `ERL_AFLAGS`, including nested
bootstrap launches, and no archive installer is executed.

The URL bootstrap form requires `bootstrap_otp_fully_static = True`, and the
generated prebuilt rule verifies every executable ELF and recursively resolves
every NIF/shared-object dependency from declared archive inputs before the
expensive source build begins. A dynamically linked bootstrap must be a
provider-backed `OtpInfo` target that owns its complete normalized execution
closure. A wrapper around only `erlexec` is insufficient because `beam.smp`,
OTP port programs, and loadable NIFs have independent native dependencies.

Another Bazel rule may own the complete bootstrap runtime instead of an HTTP
archive:

```starlark
beam.source_toolchain(
    name = "beam_source",
    bootstrap_otp = "//toolchains:otp_29_bootstrap",
    bootstrap_exec_compatible_with = [
        "@platforms//cpu:x86_64",
        "@platforms//os:linux",
    ],
    # Remaining source and native-tool attributes omitted.
)
```

The provider target must expose `OtpInfo`; archive metadata and
`bootstrap_otp` are mutually exclusive. Every generated source toolchain also
exports `@elixir_config//<name>:bootstrap_smoke_test`. Run that focused target
before the expensive source build to surface an incompatible loader, libc, or
CPU without host fallback.

Set `otp_version` or `elixir_version` to another cataloged value when needed.
For a version absent from the catalog, set that language's `*_url` and
`*_sha256` together; optional `*_strip_prefix` and `*_type` then describe the
custom archive. Mirrors belong in `otp_urls` or `elixir_urls`. Partial
overrides fail during module-extension evaluation.
Custom URLs must use HTTPS, digests must be lowercase SHA-256, extraction
prefixes must be normalized relative paths, and extracted trees reject
dangling or escaping symlinks.

The catalog deliberately does not cover prebuilt runtimes. Those bytes depend
on the producer, target platform, libc, loader, NIF ABI, and native closure, so
`prebuilt_toolchain` continues to require explicit archive URLs and digests.
Updating the default source tuple requires upgrading the pinned ruleset and is
therefore an ordinary reviewable dependency change.

The `Source catalog` workflow checks the official stable OTP and Elixir GitHub
releases every six hours. When either changes, it hashes the immutable tag
archive without executing it and opens a pull request using a GitHub-verified
bot commit. The source-toolchain job then builds the proposed default tuple
from pristine sources. A release becomes a known, tested default only after
that pull request passes the full matrix and is merged.

The current runtime and static-linkage verifier are Linux-specific. Generated
toolchains therefore require `@platforms//os:linux` for both execution and
target platforms instead of advertising an unverified portable runtime.
Every toolchain tag also requires a dedicated `runtime_abi` constraint value.
That value constrains the produced runtime and its consumers only; it is not
added to `exec_compatible_with`. The build host is described independently by
the caller's execution OS, CPU, and declared tool closures. This permits, for
example, an x86-64 glibc worker to produce an x86-64 musl runtime without
falsely labeling the worker as musl.

Each generated profile also exports a Bazel test toolchain. Register it with
the OTP and Elixir toolchains. Bazel 9 otherwise applies a test's target
constraints to its execution platform before the rule's declared runtime
wrapper can start the target-ABI BEAM. The generated test toolchain binds test
execution to the real build-host OS and CPU while retaining the produced
runtime ABI on the target. It does not advertise musl or FIPS as properties of
a GNU worker.

`libc` describes the produced runtime and is independent from the build-host
ABI. For x86-64 musl, set `jit = "disabled"`. The extension rejects `auto` or
`required` because OTP's x86 JIT can exceed musl's fixed signal stack on hosts
with a large `AT_MINSIGSTKSZ`. The generated smoke target verifies the emulator
flavor. glibc and Arm64 profiles may request `jit = "required"` and are checked
the same way.

Separation is not permission to use the host. The selected C/C++ toolchain,
sysroot, compiler runtime, Bash, Make, Perl, POSIX tools, bootstrap runtime,
loader wrapper, and crypto SDK must still be declared inputs. A source build
that needs to execute a target-ABI bootstrap on a different execution ABI must
use a provider-backed bootstrap with its own execution overlay and declare
`bootstrap_exec_compatible_with`; it never discovers a host loader or library.

The repository that produces the native platform owns that complete closure.
For a FIPS deployment, `rules_fips` may provide the musl or glibc C/C++
toolchain, linker, declared POSIX tools, normalized crypto SDK, and matching
`runtime_abi` constraint. `rules_elixir_mix` neither rebuilds nor identifies
those components. It consumes their Bazel targets while building pristine OTP
and Elixir sources. This prevents a second, subtly different libc or crypto
build from appearing here.

### Native runtime shapes

The runtime ABI and linkage shape are independent choices. The rules support
dynamic glibc, wrapped-dynamic musl, and fully static musl source builds on
AMD64 and ARM64 when the selected C/C++ toolchain and SDK provide that exact
contract. A glibc build is constrained by its declared ABI floor, not by a
Linux distribution name.

Do not infer a fully static VM from `static_crypto_nif = True`. That setting
embeds OTP's crypto NIF in the emulator, but the emulator may still be a
wrapped dynamic executable. OpenSSL 3 FIPS needs its declared provider module,
and Phoenix, LiveView, Rustler, and other packages may load application NIFs;
those profiles use the wrapped-dynamic contract even when their target libc is
musl. Set `otp_fully_static = True` only when the whole native runtime and SDK
are genuinely static and the application does not require loadable NIFs or a
dynamic crypto provider.

The source rule requires exactly one native-runtime contract. A dynamic SDK
must provide both target and execution wrappers; after verification, the OTP
driver replaces every dynamic executable in the installed tree with that
declared static wrapper and retains the real program beside it. This includes
port programs outside `erts-*/bin` and survives deterministic archive
assembly. For a source profile whose C/C++ toolchain produces only static
executables, set `otp_fully_static = True`; the driver scans the complete
installed tree and fails if any executable ELF still has an interpreter. Both
contracts also parse every ELF in the installed runtime and recursively require
each `DT_NEEDED` library to resolve uniquely from the runtime or declared SDK.
Absolute/escaping archive symlinks and host-library fallback fail verification.

## Native tool handoff

The source toolchain's declared Bash, Make, Perl, and POSIX targets are also
attached to the generated Elixir toolchain for selective native Hex builds.
They are not added to ordinary Mix actions. A package explicitly marked
`native_build` resolves the same registered Bazel C/C++ toolchain used for OTP
and receives the declared tools as action inputs with a strict action-local
environment. This is the handoff point for a `rules_fips`-produced musl or
glibc closure; this repository does not construct a second native sysroot.

Source files are copied by content into the action's writable tree. Bazel may
represent repository inputs as symlinks into its content-addressed cache;
preserving those links would allow upstream configure or Make steps to mutate
declared inputs. A Starlark repository rule also records empty directories from
the checksum-pinned archive so the staged source topology matches upstream
without shell traversal. OTP and Elixir language/runtime sources are not
patched. In the writable staging copy, interpreter headers and generated
launcher references are rebound to the declared Bash, Perl, and escript tools;
otherwise upstream `/bin/sh` and `/usr/bin/env` shebangs would escape the
hermetic action. Those launchers are not the consumer API.

## Crypto selection

A source toolchain without `crypto_sdk` configures OTP with `--without-ssl`.
This prevents `configure` from discovering a host OpenSSL installation. Source
toolchains that need `crypto`, `ssl`, TLS, or FIPS must declare a normalized
crypto SDK; there is no ambient-system fallback.

## Backend-neutral crypto SDK

The compatibility form of `crypto_sdk` is one directory artifact:

```text
crypto-sdk/
├── include/
└── lib/
    └── libcrypto.a
```

This means “fully static, no deployment payload.” It suits any compatible
fully static SDK and clears ambient provider configuration before a
FIPS-required BEAM starts. An SDK with a runtime provider payload must use
`otp_crypto_sdk`; otherwise OTP's build-time FIPS verification fails instead of
borrowing host configuration.

```starlark
load("@rules_elixir_mix//:defs.bzl", "otp_crypto_sdk")

otp_crypto_sdk(
    name = "openssl_fips_sdk",
    sysroot = "@crypto//:sdk",
    fully_static = False,
    runtime_files = [
        "@crypto//:fips_module",
        "@crypto//:openssl_config",
        "@crypto//:openssl_for_target",
        "@crypto//:runtime_libraries",
        "@crypto//:runtime_wrapper_target",
    ],
    runtime_destinations = [
        "lib/ossl-modules/fips.so",
        "ssl/openssl.cnf",
        "bin/openssl",
        "lib",
        "bin/runtime-launch",
    ],
    runtime_environment = {
        "OPENSSL_CONF": "{sysroot}/ssl/openssl.cnf",
        "OPENSSL_MODULES": "{sysroot}/lib/ossl-modules",
        "FIPS_MODULE_CONF": "{activation_root}/fipsmodule.cnf",
    },
    activation_exec_tool = "@crypto//:openssl_for_exec",
    activation_tool = "@crypto//:openssl_for_target",
    activation_tool_release_path = "bin/openssl",
    activation_args = [
        "fipsinstall",
        "-out",
        "{activation_root}/fipsmodule.cnf",
        "-module",
        "{sysroot}/lib/ossl-modules/fips.so",
    ],
    cc_features = ["rules_fips_dynamic_executable"],
    build_elf_interpreter = "/__bazel_hermetic_runtime__/declared-loader",
    execution_exec_wrapper = "@crypto//:runtime_wrapper_exec",
    execution_wrapper = "@crypto//:runtime_wrapper_target",
    execution_wrapper_environment = {
        "RULES_CRYPTO_RUNTIME_LIBRARY_PATH": "{sysroot}/lib",
        "RULES_CRYPTO_RUNTIME_LOADER": "{sysroot}/lib/ld-runtime.so.1",
        "RULES_CRYPTO_RUNTIME_PROGRAM": "{program}",
    },
    execution_wrapper_release_path = "bin/runtime-launch",
)
```

The SDK producer decides the payload layout. `{sysroot}` expands to the
declared build SDK during Bazel actions and to the packaged
`.rules_elixir_mix/crypto_sdk` directory inside a release.
`{activation_root}` is a writable, action/deployment-specific state directory.
The activation command is a declared executable and argument vector; it never
passes through a shell. The execution-configured activation tool and the
release-packaged activation executable may be different builds, but both must
come from declared SDK artifacts.

For a provider-backed SDK whose OTP build executables are dynamically linked,
`build_elf_interpreter` is the fail-closed marker emitted by the selected C/C++
toolchain. The source driver replaces that linker argument with the declared
SDK loader while building, then normalizes installed real executables to
deliberately unusable, execroot-independent interpreter and runpath markers.
Only the adjacent static wrapper may start them, using the SDK's declared
loader and libraries. `cc_features` lets the producer opt only OTP executable
link actions into that dynamic contract; shared-library actions must never
inherit an executable-only `-static` flag. Fully static SDKs may not declare
any of these runtime fields.

With `fips = "required"` and `static_crypto_nif = True`, the OTP source action
owns these upstream configure flags:

```text
--with-ssl=<crypto-sdk>
--disable-dynamic-ssl-lib
--enable-fips
--enable-static-nifs
```

Compilation uses the FIPS-capable OTP and SDK without `-crypto fips_mode true`
or provider activation. After installation, the source rule starts the declared
BEAM with explicit FIPS activation and fails unless FIPS is enabled, the crypto
NIF is static, an approved operation succeeds, and a prohibited operation
fails. Runtime tests repeat that activation explicitly. FIPS-required releases
persist it in release configuration; ordinary Mix, Rebar, protocol,
Dialyzer, escript, and writable local actions do not activate FIPS merely
because the selected toolchain is capable.

The rule does not append `libcrypto.a` to generic `LDFLAGS`; static archive
ordering remains owned by OTP's generated build. The source action must link
and start the resulting BEAM successfully, and `elixir_fips_runtime_test`
independently rejects dynamic `libcrypto`/`libssl` dependencies. There is no
silent alternate link path.

`rules_elixir_mix` never interprets `backend_metadata`, recognizes backend
names, downloads crypto or libc sources, validates a certificate, or falls back
between SDKs. A producer such as `rules_fips` owns source integrity, the native
toolchain closure, static archive, provider payload, provenance, validation
metadata, and backend-specific tests. There is intentionally no direct
repository dependency between the rule sets: integration happens through
ordinary Bazel targets and constraints. This repository owns only the OTP
adapter and shared fail-closed behavior.

## Cache strategy

An OTP source build is one large, deterministic Bazel action. It uses declared
inputs, a fixed locale/time zone/source date, blocked networking, parallel Make,
and compiler prefix maps. Remote caching therefore works, but downloading a
previously published prebuilt runtime is still the best fleet-wide path. Build
source variants once per `{OTP patch, platform, C toolchain, configure options,
crypto SDK}` tuple, publish them by digest, and use `prebuilt_toolchain` for the
normal CI graph.
