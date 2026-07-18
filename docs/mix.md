# Mix rules

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
- `native_build`: opt one application into the selected execution platform's
  registered C/C++ toolchain and declared Bash/Make/Perl/POSIX closure.

All inputs must be declared. Network access during compilation and tests is a
build error; add packages to `mix.lock` instead of calling `mix deps.get`.

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

The repository download is checksum-pinned; the Mix action itself remains
offline. For a package that must compile native sources, list its Hex package
name in `native_build_packages`. The lockfile's advertised build-tool list is
not used as an automatic signal because packages often advertise multiple
alternative managers. Native flags and tools affect only the selected package
action, not every BEAM dependency:

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
