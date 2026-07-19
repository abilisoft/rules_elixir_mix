"""Create deterministic, relocatable archives from source-built runtimes."""

load("//private:beam_info.bzl", "OtpInfo", "crypto_exec_inputs", "crypto_exec_tools", "fips_erl_args", "otp_runtime_env")
load("//private:runtime_archive_info.bzl", "BeamRuntimeArchiveInfo", "BeamRuntimeSourceInfo")

_DRIVER_EVAL = "A=init:get_plain_arguments(),[D|R]=A,{ok,runtime_archive_driver,B}=compile:file(D,[binary,report_errors,report_warnings]),{module,runtime_archive_driver}=code:load_binary(runtime_archive_driver,D,B),runtime_archive_driver:main(R),halt()."

def _validate_package_dir(value):
    if not value or value.startswith("/"):
        fail("beam_runtime_archive package_dir must be a non-empty relative path")
    if any([part in ["", ".", ".."] for part in value.split("/")]):
        fail("beam_runtime_archive package_dir must not contain empty, '.' or '..' components")

def _beam_runtime_archive_impl(ctx):
    source = ctx.attr.runtime[BeamRuntimeSourceInfo]
    otp = ctx.attr.runtime[OtpInfo]
    _validate_package_dir(ctx.attr.package_dir)
    if not otp.crypto_sdk:
        fail("beam_runtime_archive requires a source runtime built with a declared crypto_sdk so its SHA-256 can be generated hermetically")

    archive = ctx.outputs.archive
    sha256 = ctx.outputs.sha256
    metadata = ctx.outputs.metadata
    state = ctx.actions.declare_directory(ctx.label.name + "_state")
    root = source.root.path
    if source.root_relative_path:
        root += "/" + source.root_relative_path

    args = ctx.actions.args()
    args.add_all([
        "-noshell",
        "+fnu",
    ] + fips_erl_args(otp) + [
        "-eval",
        _DRIVER_EVAL,
        "-extra",
        ctx.file._driver,
        source.kind,
        source.version,
        root,
        ctx.attr.package_dir,
        archive,
        sha256,
        metadata,
    ])
    environment = otp_runtime_env(otp)
    environment.update({
        "HOME": state.path + "/home",
        "LANG": "C",
        "LC_ALL": "C",
        "RULES_ELIXIR_MIX_CRYPTO_STATE": state.path,
        "TZ": "UTC",
    })
    ctx.actions.run(
        executable = otp.erlexec,
        arguments = [args],
        inputs = depset(
            direct = [source.root, ctx.file._driver],
            transitive = [otp.runtime_files, crypto_exec_inputs(otp)],
        ),
        tools = crypto_exec_tools(otp),
        outputs = [archive, sha256, metadata, state],
        env = environment,
        execution_requirements = {"block-network": "1"},
        mnemonic = "BEAMARCHIVE",
        progress_message = "Archiving {} {} runtime".format(source.kind, source.version),
        use_default_shell_env = False,
    )

    return [
        DefaultInfo(files = depset([archive, sha256, metadata])),
        BeamRuntimeArchiveInfo(
            archive = archive,
            kind = source.kind,
            metadata = metadata,
            package_dir = ctx.attr.package_dir,
            sha256 = sha256,
            version = source.version,
        ),
    ]

beam_runtime_archive = rule(
    implementation = _beam_runtime_archive_impl,
    doc = "Package a crypto-enabled source-built OTP or Elixir runtime reproducibly.",
    attrs = {
        "runtime": attr.label(
            mandatory = True,
            providers = [OtpInfo, BeamRuntimeSourceInfo],
            cfg = "exec",
            doc = "Source-built otp or runtime target emitted by elixir_config.",
        ),
        "package_dir": attr.string(
            mandatory = True,
            doc = "Stable top-level directory stored in the archive.",
        ),
        "_driver": attr.label(
            default = Label("//private:runtime_archive_driver.erl"),
            allow_single_file = [".erl"],
        ),
    },
    outputs = {
        "archive": "%{name}.tar.gz",
        "metadata": "%{name}.metadata.json",
        "sha256": "%{name}.sha256",
    },
)
