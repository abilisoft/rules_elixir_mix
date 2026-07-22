"""Source-only writable Mix formatter for explicit bazel run workflows."""

load("//private:beam_info.bzl", "ErlangAppInfo", "crypto_runtime_files", "erl_env_flags", "otp_runtime_env", "otp_runtime_erl_args", "path_join", "test_erl_launcher")

def _elixir_string(value):
    return '"{}"'.format(
        value.replace("\\", "\\\\")
            .replace('"', '\\"')
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .replace("\t", "\\t"),
    )

def _project_root(mix_config):
    short_path = mix_config.short_path
    if short_path.startswith("../"):
        fail("mix_format requires a Mix project in the main workspace")
    return short_path.rsplit("/", 1)[0] if "/" in short_path else ""

def _source_argument(file, project_root):
    prefix = project_root + "/" if project_root else ""
    if file.short_path.startswith("../") or (prefix and not file.short_path.startswith(prefix)):
        fail("mix_format source {} is outside project root '{}'".format(file, project_root or "."))
    relative = file.short_path[len(prefix):] if prefix else file.short_path
    if not relative or any([part in ["", ".", ".."] for part in relative.split("/")]):
        fail("mix_format source {} has unsafe project-relative path '{}'".format(file, relative))
    return relative

def _state_name(ctx):
    return str(ctx.label).replace("@", "").replace("//", "").replace(":", "/").strip("/")

def _runfiles_relative_path(ctx, file):
    if file.short_path.startswith("../"):
        return file.short_path.removeprefix("../")
    return path_join(ctx.workspace_name, file.short_path)

def _formatter_dependencies(ctx):
    terms = []
    files = []
    apps = {}
    for target in ctx.attr.deps:
        info = target[ErlangAppInfo]
        if info.app_name in apps:
            fail("mix_format dependencies {} and {} both provide '{}'".format(
                apps[info.app_name],
                target.label,
                info.app_name,
            ))
        apps[info.app_name] = target.label
        formatter = None
        for entry in info.project_entries:
            if entry.destination == ".formatter.exs":
                if formatter:
                    fail("mix_format dependency {} exposes multiple root .formatter.exs files".format(target.label))
                formatter = entry.source
        if formatter:
            files.append(formatter)
        terms.append("{{:{}, {}}}".format(
            info.app_name,
            _elixir_string(_runfiles_relative_path(ctx, formatter)) if formatter else "nil",
        ))
    return "[{}]".format(", ".join(terms)), files

def _mix_format_impl(ctx):
    if not ctx.files.srcs:
        fail("mix_format requires at least one declared source")
    for option in ctx.attr.format_opts:
        if not option.startswith("-"):
            fail("mix_format format_opts may contain options only; declare source paths through srcs")

    toolchain = ctx.toolchains["//:toolchain_type"]
    project_root = _project_root(ctx.file.mix_config)
    source_arguments = [_source_argument(file, project_root) for file in ctx.files.srcs]
    formatter_dependencies, formatter_files = _formatter_dependencies(ctx)
    expression = """
workspace = System.fetch_env!("BUILD_WORKSPACE_DIRECTORY")
runfiles = System.fetch_env!("RUNFILES_DIR")
project = Path.join(workspace, {project_root})
state = Path.join(
  System.tmp_dir!(),
  "rules_elixir_mix-{state_name}-format-#{{System.unique_integer([:positive, :monotonic])}}"
)
File.rm_rf!(state)
File.mkdir_p!(state)
System.put_env("HEX_HOME", Path.join(state, "hex"))
System.put_env("HOME", Path.join(state, "home"))
System.put_env("MIX_ARCHIVES", Path.join(state, "mix/archives"))
System.put_env("MIX_BUILD_PATH", Path.join(state, "_build/dev"))
System.put_env("MIX_BUILD_ROOT", Path.join(state, "_build"))
System.put_env("MIX_DEPS_PATH", Path.join(state, "deps"))
System.put_env("MIX_HOME", Path.join(state, "mix"))
format_deps = {formatter_dependencies}
File.rm_rf!(System.fetch_env!("MIX_DEPS_PATH"))
Enum.each(format_deps, fn {{app, formatter}} ->
  dependency = Path.join(System.fetch_env!("MIX_DEPS_PATH"), Atom.to_string(app))
  File.mkdir_p!(dependency)
  if formatter do
    File.cp!(Path.join(runfiles, formatter), Path.join(dependency, ".formatter.exs"))
  end
end)
File.cd!(project)
try do
  Mix.start()
  Code.compile_file({mix_config})
  Mix.ProjectStack.merge_config(
    deps: Enum.map(format_deps, fn {{app, _formatter}} ->
      {{app, [path: Path.join(System.fetch_env!("MIX_DEPS_PATH"), Atom.to_string(app)), override: true]}}
    end)
  )
  Mix.Task.run("loadconfig")
  Mix.Task.run("format", ["--no-compile" | System.argv()])
after
  File.rm_rf!(state)
end
""".format(
        formatter_dependencies = formatter_dependencies,
        mix_config = _elixir_string(ctx.file.mix_config.basename),
        project_root = _elixir_string(project_root),
        state_name = _elixir_string(_state_name(ctx)),
    )
    formatter_arguments = []
    if ctx.file.formatter_config:
        formatter_arguments = [
            "--dot-formatter",
            _source_argument(ctx.file.formatter_config, project_root),
        ]
    args = otp_runtime_erl_args(toolchain.otpinfo, runfiles = True) + [
        "-noshell",
        "+fnu",
        "-s",
        "elixir",
        "start_cli",
        "-extra",
        "-e",
        expression,
        "--",
    ] + ctx.attr.format_opts + formatter_arguments + source_arguments
    environment = otp_runtime_env(toolchain.otpinfo, runfiles = True)
    launcher = test_erl_launcher(ctx, toolchain.otpinfo)
    environment.update({
        "ERL_AFLAGS": erl_env_flags(args),
        "ERL_LIBS": path_join(toolchain.elixirinfo.elixir_home_short_path, "lib"),
        "HEX_OFFLINE": "true",
        "HOME": ".",
        "LANG": "C",
        "LC_ALL": "C",
        "MIX_ENV": "dev",
        "MIX_OS_CONCURRENCY_LOCK": "false",
        "RUNFILES_DIR": "..",
        "SOURCE_DATE_EPOCH": "946684800",
        "TZ": "UTC",
    })
    runfiles = ctx.runfiles(
        files = ctx.files.srcs + formatter_files + [ctx.file.mix_config] + ([ctx.file.formatter_config] if ctx.file.formatter_config else []),
        transitive_files = depset(transitive = [
            toolchain.runtime_files,
            crypto_runtime_files(toolchain.otpinfo),
        ]),
    )
    return [
        DefaultInfo(executable = launcher, runfiles = runfiles),
        RunEnvironmentInfo(environment = environment),
    ]

mix_format = rule(
    implementation = _mix_format_impl,
    attrs = {
        "format_opts": attr.string_list(),
        "formatter_config": attr.label(allow_single_file = [".exs"]),
        "mix_config": attr.label(mandatory = True, allow_single_file = [".exs"]),
        "deps": attr.label_list(
            providers = [ErlangAppInfo],
            doc = "Locked dependency source metadata available to .formatter.exs import_deps.",
        ),
        "srcs": attr.label_list(mandatory = True, allow_files = [".ex", ".exs"]),
    },
    doc = "Formats only declared workspace sources without depending on a compiled application.",
    executable = True,
    toolchains = ["//:toolchain_type"],
)
