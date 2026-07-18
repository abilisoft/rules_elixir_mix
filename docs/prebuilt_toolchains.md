# Prebuilt toolchains

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
    name = "linux_arm64",
    otp_version = "29.0.3",
    otp_url = "https://artifacts.example/otp.tar.zst",
    otp_sha256 = "...",
    otp_strip_prefix = "otp",
    erlexec = "erts-17.0.3/bin/erlexec",
    elixir_version = "1.20.2",
    elixir_url = "https://artifacts.example/elixir.tar.gz",
    elixir_sha256 = "...",
    elixir_strip_prefix = "elixir",
    elixir_home_marker = "bin/elixir",
    bash = "@native_platform//:bash",
    make = "@native_platform//:make",
    perl = "@native_platform//:perl",
    posix_tools = ["@native_platform//:tools"],
    exec_compatible_with = [
        "@platforms//cpu:arm64",
        "@platforms//os:linux",
    ],
    runtime_abi = "//platforms:otp29_elixir120_glibc239_arm64",
)

use_repo(beam, "elixir_config")
register_toolchains(
    "@elixir_config//linux_arm64:otp_toolchain",
    "@elixir_config//linux_arm64:toolchain",
)
```

The archive checksum and every runtime file are action inputs, so OTP/Elixir
changes invalidate the relevant cache entries. `runtime_abi` is a mandatory,
dedicated constraint value that must also appear on the selected execution
platform. It identifies libc, loader, NIF ABI, and the immutable native runtime
closure; OS and CPU alone are not sufficient. Pin the execution platform image
by digest in `exec_properties` so that constraint has a concrete worker
meaning.

Mix actions do not execute `bin/elixir` or `bin/mix`; the marker is used only
to derive the extracted Elixir root. Actions enter Elixir through the declared
`erl` executable and the archive's BEAM libraries, avoiding shell launchers.

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
