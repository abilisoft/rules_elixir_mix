# Mix releases

`mix_release` invokes `mix release --path <declared output>` directly. Mix owns
boot scripts, runtime configuration, overlays, protocol consolidation, and
ERTS inclusion. The rule does not post-process the release with shell commands.

```starlark
mix_release(
    name = "release",
    application = ":app",
    configs = glob(["config/**/*.exs"]),
    data = glob(["rel/**/*"]),
    release_name = "my_app",
)
```

Build the release with an execution platform matching its deployment ABI,
especially when OTP or dependencies contain native code. Static assets should
already be declared under `priv/static` (or supplied as `data`) by their owning
Bazel rules.

For a FIPS-required toolchain, `mix_release` merges
`{crypto, [{fips_mode, true}]}` into every generated `sys.config`. A fully
static crypto SDK needs no other release payload.

A normalized provider-backed SDK is copied under
`.rules_elixir_mix/crypto_sdk`. The rule prepends a checked-in Elixir activation
hook to the generated `runtime.exs`; runtime configuration executes immediately
before applications start. The hook clears ambient OpenSSL variables, runs the
packaged SDK activation executable by a release-relative path, applies only the
normalized packaged paths, and aborts release boot on failure. It never invokes
a host executable, a shell, or a backend-specific rule.

Provider-backed releases must declare `config/runtime.exs` through the
application's `config` attribute. Their launcher/deployment must set
`RULES_ELIXIR_MIX_CRYPTO_STATE` to a writable, deployment-local directory;
the release fails closed when it is absent. OpenSSL's generated
`fipsmodule.cnf` is therefore created on the deployment host from packaged
inputs instead of copied from the build host.
