"""Analysis-only BCR consumer smoke test."""

def _beam_toolchain_smoke_impl(ctx):
    runtime = ctx.toolchains["@rules_elixir_mix//:toolchain_type"]
    if runtime.otpinfo.version != "29.0.3":
        fail("unexpected OTP version: {}".format(runtime.otpinfo.version))
    if runtime.elixirinfo.version != "1.20.2":
        fail("unexpected Elixir version: {}".format(runtime.elixirinfo.version))
    output = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(
        output,
        "OTP {} + Elixir {}\n".format(runtime.otpinfo.version, runtime.elixirinfo.version),
    )
    return [DefaultInfo(files = depset([output]))]

beam_toolchain_smoke = rule(
    implementation = _beam_toolchain_smoke_impl,
    toolchains = ["@rules_elixir_mix//:toolchain_type"],
)
