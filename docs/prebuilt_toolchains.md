<!--
SPDX-FileCopyrightText: 2026 AbiliSoft
SPDX-License-Identifier: Apache-2.0
-->

# Prebuilt toolchains

[Documentation home](README.md) · [Getting started](getting_started.md) ·
[Source toolchains](source_toolchains.md) · [Agent playbook](agents/README.md)

Use this path when a producer already supplies verified OTP and Elixir archives
for the exact target runtime ABI. It is the normal low-latency CI path.

A prebuilt toolchain is a pair of checksum-pinned archives: one OTP runtime and
one Elixir runtime built for that OTP version. Archives must already be usable
after extraction; `rules_elixir_mix` does not relocate or install them.

```starlark
bazel_dep(name = "platforms", version = "1.1.0")

beam = use_extension(
    "@rules_elixir_mix//bzlmod:toolchains.bzl",
    "elixir_config",
)

beam.prebuilt_toolchain(
    name = "linux_x86_64",
    otp_version = "29.0.3",
    otp_url = "https://artifacts.example/otp-29.0.3-linux-x86_64.tar.gz",
    otp_sha256 = "...",
    otp_strip_prefix = "otp-29.0.3-linux-x86_64",
    otp_type = "tar.gz",
    erlexec = "erts-17.0.3/bin/erlexec",
    otp_fully_static = True,
    elixir_version = "1.20.2",
    elixir_url = "https://artifacts.example/elixir-1.20.2-otp-29-linux-x86_64.tar.gz",
    elixir_sha256 = "...",
    elixir_strip_prefix = "elixir-1.20.2-otp-29-linux-x86_64",
    elixir_type = "tar.gz",
    elixir_home_marker = "bin/.runtime_root",
    bash = "@native_platform//:bash",
    make = "@native_platform//:make",
    perl = "@native_platform//:perl",
    posix_tools = ["@native_platform//:tools"],
    exec_compatible_with = [
        "@platforms//cpu:x86_64",
        "@platforms//os:linux",
    ],
    runtime_abi = "//platforms:otp29_elixir120_glibc235_x86_64",
)

use_repo(beam, "elixir_config")
register_toolchains(
    "@elixir_config//linux_x86_64:otp_toolchain",
    "@elixir_config//linux_x86_64:toolchain",
    "@elixir_config//linux_x86_64:test_toolchain",
)
```

Linux x86-64 (`@platforms//cpu:x86_64`) and Linux ARM64
(`@platforms//cpu:arm64`) are maintained. The example shows one x86-64
registration for readability. Register a second tag and toolchain pair with
ARM64-specific URLs, SHA-256 values, `exec_compatible_with`, and `runtime_abi`;
never reuse the x86-64 archive or ABI constraint. When multiple tags are
registered, set exactly one `default = True` and put the generated
`@elixir_config//:runtime_<tag_name>` constraint on each corresponding
platform. The generated constraint chooses the requested tuple; the dedicated
`runtime_abi` describes whether its native closure is actually compatible.
macOS, Windows, and cross-compilation are not claimed.

## Produce archives from a source toolchain

`beam_runtime_archive` turns the `otp` and `runtime` targets emitted by a
source toolchain into normalized `tar.gz` files. The source toolchain must use
a declared `crypto_sdk`; the archive action uses that runtime's own `crypto`
application to generate SHA-256 instead of discovering a host checksum tool.

```starlark
load("@rules_elixir_mix//:defs.bzl", "beam_runtime_archive")

beam_runtime_archive(
    name = "otp-29.0.3-linux-x86_64",
    package_dir = "otp-29.0.3-linux-x86_64",
    runtime = "@elixir_config//linux_x86_64_source:otp",
)

beam_runtime_archive(
    name = "elixir-1.20.2-otp-29-linux-x86_64",
    package_dir = "elixir-1.20.2-otp-29-linux-x86_64",
    runtime = "@elixir_config//linux_x86_64_source:runtime",
)
```

Each target emits the archive, a lowercase hexadecimal `.sha256`, and a
`.metadata.json` file containing the version, strip prefix, archive type, and
the marker paths required by `prebuilt_toolchain`. The action sorts archive
entries, uses zero timestamps and numeric ownership, normalizes immutable file
modes, rejects escaping symlinks, blocks network access, and never invokes a
shell.

Repeat both archive targets on each native producer platform. Publishing those
files is a producer responsibility. For a FIPS archive, the
release gate must also pass the crypto producer's provenance tests and
`elixir_fips_runtime_test`; this ruleset does not turn a successful archive
action into a backend certification. See [Publishing](publishing.md).

An OTP archive produced from a dynamically linked crypto SDK contains a static
wrapper beside every real native executable. Import that archive with
`otp_runtime_wrapped = True` and the same normalized `crypto_sdk`. The import
action verifies the complete tree, including OTP port programs outside the
ERTS directory; it does not treat one wrapper around `erlexec` as a complete
runtime contract. It also recursively validates `DT_NEEDED` for executables,
NIFs, and shared objects against only the archive and normalized SDK.

## Archive and platform contract

The archive checksum and every runtime file are action inputs, so OTP/Elixir
changes invalidate the relevant cache entries. `runtime_abi` is a mandatory,
dedicated target constraint identifying libc, loader, NIF ABI, and the
immutable native runtime closure; OS and CPU alone are not sufficient. It is
not an execution-platform label. `exec_compatible_with` independently names
where the archive itself can run. This constraint is mandatory in practice for
both generated toolchains and direct `otp_prebuilt_release` targets: it stops
Bazel before a foreign-CPU executable can reach the operating system's
`ENOEXEC` shell fallback. It must name the archive's real Linux CPU, not the
machine on which the BUILD file was authored.

The public archive repository rejects dangling and escaping symlinks before
analysis exposes any extracted file. Runtime verification then proves the
complete ELF closure rather than trusting archive layout alone.

An archive must select exactly one verified native contract. Set
`otp_fully_static = True` when every native OTP executable is statically
linked. Set `otp_runtime_wrapped = True` only for an archive whose every
dynamic executable has an adjacent static wrapper and declare the SDK that
owns the loader and runtime libraries. The verification action walks the
entire archive and rejects a dynamic executable outside that shape.
It additionally rejects missing or ambiguous native dependencies, including
dependencies reached only after a NIF is loaded.
Arbitrary dynamically linked distributor archives are not accepted through
the URL form because a launcher for one process cannot make its descendants
hermetic. A Bazel producer may instead expose a provider-backed `OtpInfo` that
owns a complete normalized runtime.
Merely selecting a worker whose host happens to contain a compatible libc is
not sufficient. The verification action blocks networking and does not invoke
an install script, relocate the archive, search `PATH`, or fall back to host
libraries. A common distributor's pre-install archive may set `otp_boot_file`
to its declared `releases/<major>/start_clean.boot`; the path is passed
extensionless with `-boot` during verification and every downstream BEAM
launch, and the installer remains unexecuted.

Mix actions do not execute `bin/elixir` or `bin/mix`; the marker is used only
to derive the extracted Elixir root. Actions enter Elixir through the declared
`erl` executable and the archive's BEAM libraries, avoiding shell launchers.

Chrome and Postgres are not part of OTP/Elixir archives. Declare them only on
`mix_wallaby_test` and `mix_ecto_test` targets that actually start those
services.

## FIPS and native-package tools

Prebuilt FIPS runtimes must declare `fips = "required"`,
`static_crypto_nif = True`, and the same `crypto_sdk` contract as source
toolchains. Requiring the SDK shape prevents an OpenSSL-based archive from
silently using host provider configuration. The archive producer must already
have built OTP with the matching SDK and flags. `elixir_fips_runtime_test`
verifies the shared OTP behavior and ELF linkage; provider identity,
certificate/version metadata, and service indicators remain tests of the SDK
producer.

The optional Bash/Make/Perl/POSIX labels are not used by ordinary BEAM
packages. They become inputs only for `mix_library(native_build = True)` or a
Hex package named in `mix_lock(native_build_packages = [...])`. The native
action also resolves the standard Bazel C/C++ toolchain, so a producer such as
`rules_fips` can supply the complete musl/glibc platform closure without a
direct repository dependency. Declare all four tool fields together; omitting
them makes native source compilation fail at analysis rather than borrow host
tools.
