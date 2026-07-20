"""Third-party integration fixture for rules_fips and rules_elixir_mix."""

load("@rules_elixir_mix//:defs.bzl", "otp_crypto_sdk")
load("@rules_fips//fips:defs.bzl", "openssl_fips_sdk")

def rules_fips_crypto_sdk(name):
    """Build and adapt the normalized rules_fips SDK without shared providers."""
    produced = openssl_fips_sdk(name = name + "_producer")
    otp_crypto_sdk(
        name = name,
        **produced.otp_crypto_sdk
    )
