"""Public rules_elixir_mix API.

Mix is the application build system. Bazel supplies pinned sources,
dependencies, tools, execution isolation, caching, and the OTP+Elixir runtime.
"""

load("//private:beam_info.bzl", _ErlangAppInfo = "ErlangAppInfo", _OtpCryptoSdkInfo = "OtpCryptoSdkInfo", _OtpInfo = "OtpInfo")
load("//private:dialyzer.bzl", _DialyzerPltInfo = "DialyzerPltInfo", _dialyzer_plt = "dialyzer_plt", _elixir_dialyzer_test = "elixir_dialyzer_test")
load("//private:elixir_info.bzl", _ElixirInfo = "ElixirInfo")
load("//private:elixir_prebuilt_release.bzl", _elixir_prebuilt_release = "elixir_prebuilt_release")
load("//private:elixir_priv.bzl", _ElixirPrivInfo = "ElixirPrivInfo", _elixir_priv = "elixir_priv")
load("//private:elixir_protocols.bzl", _ElixirProtocolInfo = "ElixirProtocolInfo", _elixir_protocols = "elixir_protocols")
load("//private:elixir_source.bzl", _ElixirSourceInfo = "ElixirSourceInfo", _elixir_generated_source = "elixir_generated_source")
load("//private:elixir_source_release.bzl", _elixir_source_release = "elixir_source_release")
load("//private:elixir_toolchain.bzl", _elixir_toolchain = "elixir_toolchain")
load("//private:erlang_app.bzl", _erlang_app = "erlang_app")
load("//private:erlang_test.bzl", _erlang_common_test = "erlang_common_test", _erlang_eunit_test = "erlang_eunit_test")
load("//private:fips_runtime_test.bzl", _elixir_fips_runtime_test = "elixir_fips_runtime_test")
load("//private:mix_library.bzl", _mix_library = "mix_library")
load("//private:mix_local.bzl", _mix_local = "mix_local")
load("//private:mix_phx_assets.bzl", _mix_phx_assets = "mix_phx_assets")
load("//private:mix_release.bzl", _mix_release = "mix_release")
load("//private:mix_task.bzl", _mix_task_test = "mix_task_test")
load("//private:mix_test.bzl", _mix_test = "mix_test")
load("//private:otp_crypto_sdk.bzl", _otp_crypto_sdk = "otp_crypto_sdk")
load("//private:otp_prebuilt_release.bzl", _otp_prebuilt_release = "otp_prebuilt_release")
load("//private:otp_source_release.bzl", _otp_source_release = "otp_source_release")
load("//private:otp_toolchain.bzl", _otp_toolchain = "otp_toolchain")
load("//private:rebar_library.bzl", _rebar_library = "rebar_library")
load("//private:release_runtime_test.bzl", _elixir_release_test = "elixir_release_test")
load("//private:runtime_archive.bzl", _beam_runtime_archive = "beam_runtime_archive")
load("//private:runtime_archive_info.bzl", _BeamRuntimeArchiveInfo = "BeamRuntimeArchiveInfo")

ErlangAppInfo = _ErlangAppInfo
OtpInfo = _OtpInfo
OtpCryptoSdkInfo = _OtpCryptoSdkInfo
ElixirInfo = _ElixirInfo
ElixirPrivInfo = _ElixirPrivInfo
ElixirSourceInfo = _ElixirSourceInfo
ElixirProtocolInfo = _ElixirProtocolInfo
DialyzerPltInfo = _DialyzerPltInfo
BeamRuntimeArchiveInfo = _BeamRuntimeArchiveInfo
beam_runtime_archive = _beam_runtime_archive
otp_prebuilt_release = _otp_prebuilt_release
otp_crypto_sdk = _otp_crypto_sdk
otp_source_release = _otp_source_release
otp_toolchain = _otp_toolchain
elixir_prebuilt_release = _elixir_prebuilt_release
elixir_source_release = _elixir_source_release
elixir_generated_source = _elixir_generated_source
elixir_toolchain = _elixir_toolchain
erlang_app = _erlang_app
rebar_library = _rebar_library
elixir_priv = _elixir_priv
elixir_protocols = _elixir_protocols
mix_protocols = _elixir_protocols
dialyzer_plt = _dialyzer_plt

def _offline_tags(tags):
    return tags if "block-network" in tags else tags + ["block-network"]

def _erlang_common_test_impl(name, visibility, tags, **kwargs):
    _erlang_common_test(name = name, visibility = visibility, tags = _offline_tags(tags), **kwargs)

erlang_common_test = macro(
    doc = "Run Common Test with network access blocked unless a service rule explicitly opts in.",
    inherit_attrs = _erlang_common_test,
    attrs = {"tags": attr.string_list(configurable = False)},
    implementation = _erlang_common_test_impl,
)

def _erlang_eunit_test_impl(name, visibility, tags, **kwargs):
    _erlang_eunit_test(name = name, visibility = visibility, tags = _offline_tags(tags), **kwargs)

erlang_eunit_test = macro(
    doc = "Run EUnit with network access blocked.",
    inherit_attrs = _erlang_eunit_test,
    attrs = {"tags": attr.string_list(configurable = False)},
    implementation = _erlang_eunit_test_impl,
)

def _elixir_fips_runtime_test_impl(name, visibility, tags, **kwargs):
    _elixir_fips_runtime_test(name = name, visibility = visibility, tags = _offline_tags(tags), **kwargs)

elixir_fips_runtime_test = macro(
    doc = "Verify the generic static/FIPS OTP runtime contract with network access blocked.",
    inherit_attrs = _elixir_fips_runtime_test,
    attrs = {"tags": attr.string_list(configurable = False)},
    implementation = _elixir_fips_runtime_test_impl,
)

def _elixir_release_test_impl(name, visibility, tags, **kwargs):
    _elixir_release_test(name = name, visibility = visibility, tags = _offline_tags(tags), **kwargs)

elixir_release_test = macro(
    doc = "Boot a release through its packaged native VM with build-time runtime paths removed.",
    inherit_attrs = _elixir_release_test,
    attrs = {"tags": attr.string_list(configurable = False)},
    implementation = _elixir_release_test_impl,
)

def _elixir_dialyzer_test_impl(name, visibility, tags, **kwargs):
    _elixir_dialyzer_test(name = name, visibility = visibility, tags = _offline_tags(tags), **kwargs)

elixir_dialyzer_test = macro(
    doc = "Run native Dialyzer against a cached PLT with network access blocked.",
    inherit_attrs = _elixir_dialyzer_test,
    attrs = {"tags": attr.string_list(configurable = False)},
    implementation = _elixir_dialyzer_test_impl,
)

def _mix_library_impl(name, visibility, deps, hex, **kwargs):
    compile_deps = kwargs.pop("compile_deps")
    runtime_deps = kwargs.pop("runtime_deps")
    tags = kwargs.pop("tags")
    if hex:
        compile_deps = compile_deps + [hex]
    _mix_library(
        name = name,
        visibility = visibility,
        compile_deps = compile_deps,
        runtime_deps = runtime_deps + deps,
        tags = _offline_tags(tags),
        **kwargs
    )

mix_library = macro(
    doc = "Compile one Mix application from explicit, offline Bazel inputs.",
    inherit_attrs = _mix_library,
    attrs = {
        "compile_deps": attr.label_list(
            providers = [ErlangAppInfo],
            configurable = False,
            doc = "Applications available during compilation but not propagated at runtime.",
        ),
        "deps": attr.label_list(
            providers = [ErlangAppInfo],
            configurable = False,
            doc = "Compatibility alias appended to runtime_deps.",
        ),
        "hex": attr.label(
            providers = [ErlangAppInfo],
            configurable = False,
            doc = "Optional caller-resolved offline Hex application, normally @hex_pm//:lib.",
        ),
        "runtime_deps": attr.label_list(
            providers = [ErlangAppInfo],
            configurable = False,
            doc = "Applications propagated into the runtime closure.",
        ),
        "tags": attr.string_list(configurable = False),
    },
    implementation = _mix_library_impl,
)

elixir_library = mix_library
elixir_app = mix_library

def _elixir_nif_impl(name, visibility, shared_library, destination, **kwargs):
    if not destination.startswith("native/"):
        fail("elixir_nif destination must be below priv/native")
    _elixir_priv(
        name = name,
        destination = destination,
        src = shared_library,
        visibility = visibility,
        **kwargs
    )

elixir_nif = macro(
    doc = "Map a declared NIF shared library below an OTP application's priv/native tree.",
    attrs = {
        "destination": attr.string(mandatory = True, configurable = False),
        "shared_library": attr.label(mandatory = True, allow_single_file = True),
        "tags": attr.string_list(configurable = False),
    },
    implementation = _elixir_nif_impl,
)

rustler_nif = elixir_nif

def _mix_test_impl(name, visibility, tags, **kwargs):
    _mix_test(
        name = name,
        visibility = visibility,
        tags = _offline_tags(tags),
        **kwargs
    )

mix_test = macro(
    doc = "Run ExUnit through Mix against an explicitly test-compiled application.",
    inherit_attrs = _mix_test,
    attrs = {
        "srcs": attr.label_list(
            mandatory = True,
            allow_files = [".exs"],
            doc = "Explicit test and test-helper inputs; BUILD-file globs belong at the call site.",
        ),
        "tags": attr.string_list(configurable = False),
    },
    implementation = _mix_test_impl,
)

def _mix_task_test_impl(name, visibility, tags, **kwargs):
    _mix_task_test(
        name = name,
        visibility = visibility,
        tags = _offline_tags(tags),
        **kwargs
    )

mix_task_test = macro(
    doc = "Run an offline Mix analysis task as a Bazel test with explicit inputs.",
    inherit_attrs = _mix_task_test,
    attrs = {
        "srcs": attr.label_list(
            mandatory = True,
            allow_files = True,
            doc = "All files that the Mix task may read.",
        ),
        "tags": attr.string_list(configurable = False),
    },
    implementation = _mix_task_test_impl,
)

def _mix_format_test_impl(name, visibility, format_opts, **kwargs):
    mix_task_test(
        name = name,
        visibility = visibility,
        task = "format",
        task_args = ["--check-formatted"] + format_opts,
        **kwargs
    )

mix_format_test = macro(
    doc = "Check declared Elixir sources with mix format --check-formatted.",
    inherit_attrs = mix_task_test,
    attrs = {
        "format_opts": attr.string_list(configurable = False),
        "task": None,
        "task_args": None,
    },
    implementation = _mix_format_test_impl,
)

def _mix_credo_test_impl(name, visibility, strict, credo_opts, **kwargs):
    mix_task_test(
        name = name,
        visibility = visibility,
        task = "credo",
        task_args = (["--strict"] if strict else []) + credo_opts,
        **kwargs
    )

mix_credo_test = macro(
    doc = "Run Credo over explicitly declared inputs.",
    inherit_attrs = mix_task_test,
    attrs = {
        "credo_opts": attr.string_list(configurable = False),
        "strict": attr.bool(default = True, configurable = False),
        "task": None,
        "task_args": None,
    },
    implementation = _mix_credo_test_impl,
)

def _mix_dialyzer_test_impl(name, visibility, dialyzer_opts, **kwargs):
    mix_task_test(
        name = name,
        visibility = visibility,
        task = "dialyzer",
        task_args = dialyzer_opts,
        **kwargs
    )

mix_dialyzer_test = macro(
    doc = "Run Dialyxir through Mix; use elixir_dialyzer_test with dialyzer_plt for native cached PLTs.",
    inherit_attrs = mix_task_test,
    attrs = {
        "dialyzer_opts": attr.string_list(configurable = False),
        "task": None,
        "task_args": None,
    },
    implementation = _mix_dialyzer_test_impl,
)

def _mix_sobelow_test_impl(name, visibility, sobelow_opts, **kwargs):
    mix_task_test(
        name = name,
        visibility = visibility,
        task = "sobelow",
        task_args = sobelow_opts,
        **kwargs
    )

mix_sobelow_test = macro(
    doc = "Run Sobelow for Phoenix security analysis, failing at Low by default.",
    inherit_attrs = mix_task_test,
    attrs = {
        "sobelow_opts": attr.string_list(default = ["--exit", "Low"], configurable = False),
        "task": None,
        "task_args": None,
    },
    implementation = _mix_sobelow_test_impl,
)

def _mix_xref_test_impl(name, visibility, xref_args, **kwargs):
    if not xref_args:
        fail("mix_xref_test requires xref_args; xref modes vary across Elixir releases")
    mix_task_test(
        name = name,
        visibility = visibility,
        task = "xref",
        task_args = xref_args,
        **kwargs
    )

mix_xref_test = macro(
    doc = "Run an explicitly selected Mix xref mode.",
    inherit_attrs = mix_task_test,
    attrs = {
        "task": None,
        "task_args": None,
        "xref_args": attr.string_list(mandatory = True, configurable = False),
    },
    implementation = _mix_xref_test_impl,
)

def _mix_typecheck_test_impl(name, visibility, typecheck_opts, **kwargs):
    mix_task_test(
        name = name,
        visibility = visibility,
        minimum_elixir_version = "1.20.0",
        task = "compile",
        task_args = ["--force", "--no-deps-check", "--warnings-as-errors"] + typecheck_opts,
        **kwargs
    )

mix_typecheck_test = macro(
    doc = "Run Elixir 1.20's compiler-integrated gradual type analysis as a test.",
    inherit_attrs = mix_task_test,
    attrs = {
        "minimum_elixir_version": None,
        "task": None,
        "task_args": None,
        "typecheck_opts": attr.string_list(configurable = False),
    },
    implementation = _mix_typecheck_test_impl,
)

mix_ex_unit_test = mix_test

def _mix_ecto_test_impl(name, visibility, createdb, initdb, postgres, **kwargs):
    mix_test(
        name = name,
        visibility = visibility,
        createdb = createdb,
        initdb = initdb,
        postgres = postgres,
        **kwargs
    )

mix_ecto_test = macro(
    doc = "Run ExUnit with an isolated, declared Postgres cluster below TEST_TMPDIR.",
    inherit_attrs = mix_test,
    attrs = {
        "createdb": attr.label(mandatory = True, executable = True, cfg = "target"),
        "initdb": attr.label(mandatory = True, executable = True, cfg = "target"),
        "postgres": attr.label(mandatory = True, executable = True, cfg = "target"),
    },
    implementation = _mix_ecto_test_impl,
)

def _mix_coverage_test_impl(name, visibility, coverage_opts, mix_test_opts, **kwargs):
    mix_test(
        name = name,
        visibility = visibility,
        mix_test_opts = ["--cover"] + coverage_opts + mix_test_opts,
        recompile_for_coverage = True,
        **kwargs
    )

mix_coverage_test = macro(
    doc = "Run ExUnit with Mix's built-in coverage reporting.",
    inherit_attrs = mix_test,
    attrs = {
        "coverage_opts": attr.string_list(configurable = False),
        "mix_test_opts": attr.string_list(configurable = False),
        "recompile_for_coverage": None,
    },
    implementation = _mix_coverage_test_impl,
)

def _mix_lcov_test_impl(name, visibility, coverage_opts, coverage_output, **kwargs):
    mix_task_test(
        name = name,
        visibility = visibility,
        coverage_output = coverage_output,
        task = "coveralls.lcov",
        task_args = coverage_opts,
        **kwargs
    )

mix_lcov_test = macro(
    doc = "Run ExCoveralls and export its LCOV file through Bazel's coverage protocol.",
    inherit_attrs = mix_task_test,
    attrs = {
        "coverage_opts": attr.string_list(configurable = False),
        "coverage_output": attr.string(default = "cover/lcov.info", configurable = False),
        "task": None,
        "task_args": None,
    },
    implementation = _mix_lcov_test_impl,
)

def _mix_wallaby_test_impl(name, visibility, chrome, chromedriver, env, tools, **kwargs):
    wallaby_env = dict(env)
    wallaby_env.update({
        "WALLABY_CHROME": "$(location {})".format(chrome),
        "WALLABY_CHROMEDRIVER": "$(location {})".format(chromedriver),
        "WALLABY_DRIVER": "chrome",
    })
    wallaby_tools = []
    for tool in tools + [chrome, chromedriver]:
        if tool not in wallaby_tools:
            wallaby_tools.append(tool)
    mix_test(
        name = name,
        visibility = visibility,
        env = wallaby_env,
        tools = wallaby_tools,
        **kwargs
    )

mix_wallaby_test = macro(
    doc = "Run Wallaby/ExUnit with declared execution-platform Chrome binaries.",
    inherit_attrs = mix_test,
    attrs = {
        "chrome": attr.label(mandatory = True, executable = True, cfg = "target", configurable = False),
        "chromedriver": attr.label(mandatory = True, executable = True, cfg = "target", configurable = False),
        "env": attr.string_dict(configurable = False),
        "tools": attr.label_list(allow_files = True, configurable = False),
    },
    implementation = _mix_wallaby_test_impl,
)

def _mix_release_impl(name, visibility, tags, **kwargs):
    _mix_release(name = name, visibility = visibility, tags = _offline_tags(tags), **kwargs)

mix_release = macro(
    doc = "Assemble an immutable Mix release from precompiled Bazel applications.",
    inherit_attrs = _mix_release,
    attrs = {"tags": attr.string_list(configurable = False)},
    implementation = _mix_release_impl,
)

mix_phx_assets = _mix_phx_assets
mix_phx_digest = _mix_phx_assets

mix_local = _mix_local

def _mix_iex_impl(name, visibility, **kwargs):
    _mix_local(
        name = name,
        visibility = visibility,
        mode = "iex",
        **kwargs
    )

mix_iex = macro(
    doc = "Start IEx over the real workspace with the selected hermetic OTP/Elixir runtime.",
    inherit_attrs = _mix_local,
    attrs = {
        "function": None,
        "mode": None,
        "module": None,
        "task": None,
    },
    implementation = _mix_iex_impl,
)

def _elixir_ls_impl(name, visibility, **kwargs):
    _mix_local(
        name = name,
        visibility = visibility,
        function = "main",
        mode = "elixir",
        module = "Elixir.ElixirLS.LanguageServer.CLI",
        **kwargs
    )

elixir_ls = macro(
    doc = "Run the caller-provided ElixirLS application over the real workspace and Bazel dependency graph.",
    inherit_attrs = _mix_local,
    attrs = {
        "function": None,
        "mode": None,
        "module": None,
        "task": None,
    },
    implementation = _elixir_ls_impl,
)

def _mix_phx_server_impl(name, visibility, **kwargs):
    _mix_local(
        name = name,
        visibility = visibility,
        task = "phx.server",
        **kwargs
    )

mix_phx_server = macro(
    doc = "Run Phoenix's explicit writable, local-only development server workflow.",
    inherit_attrs = _mix_local,
    attrs = {"task": None},
    implementation = _mix_phx_server_impl,
)
