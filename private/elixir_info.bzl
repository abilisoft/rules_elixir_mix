"""Provider shared by Elixir runtimes and the combined BEAM toolchain."""

load("//private:beam_info.bzl", "OtpInfo")

ElixirInfo = provider(
    doc = "An Elixir runtime paired with an Erlang/OTP runtime.",
    fields = {
        "version": "Elixir version.",
        "elixir_home": "Action-time path to the Elixir installation root.",
        "elixir_home_short_path": "Runfiles-relative Elixir installation root.",
        "runtime_files": "Depset containing the hermetic Elixir runtime.",
        "version_file": "Declared version file used for cache invalidation.",
    },
)

def otp_info_from_dependency(dep):
    """Return OtpInfo from a runtime target or toolchain target.

    Args:
      dep: Target providing OtpInfo directly or through ToolchainInfo.

    Returns:
      The dependency's OtpInfo provider.
    """
    if OtpInfo in dep:
        return dep[OtpInfo]
    if platform_common.ToolchainInfo in dep:
        toolchain = dep[platform_common.ToolchainInfo]
        if hasattr(toolchain, "otpinfo"):
            return toolchain.otpinfo
    fail("otp must provide OtpInfo or ToolchainInfo.otpinfo")
