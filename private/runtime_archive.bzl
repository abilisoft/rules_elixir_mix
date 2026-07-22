"""Create deterministic, relocatable archives from source-built runtimes."""

load("//private:beam_info.bzl", "OtpInfo", "execution_erlexec", "otp_runtime_env")
load("//private:runtime_archive_info.bzl", "BeamRuntimeArchiveInfo", "BeamRuntimeSourceInfo")

_DRIVER_EVAL = "A=init:get_plain_arguments(),[N,D|R]=A,{ok,artifact_normalizer,NB}=compile:file(N,[binary,report_errors,report_warnings]),{module,artifact_normalizer}=code:load_binary(artifact_normalizer,N,NB),{ok,runtime_archive_driver,B}=compile:file(D,[binary,report_errors,report_warnings]),{module,runtime_archive_driver}=code:load_binary(runtime_archive_driver,D,B),runtime_archive_driver:main(R),halt()."

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
    if otp.runtime_wrapped:
        native_contract = "wrapped"
    elif otp.fully_static:
        native_contract = "static"
    else:
        fail("beam_runtime_archive requires a verified wrapped or fully static OTP runtime")

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
        "-eval",
        _DRIVER_EVAL,
        "-extra",
        ctx.file._normalizer,
        ctx.file._driver,
        source.kind,
        source.version,
        native_contract,
        otp.crypto_sdk.sysroot,
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
        executable = execution_erlexec(otp),
        arguments = [args],
        inputs = depset(
            direct = [source.root, otp.crypto_sdk.sysroot, ctx.file._driver, ctx.file._normalizer],
            transitive = [otp.runtime_files],
        ),
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
        "_normalizer": attr.label(
            default = Label("//private:artifact_normalizer.erl"),
            allow_single_file = [".erl"],
        ),
    },
    outputs = {
        "archive": "%{name}.tar.gz",
        "metadata": "%{name}.metadata.json",
        "sha256": "%{name}.sha256",
    },
)
