# Phoenix + FIPS consumer proof

This directory is an independent Bazel module that consumes both
`rules_elixir_mix` and `rules_fips`. It is an executable compatibility test,
not a mocked analysis fixture.

The project builds OTP 29 and Elixir 1.20 from source, imports checksum-pinned
Hex packages, compiles a Phoenix 1.8 application with a stateful LiveView, and
uses the normalized OpenSSL FIPS SDK exported by `rules_fips`.

The targets prove distinct boundaries:

- `//:test` starts the application, requires OTP FIPS mode and static crypto,
  then renders the LiveView route through the Phoenix endpoint.
- `//:fips_runtime` verifies the generic OTP FIPS runtime contract.
- `//:release_test` assembles a production release, starts its Bandit endpoint,
  verifies packaged crypto activation, and boots without ambient crypto state.
- `//:source_escript_codegen` builds the application as an offline escript in
  the execution configuration and runs it as a declared code-generation tool.

CI executes the runtime targets and escript tool natively on AMD64 and Arm64,
then repeats them to require reusable Bazel cache entries. Each GNU glibc
platform serves as both its native target and the execution platform for tools
transitioned into the execution configuration. That keeps one cache identity
for the source-built GNU runtime; the produced musl tuple remains a target-only
constraint. The bootstrap OTP archive is a declared, checksum-verified input;
consumers should replace its CI-local URL with their own integrity-pinned
artifact URL.
