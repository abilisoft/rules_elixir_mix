# Pull request

## Summary

<!--
Describe what changes, why it is necessary, and the affected public rules.
-->

## Hermeticity and compatibility

- [ ] Every tool, input, environment value, and runtime file is declared.
- [ ] No action depends on ambient host paths, host runtimes, or undeclared
      network access.
- [ ] Toolchain, execution-platform, runtime-ABI, and cache-key effects are
      documented.
- [ ] Public rule/provider compatibility is preserved, or the breaking change
      is explicit.
- [ ] Crypto/FIPS changes remain backend-neutral and keep provider provenance
      outside this repository.

## Validation

- [ ] `bazel test //:buildifier_test`
- [ ] Public rule-surface analysis passes.
- [ ] Integration, ExUnit, release, analysis, and cache tests pass.
- [ ] Pristine OTP/Elixir source-toolchain validation passes when affected.
- [ ] Every commit is Conventional and GitHub-verified signed.

## Notes for reviewers

<!--
Record non-obvious tradeoffs, external prerequisites, or deliberately deferred
work.
-->
