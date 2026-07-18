"""Analysis-only regression checks that require no host BEAM runtime."""

load("//bzlmod:mix_lock_test_support.bzl", "parse_mix_lock")

def _mix_lock_analysis_check_impl(ctx):
    packages = parse_mix_lock(ctx.attr.content)
    if len(packages) != 2:
        fail("expected two parsed packages, got {}".format(len(packages)))
    first = packages[0]
    second = packages[1]
    if first.app_name != "compile_tool" or first.manager != "rebar3" or first.repository != "hexpm":
        fail("unexpected first lock package: {}".format(first))
    if second.app_name != "web_app" or second.manager != "mix" or second.repository != "hexpm":
        fail("unexpected second lock package: {}".format(second))
    if second.compile_deps != ["compile_tool"] or second.runtime_deps != []:
        fail("runtime:false dependency edge was not preserved: {}".format(second))
    return []

mix_lock_analysis_check = rule(
    implementation = _mix_lock_analysis_check_impl,
    attrs = {"content": attr.string(mandatory = True)},
)

def _toolchain_analysis_check_impl(ctx):
    runtime = ctx.toolchains["//:toolchain_type"]
    if runtime.otpinfo.version != "29.0.3":
        fail("unexpected OTP version {}".format(runtime.otpinfo.version))
    if runtime.elixirinfo.version != "1.20.2":
        fail("unexpected Elixir version {}".format(runtime.elixirinfo.version))
    if runtime.otpinfo.erlexec.basename != "erlexec":
        fail("toolchain must expose native erlexec, got {}".format(runtime.otpinfo.erlexec))
    if not runtime.otpinfo.erts_bin.endswith("erts-17.0.3/bin"):
        fail("unexpected ERTS bin {}".format(runtime.otpinfo.erts_bin))
    if runtime.native_build_tools == None:
        fail("test toolchain must expose its declared native build closure")
    return []

toolchain_analysis_check = rule(
    implementation = _toolchain_analysis_check_impl,
    toolchains = ["//:toolchain_type"],
)

def _fake_directory_impl(ctx):
    output = ctx.actions.declare_directory(ctx.label.name)
    ctx.actions.run(
        executable = ctx.executable._unreachable,
        outputs = [output],
        mnemonic = "UnreachableAnalysisFixture",
    )
    return [DefaultInfo(files = depset([output]))]

fake_directory = rule(
    implementation = _fake_directory_impl,
    attrs = {
        "_unreachable": attr.label(
            default = Label("//test:fake_activation"),
            executable = True,
            cfg = "exec",
        ),
    },
)

def _fake_executable_impl(ctx):
    output = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.write(output, "analysis fixture only\n", is_executable = True)
    return [DefaultInfo(executable = output, files = depset([output]))]

fake_executable = rule(implementation = _fake_executable_impl, executable = True)

def _generated_file_impl(ctx):
    output = ctx.actions.declare_file(ctx.attr.filename)
    ctx.actions.write(output, ctx.attr.content)
    return [DefaultInfo(files = depset([output]))]

generated_file = rule(
    implementation = _generated_file_impl,
    attrs = {
        "content": attr.string(mandatory = True),
        "filename": attr.string(mandatory = True),
    },
)
