"""Metadata for a Mix release artifact."""

ReleaseInfo = provider(
    doc = "A Mix release tree assembled as a Bazel artifact.",
    fields = {
        "name": "Mix release name.",
        "version": "Known release version, or None when owned by mix.exs.",
        "env": "MIX_ENV used for assembly.",
        "fips": "FIPS policy baked into the generated release configuration.",
        "app_name": "Primary OTP application name.",
        "crypto_activation": "Whether the release activates a provider-backed crypto SDK before applications start.",
    },
)
