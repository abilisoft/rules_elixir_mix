"""Normalized, backend-neutral static crypto SDK contract for OTP."""

load("//private:beam_info.bzl", "OtpCryptoSdkInfo")

_SYSROOT = "{sysroot}"
_ACTIVATION_ROOT = "{activation_root}"
_PROGRAM = "{program}"

def crypto_sdk_info(target):
    """Return the normalized SDK provider or adapt the legacy directory form.

    Args:
      target: Optional target passed through a crypto_sdk attribute.

    Returns:
      OtpCryptoSdkInfo-compatible provider/struct, or None.
    """
    if not target:
        return None
    if OtpCryptoSdkInfo in target:
        info = target[OtpCryptoSdkInfo]
        _validate_normalized_info(info)
        return info
    files = target[DefaultInfo].files.to_list()
    if len(files) != 1 or not files[0].is_directory:
        fail("crypto_sdk must provide OtpCryptoSdkInfo or exactly one directory artifact")
    return struct(
        activation_args = [],
        activation_exec_tool = None,
        activation_tool = None,
        activation_tool_release_path = "",
        backend_metadata = {},
        exec_files = depset(),
        exec_support_files = depset(),
        execution_exec_wrapper = None,
        execution_wrapper = None,
        execution_wrapper_environment = {},
        execution_wrapper_release_path = "",
        files = depset(files),
        fully_static = True,
        linkopts = [],
        prepared_state = None,
        runtime_entries = [],
        runtime_environment = {},
        runtime_files = depset(),
        sysroot = files[0],
    )

def _validate_relative_path(value, attribute):
    parts = value.split("/")
    if not value or value.startswith("/") or "\\" in value or ":" in value or any([part in ["", ".", ".."] for part in parts]):
        fail("{} must be a normalized non-empty SDK-relative path: '{}'".format(attribute, value))

def _validate_template(value, attribute, allow_program = False):
    remainder = value.replace(_SYSROOT, "").replace(_ACTIVATION_ROOT, "")
    if allow_program:
        remainder = remainder.replace(_PROGRAM, "")
    if "{" in remainder or "}" in remainder:
        fail("{} contains an unknown placeholder: '{}'".format(attribute, value))
    normalized = value.replace(_SYSROOT, "SDKROOT").replace(_ACTIVATION_ROOT, "ACTIVATIONROOT")
    if allow_program:
        normalized = normalized.replace(_PROGRAM, "PROGRAM")
    if normalized.startswith("/") or "=/" in normalized or ":/" in normalized or "\\" in normalized:
        fail("{} must not contain a host-absolute path: '{}'".format(attribute, value))
    if any([part in [".", ".."] for part in normalized.split("/")]):
        fail("{} must not escape its declared root: '{}'".format(attribute, value))

def _validate_linkopts(linkopts):
    for option in linkopts:
        lowered = option.lower()
        if "/" in option or ".." in option or "-l" in option and "-L" in option or "rpath" in lowered:
            fail("crypto SDK linkopts must not contain host paths or rpaths: '{}'".format(option))
        if "crypto" in lowered or "ssl" in lowered:
            fail("crypto SDK linkopts must not request a dynamic crypto fallback: '{}'".format(option))
        if option in ["-l", "-L", "-Xlinker", "--library-path"] or option.startswith("-L") or "-Wl,-L" in option:
            fail("crypto SDK linkopts must not add undeclared library search paths or split linker arguments: '{}'".format(option))

def _validate_runtime_environment(environment):
    reserved = [
        "BINDIR",
        "EMU",
        "ERL_LIBS",
        "ERL_ROOTDIR",
        "HOME",
        "LANG",
        "LC_ALL",
        "LD_LIBRARY_PATH",
        "LD_PRELOAD",
        "PATH",
        "PROGNAME",
        "ROOTDIR",
        "SHELL",
        "TEMP",
        "TMP",
        "TMPDIR",
    ]
    reserved_prefixes = ["DYLD_", "ERL_", "HEX_", "MIX_", "REBAR_", "RULES_ELIXIR_MIX_"]
    for key in environment:
        if not key:
            fail("runtime_environment keys must not be empty")
        if key in reserved or any([key.startswith(prefix) for prefix in reserved_prefixes]):
            fail("crypto SDK runtime_environment may not override rules/runtime variable '{}'".format(key))

def _validate_normalized_info(info):
    if not info.sysroot.is_directory:
        fail("OtpCryptoSdkInfo.sysroot must be a directory artifact")
    _validate_linkopts(info.linkopts)
    if info.fully_static:
        if info.runtime_files.to_list() or info.runtime_entries or info.runtime_environment or info.activation_exec_tool or info.activation_tool or info.activation_args or info.activation_tool_release_path or info.execution_exec_wrapper or info.execution_wrapper or info.execution_wrapper_environment or info.execution_wrapper_release_path or info.exec_support_files.to_list() or info.prepared_state:
            fail("fully_static OtpCryptoSdkInfo must not declare runtime files, environment, activation, or an execution wrapper")
        return
    if not info.runtime_files.to_list() or not info.runtime_entries:
        fail("non-fully-static OtpCryptoSdkInfo requires an explicit runtime payload")
    if not info.activation_exec_tool or not info.activation_tool or not info.activation_tool_release_path:
        fail("non-fully-static OtpCryptoSdkInfo requires execution and target activation tools")
    if not info.prepared_state or not info.prepared_state.is_directory:
        fail("non-fully-static OtpCryptoSdkInfo requires a prepared state directory")
    wrappers = [info.execution_exec_wrapper, info.execution_wrapper, info.execution_wrapper_environment, info.execution_wrapper_release_path]
    if any(wrappers) and not all(wrappers):
        fail("OtpCryptoSdkInfo execution wrapper requires exec/target tools, environment, and a release path")
    _validate_relative_path(info.activation_tool_release_path, "activation_tool_release_path")
    if not any([_ACTIVATION_ROOT in arg for arg in info.activation_args]):
        fail("OtpCryptoSdkInfo.activation_args must place generated state below {activation_root}")
    for value in info.activation_args:
        _validate_template(value, "activation_args")
    _validate_runtime_environment(info.runtime_environment)
    for key, value in info.runtime_environment.items():
        _validate_template(value, "runtime_environment[{}]".format(key))
        if not value.startswith(_SYSROOT) and not value.startswith(_ACTIVATION_ROOT):
            fail("runtime_environment[{}] must be rooted at {{sysroot}} or {{activation_root}}".format(key))
    _validate_runtime_environment(info.execution_wrapper_environment)
    for key, value in info.execution_wrapper_environment.items():
        _validate_template(value, "execution_wrapper_environment[{}]".format(key), allow_program = True)
        if not value.startswith(_SYSROOT) and value != _PROGRAM:
            fail("execution_wrapper_environment[{}] must be rooted at {{sysroot}} or equal {{program}}".format(key))
    if info.execution_wrapper and not any([_PROGRAM in value for value in info.execution_wrapper_environment.values()]):
        fail("execution_wrapper_environment must pass {program} to the opaque wrapper")
    destinations = [entry.destination for entry in info.runtime_entries]
    if len(destinations) != len({destination: True for destination in destinations}):
        fail("OtpCryptoSdkInfo runtime destinations must be unique")
    if len(destinations) > 1 and "." in destinations:
        fail("runtime destination '.' must be the SDK's only runtime entry")
    for destination in destinations:
        if destination != ".":
            _validate_relative_path(destination, "runtime destination")
    runtime_paths = {file.path: True for file in info.runtime_files.to_list()}
    entry_paths = {entry.file.path: True for entry in info.runtime_entries}
    all_paths = {file.path: True for file in info.files.to_list()}
    if runtime_paths != entry_paths:
        fail("OtpCryptoSdkInfo runtime_files and runtime_entries must describe the same files")
    for path in runtime_paths:
        if path not in all_paths:
            fail("OtpCryptoSdkInfo runtime file '{}' is absent from files".format(path))
    undeclared_deployment_paths = sorted([
        path
        for path in all_paths
        if path != info.sysroot.path and path not in runtime_paths
    ])
    if undeclared_deployment_paths:
        fail("OtpCryptoSdkInfo deployment files must have explicit runtime_entries; missing mappings for {}".format(undeclared_deployment_paths))
    activation_matches = [
        entry
        for entry in info.runtime_entries
        if entry.file.path == info.activation_tool.executable.path and entry.destination == info.activation_tool_release_path
    ]
    if len(activation_matches) != 1:
        fail("activation_tool executable must be an exact runtime entry at activation_tool_release_path")
    if info.execution_wrapper:
        _validate_relative_path(info.execution_wrapper_release_path, "execution_wrapper_release_path")
        wrapper_matches = [
            entry
            for entry in info.runtime_entries
            if entry.file.path == info.execution_wrapper.executable.path and entry.destination == info.execution_wrapper_release_path
        ]
        if len(wrapper_matches) != 1:
            fail("execution_wrapper executable must be an exact runtime entry at execution_wrapper_release_path")

def _runtime_destination(sysroot, file, explicit):
    if explicit:
        _validate_relative_path(explicit, "runtime_destinations")
        return explicit
    if file == sysroot:
        return "."
    prefix = sysroot.short_path.rstrip("/") + "/"
    if file.short_path.startswith(prefix):
        return file.short_path[len(prefix):]
    fail("runtime file {} is outside sysroot {}; give it an explicit runtime_destinations entry".format(file, sysroot))

def _otp_crypto_sdk_impl(ctx):
    sysroots = ctx.attr.sysroot[DefaultInfo].files.to_list()
    if len(sysroots) != 1 or not sysroots[0].is_directory:
        fail("otp_crypto_sdk sysroot must provide exactly one directory artifact")
    sysroot = sysroots[0]
    runtime_files = ctx.files.runtime_files
    destinations = ctx.attr.runtime_destinations
    if destinations and len(destinations) != len(runtime_files):
        fail("runtime_destinations must be empty or have one entry per runtime_files artifact")

    activation_exec_tool = ctx.attr.activation_exec_tool[DefaultInfo].files_to_run if ctx.attr.activation_exec_tool else None
    activation_tool = ctx.attr.activation_tool[DefaultInfo].files_to_run if ctx.attr.activation_tool else None
    execution_exec_wrapper = ctx.attr.execution_exec_wrapper[DefaultInfo].files_to_run if ctx.attr.execution_exec_wrapper else None
    execution_wrapper = ctx.attr.execution_wrapper[DefaultInfo].files_to_run if ctx.attr.execution_wrapper else None
    exec_support_files = depset(ctx.files.exec_support_files)
    if ctx.attr.fully_static:
        if runtime_files or ctx.attr.runtime_environment or activation_exec_tool or activation_tool or ctx.attr.activation_args or ctx.attr.activation_tool_release_path or execution_exec_wrapper or execution_wrapper or ctx.attr.execution_wrapper_environment or ctx.attr.execution_wrapper_release_path:
            fail("fully_static SDKs must not declare runtime files, environment, activation, or an execution wrapper")
    else:
        if not runtime_files:
            fail("a non-fully-static SDK requires an explicit runtime payload")
        if not activation_exec_tool or not activation_tool:
            fail("a non-fully-static SDK requires activation_exec_tool and activation_tool")
        if not ctx.attr.activation_tool_release_path:
            fail("a non-fully-static SDK requires activation_tool_release_path")

    if activation_tool:
        _validate_relative_path(ctx.attr.activation_tool_release_path, "activation_tool_release_path")
        if not any([_ACTIVATION_ROOT in arg for arg in ctx.attr.activation_args]):
            fail("activation_args must place generated state below {activation_root}")
    wrappers = [execution_exec_wrapper, execution_wrapper, ctx.attr.execution_wrapper_environment, ctx.attr.execution_wrapper_release_path]
    if any(wrappers) and not all(wrappers):
        fail("execution wrapper requires execution_exec_wrapper, execution_wrapper, execution_wrapper_environment, and execution_wrapper_release_path")
    if execution_wrapper:
        _validate_relative_path(ctx.attr.execution_wrapper_release_path, "execution_wrapper_release_path")
    _validate_runtime_environment(ctx.attr.runtime_environment)
    for key, value in ctx.attr.runtime_environment.items():
        _validate_template(value, "runtime_environment[{}]".format(key))
        if not value.startswith(_SYSROOT) and not value.startswith(_ACTIVATION_ROOT):
            fail("runtime_environment[{}] must be rooted at {{sysroot}} or {{activation_root}}".format(key))
    for value in ctx.attr.activation_args:
        _validate_template(value, "activation_args")
    _validate_runtime_environment(ctx.attr.execution_wrapper_environment)
    for key, value in ctx.attr.execution_wrapper_environment.items():
        _validate_template(value, "execution_wrapper_environment[{}]".format(key), allow_program = True)
        if not value.startswith(_SYSROOT) and value != _PROGRAM:
            fail("execution_wrapper_environment[{}] must be rooted at {{sysroot}} or equal {{program}}".format(key))
    if execution_wrapper and not any([_PROGRAM in value for value in ctx.attr.execution_wrapper_environment.values()]):
        fail("execution_wrapper_environment must pass {program} to the opaque wrapper")
    _validate_linkopts(ctx.attr.linkopts)

    entries = [
        struct(
            destination = _runtime_destination(
                sysroot,
                file,
                destinations[index] if destinations else "",
            ),
            file = file,
        )
        for index, file in enumerate(runtime_files)
    ]
    if len(entries) > 1 and any([entry.destination == "." for entry in entries]):
        fail("runtime destination '.' must be the SDK's only runtime entry")
    target_activation_files = depset(
        transitive = [
            ctx.attr.activation_tool[DefaultInfo].files,
            ctx.attr.activation_tool[DefaultInfo].default_runfiles.files,
        ],
    ) if activation_tool else depset()
    exec_activation_files = depset(
        transitive = [
            ctx.attr.activation_exec_tool[DefaultInfo].files,
            ctx.attr.activation_exec_tool[DefaultInfo].default_runfiles.files,
        ],
    ) if activation_exec_tool else depset()
    target_wrapper_files = depset(
        transitive = [
            ctx.attr.execution_wrapper[DefaultInfo].files,
            ctx.attr.execution_wrapper[DefaultInfo].default_runfiles.files,
        ],
    ) if execution_wrapper else depset()
    exec_wrapper_files = depset(
        transitive = [
            ctx.attr.execution_exec_wrapper[DefaultInfo].files,
            ctx.attr.execution_exec_wrapper[DefaultInfo].default_runfiles.files,
        ],
    ) if execution_exec_wrapper else depset()
    exec_files = depset(transitive = [exec_activation_files, exec_wrapper_files, exec_support_files])
    prepared_state = None
    if activation_exec_tool:
        prepared_state = ctx.actions.declare_directory(ctx.label.name + "_prepared_state")
        ctx.actions.run(
            executable = activation_exec_tool,
            arguments = [
                value.replace("{sysroot}", sysroot.path).replace("{activation_root}", prepared_state.path)
                for value in ctx.attr.activation_args
            ],
            inputs = depset(
                direct = [sysroot],
                transitive = [exec_activation_files, exec_support_files],
            ),
            tools = [activation_exec_tool],
            outputs = [prepared_state],
            env = {
                "HOME": prepared_state.path,
                "LANG": "C",
                "LC_ALL": "C",
                "TZ": "UTC",
            },
            execution_requirements = {"block-network": "1"},
            mnemonic = "CryptoActivation",
            progress_message = "Preparing declared crypto runtime state for {}".format(ctx.label),
            use_default_shell_env = False,
        )
    runtime_paths = {file.path: True for file in runtime_files}
    unmapped_activation_files = sorted([
        file.path
        for file in target_activation_files.to_list()
        if file.path not in runtime_paths
    ])
    if unmapped_activation_files:
        fail("activation_tool files and runfiles require explicit runtime_files/runtime_destinations mappings: {}".format(unmapped_activation_files))
    unmapped_wrapper_files = sorted([
        file.path
        for file in target_wrapper_files.to_list()
        if file.path not in runtime_paths
    ])
    if unmapped_wrapper_files:
        fail("execution_wrapper files and runfiles require explicit runtime_files/runtime_destinations mappings: {}".format(unmapped_wrapper_files))
    target_files = depset(
        direct = [sysroot] + runtime_files,
        transitive = [target_activation_files, target_wrapper_files],
    )
    info = OtpCryptoSdkInfo(
        activation_args = ctx.attr.activation_args,
        activation_exec_tool = activation_exec_tool,
        activation_tool = activation_tool,
        activation_tool_release_path = ctx.attr.activation_tool_release_path,
        backend_metadata = ctx.attr.backend_metadata,
        exec_files = exec_files,
        exec_support_files = exec_support_files,
        execution_exec_wrapper = execution_exec_wrapper,
        execution_wrapper = execution_wrapper,
        execution_wrapper_environment = ctx.attr.execution_wrapper_environment,
        execution_wrapper_release_path = ctx.attr.execution_wrapper_release_path,
        files = target_files,
        fully_static = ctx.attr.fully_static,
        linkopts = ctx.attr.linkopts,
        prepared_state = prepared_state,
        runtime_entries = entries,
        runtime_environment = ctx.attr.runtime_environment,
        runtime_files = depset(runtime_files),
        sysroot = sysroot,
    )
    _validate_normalized_info(info)
    return [
        DefaultInfo(files = target_files),
        info,
    ]

otp_crypto_sdk = rule(
    implementation = _otp_crypto_sdk_impl,
    attrs = {
        "activation_args": attr.string_list(),
        "activation_exec_tool": attr.label(executable = True, cfg = "exec", allow_files = True),
        "activation_tool": attr.label(executable = True, cfg = "target", allow_files = True),
        "activation_tool_release_path": attr.string(),
        "backend_metadata": attr.string_dict(),
        "execution_exec_wrapper": attr.label(executable = True, cfg = "exec", allow_files = True),
        "execution_wrapper": attr.label(executable = True, cfg = "target", allow_files = True),
        "execution_wrapper_environment": attr.string_dict(),
        "execution_wrapper_release_path": attr.string(),
        "exec_support_files": attr.label_list(allow_files = True, cfg = "exec"),
        "fully_static": attr.bool(default = True),
        "linkopts": attr.string_list(),
        "runtime_destinations": attr.string_list(),
        "runtime_environment": attr.string_dict(),
        "runtime_files": attr.label_list(allow_files = True),
        "sysroot": attr.label(mandatory = True, allow_files = True),
    },
)
