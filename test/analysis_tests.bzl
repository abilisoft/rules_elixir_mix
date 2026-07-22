"""Regression checks and test-only helpers for the public rules."""

load("//bzlmod:mix_lock_test_support.bzl", "parse_mix_lock")
load("//bzlmod:versions.bzl", "DEFAULT_ELIXIR_VERSION", "DEFAULT_OTP_VERSION", "known_source_versions", "resolve_source_release")
load("//private:beam_info.bzl", "ErlangAppInfo", "OtpInfo", "crypto_runtime_files", "erl_env_flags", "otp_runtime_env", "otp_runtime_erl_args", "test_erl_launcher")
load("//private:runtime_archive_info.bzl", "BeamRuntimeSourceInfo")
load("//private:rustler_precompiled.bzl", "RustlerPrecompiledArchiveInfo")

_FINGERPRINT_EQUALITY_EVAL = "[L,R]=init:get_plain_arguments(),{ok,LB}=file:read_file(L),{ok,RB}=file:read_file(R),case LB=:=RB of true->halt(0);false->io:format(standard_error,\"compiled artifact fingerprints differ: ~ts ~ts~n\",[L,R]),halt(1) end."

def _fingerprint_equality_test_impl(ctx):
    toolchain = ctx.toolchains["//:otp_toolchain_type"]
    left = ctx.attr.left[ErlangAppInfo].compile_fingerprint
    right = ctx.attr.right[ErlangAppInfo].compile_fingerprint
    args = otp_runtime_erl_args(toolchain.otpinfo, runfiles = True) + [
        "-noshell",
        "-eval",
        _FINGERPRINT_EQUALITY_EVAL,
        "-extra",
        left.short_path,
        right.short_path,
    ]
    environment = otp_runtime_env(toolchain.otpinfo, runfiles = True)
    environment.update({
        "ERL_AFLAGS": erl_env_flags(args),
        "HOME": ".",
        "LANG": "C",
        "LC_ALL": "C",
        "SOURCE_DATE_EPOCH": "946684800",
        "TZ": "UTC",
    })
    return [
        DefaultInfo(
            executable = test_erl_launcher(ctx, toolchain.otpinfo),
            runfiles = ctx.runfiles(
                files = [left, right],
                transitive_files = depset(transitive = [
                    toolchain.runtime_files,
                    crypto_runtime_files(toolchain.otpinfo),
                ]),
            ),
        ),
        RunEnvironmentInfo(environment = environment),
    ]

fingerprint_equality_test = rule(
    implementation = _fingerprint_equality_test_impl,
    attrs = {
        "left": attr.label(mandatory = True, providers = [ErlangAppInfo]),
        "right": attr.label(mandatory = True, providers = [ErlangAppInfo]),
    },
    test = True,
    toolchains = ["//:otp_toolchain_type"],
)

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
    if runtime.otpinfo.target_arch not in ["aarch64", "x86_64"]:
        fail("unexpected OTP target architecture {}".format(runtime.otpinfo.target_arch))
    if runtime.otpinfo.target_os != "linux" or runtime.otpinfo.target_abi not in ["gnu", "musl"]:
        fail("unexpected OTP target OS/ABI {}/{}".format(runtime.otpinfo.target_os, runtime.otpinfo.target_abi))
    if not runtime.otpinfo.erts_bin.endswith("erts-17.0.3/bin"):
        fail("unexpected ERTS bin {}".format(runtime.otpinfo.erts_bin))
    if runtime.native_build_tools == None:
        fail("test toolchain must expose its declared native build closure")
    return []

toolchain_analysis_check = rule(
    implementation = _toolchain_analysis_check_impl,
    toolchains = ["//:toolchain_type"],
)

def _otp_runtime_closure_analysis_check_impl(ctx):
    otp = ctx.attr.otp[OtpInfo]
    paths = [file.path for file in otp.runtime_files.to_list()]
    if not any([path.endswith("/fake_execution_wrapper") for path in paths]):
        fail("provider-backed OTP dropped its execution-wrapper closure: {}".format(paths))
    if not any([path.endswith("/fake_crypto_sysroot") for path in paths]):
        fail("provider-backed OTP dropped its execution sysroot: {}".format(paths))
    return []

otp_runtime_closure_analysis_check = rule(
    implementation = _otp_runtime_closure_analysis_check_impl,
    attrs = {
        "otp": attr.label(mandatory = True, providers = [OtpInfo]),
    },
)

def _version_catalog_analysis_check_impl(_ctx):
    hexadecimal = "0123456789abcdef"
    zero_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
    if DEFAULT_OTP_VERSION not in known_source_versions("otp"):
        fail("default OTP version is absent from the known-version catalog")
    if DEFAULT_ELIXIR_VERSION not in known_source_versions("elixir"):
        fail("default Elixir version is absent from the known-version catalog")

    otp = resolve_source_release("otp", DEFAULT_OTP_VERSION)
    elixir = resolve_source_release("elixir", DEFAULT_ELIXIR_VERSION)
    for language, release in [("otp", otp), ("elixir", elixir)]:
        if not release.url.startswith("https://github.com/"):
            fail("{} source catalog URL must use HTTPS: {}".format(language, release.url))
        if len(release.sha256) != 64 or any([release.sha256[index] not in hexadecimal for index in range(len(release.sha256))]):
            fail("{} source catalog digest must be SHA-256".format(language))
        if not release.strip_prefix or not release.archive_type:
            fail("{} source catalog must declare extraction metadata".format(language))

    custom = resolve_source_release(
        "otp",
        "custom",
        url = "https://artifacts.example/otp.tar.zst",
        sha256 = zero_sha256,
        strip_prefix = "otp",
        archive_type = "tar.zst",
    )
    if custom.sha256 != zero_sha256 or custom.strip_prefix != "otp" or custom.archive_type != "tar.zst":
        fail("complete custom source override was not preserved")
    return []

version_catalog_analysis_check = rule(implementation = _version_catalog_analysis_check_impl)

def _rustler_precompiled_analysis_check_impl(ctx):
    info = ctx.attr.archive[RustlerPrecompiledArchiveInfo]
    if info.archive.basename != ctx.attr.expected_basename:
        fail("selected RustlerPrecompiled archive {}, expected {}".format(
            info.archive.basename,
            ctx.attr.expected_basename,
        ))
    if (info.target_arch, info.target_os, info.target_abi) != (
        ctx.attr.expected_target_arch,
        ctx.attr.expected_target_os,
        ctx.attr.expected_target_abi,
    ):
        fail("selected RustlerPrecompiled target {}/{}/{}, expected {}/{}/{}".format(
            info.target_arch,
            info.target_os,
            info.target_abi,
            ctx.attr.expected_target_arch,
            ctx.attr.expected_target_os,
            ctx.attr.expected_target_abi,
        ))
    return []

rustler_precompiled_analysis_check = rule(
    implementation = _rustler_precompiled_analysis_check_impl,
    attrs = {
        "archive": attr.label(mandatory = True, providers = [RustlerPrecompiledArchiveInfo]),
        "expected_basename": attr.string(mandatory = True),
        "expected_target_abi": attr.string(mandatory = True),
        "expected_target_arch": attr.string(mandatory = True),
        "expected_target_os": attr.string(mandatory = True),
    },
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

def _fake_runtime_source_impl(ctx):
    roots = ctx.attr.root[DefaultInfo].files.to_list()
    if len(roots) != 1 or not roots[0].is_directory:
        fail("fake_runtime_source root must contain exactly one directory artifact")
    return [
        DefaultInfo(files = depset(roots, transitive = [ctx.attr.otp[DefaultInfo].files])),
        ctx.attr.otp[OtpInfo],
        BeamRuntimeSourceInfo(
            kind = ctx.attr.kind,
            root = roots[0],
            root_relative_path = "",
            version = ctx.attr.version,
        ),
    ]

fake_runtime_source = rule(
    implementation = _fake_runtime_source_impl,
    attrs = {
        "kind": attr.string(mandatory = True, values = ["otp", "elixir"]),
        "otp": attr.label(mandatory = True, providers = [OtpInfo]),
        "root": attr.label(mandatory = True),
        "version": attr.string(mandatory = True),
    },
)

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
