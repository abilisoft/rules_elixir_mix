"""Shell-free EUnit and Common Test rules."""

load("//private:beam_info.bzl", "ErlangAppInfo", "erl_env_flags", "fips_erl_args", "flat_runtime_deps", "otp_runtime_env", "runtime_path_erl_args", "test_erl_launcher")

_EUNIT_EVAL = "{ok,_}=application:ensure_all_started(eunit),A=[{application,list_to_atom(N)}||N<-init:get_plain_arguments()],case eunit:test(A,[verbose]) of ok->halt(0);_->halt(1) end."
_COMMON_TEST_EVAL = "{ok,_}=application:ensure_all_started(common_test),S=[list_to_atom(N)||N<-init:get_plain_arguments()],D=lists:usort([filename:dirname(code:which(M))||M<-S]),false=lists:member(\"non_existing\",D),L=filename:join(os:getenv(\"TEST_UNDECLARED_OUTPUTS_DIR\",os:getenv(\"TEST_TMPDIR\",\".\")),\"common_test\"),ok=filelib:ensure_dir(filename:join(L,\".keep\")),case ct:run_test([{dir,D},{suite,S},{auto_compile,false},{logdir,L},{verbosity,50}]) of {_,0,{_,_}}->halt(0);R->io:format(standard_error,\"Common Test failed: ~tp~n\",[R]),halt(1) end."

def _test_result(ctx, expression, names):
    toolchain = ctx.toolchains["//:otp_toolchain_type"]
    apps = flat_runtime_deps(ctx.attr.apps)
    lib_dirs = []
    for app in apps:
        for directory in app[ErlangAppInfo].lib_dirs_short_path:
            if directory not in lib_dirs:
                lib_dirs.append(directory)
    args = runtime_path_erl_args() + [
        "-noshell",
    ] + fips_erl_args(toolchain.otpinfo, runfiles = True) + [
        "-eval",
        expression,
        "-extra",
    ] + names
    environment = otp_runtime_env(toolchain.otpinfo, runfiles = True)
    environment.update({
        "ERL_AFLAGS": erl_env_flags(args),
        "ERL_LIBS": ":".join(lib_dirs),
        "HOME": ".",
        "LANG": "C",
        "LC_ALL": "C",
        "SOURCE_DATE_EPOCH": "946684800",
        "TZ": "UTC",
    })
    runfiles = ctx.runfiles(transitive_files = toolchain.runtime_files)
    for app in apps:
        runfiles = runfiles.merge(app[DefaultInfo].default_runfiles)
    return [
        DefaultInfo(executable = test_erl_launcher(ctx, toolchain.otpinfo), runfiles = runfiles),
        RunEnvironmentInfo(environment = environment),
    ]

def _eunit_test_impl(ctx):
    names = ctx.attr.app_names or [app[ErlangAppInfo].app_name for app in ctx.attr.apps]
    return _test_result(ctx, _EUNIT_EVAL, names)

erlang_eunit_test = rule(
    implementation = _eunit_test_impl,
    attrs = {
        "apps": attr.label_list(mandatory = True, providers = [ErlangAppInfo]),
        "app_names": attr.string_list(),
    },
    test = True,
    toolchains = ["//:otp_toolchain_type"],
)

def _common_test_impl(ctx):
    if not ctx.attr.suites:
        fail("erlang_common_test requires explicit suite module names")
    return _test_result(ctx, _COMMON_TEST_EVAL, ctx.attr.suites)

erlang_common_test = rule(
    implementation = _common_test_impl,
    attrs = {
        "apps": attr.label_list(mandatory = True, providers = [ErlangAppInfo]),
        "suites": attr.string_list(mandatory = True),
    },
    test = True,
    toolchains = ["//:otp_toolchain_type"],
)
