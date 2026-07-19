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

The current runtime and static-linkage verifier are Linux-specific. Generated
toolchains therefore require `@platforms//os:linux` for both execution and
target platforms instead of advertising an unverified portable runtime.
Every toolchain tag also requires a dedicated `runtime_abi` constraint value.
The source-build action and all consuming actions resolve on a platform bearing
that value, which makes the selected libc, loader, C toolchain/NIF ABI, and
native runtime image part of toolchain resolution rather than ambient worker
state. Execution platforms should bind the value to a digest-pinned image.

The repository that produces the native platform owns that complete closure.
For a FIPS deployment, `rules_fips` may provide the musl or glibc C/C++
toolchain, linker, declared POSIX tools, normalized crypto SDK, and matching
`runtime_abi` constraint. `rules_elixir_mix` neither rebuilds nor identifies
those components. It consumes their Bazel targets while building pristine OTP
and Elixir sources. This prevents a second, subtly different libc or crypto
build from appearing here.

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
without shell traversal.

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

This means “fully static, no deployment payload.” It suits a
BoringCrypto-shaped SDK and clears ambient OpenSSL provider variables before a
FIPS-required BEAM starts. A provider-based OpenSSL SDK must use
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
    ],
    runtime_destinations = [
        "lib/ossl-modules/fips.so",
        "ssl/openssl.cnf",
        "bin/openssl",
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

With `fips = "required"` and `static_crypto_nif = True`, the OTP source action
owns these upstream configure flags:

```text
--with-ssl=<crypto-sdk>
--disable-dynamic-ssl-lib
--enable-fips
--enable-static-nifs
```

It then starts the installed, declared BEAM with `-crypto fips_mode true` and
fails unless FIPS is enabled, the crypto NIF is static, an approved operation
succeeds, and a prohibited operation fails. The same early BEAM argument and
normalized activation apply to Mix, Rebar, protocol consolidation, Dialyzer,
tests, and local workflows.

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
