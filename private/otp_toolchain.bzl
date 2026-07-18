"""Erlang/OTP-only toolchain definition."""

load("//private:beam_info.bzl", "OtpInfo")

def _otp_toolchain_impl(ctx):
    otp = ctx.attr.otp[OtpInfo]
    return [platform_common.ToolchainInfo(
        otpinfo = otp,
        runtime_files = otp.runtime_files,
    )]

otp_toolchain = rule(
    implementation = _otp_toolchain_impl,
    attrs = {
        "otp": attr.label(mandatory = True, providers = [OtpInfo]),
    },
)
