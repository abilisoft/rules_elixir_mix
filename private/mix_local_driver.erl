%% Writable local-workflow staging driven by a compact Bazel-generated manifest.
-module(mix_local_driver).
-export([stage/1, cleanup/1]).

-include_lib("kernel/include/file.hrl").

stage(ManifestPath) ->
    {ok, [Config]} = file:consult(ManifestPath),
    Workspace = required_environment("BUILD_WORKSPACE_DIRECTORY"),
    Project = filename:join(Workspace, maps:get(project_root, Config)),
    State = case os:getenv("RULES_ELIXIR_MIX_LOCAL_STATE") of
        false -> filename:join([Workspace, ".bazel", "elixir_mix", maps:get(state_name, Config)]);
        StatePath -> StatePath
    end,
    Build = filename:join(State, "_build"),
    MixEnvironment = required_environment("MIX_ENV"),
    ok = filelib:ensure_dir(filename:join(State, ".keep")),
    set_environment(State, Build, Project, MixEnvironment),
    ContextStatus = stage_context(Config, State, Build, MixEnvironment),
    DependencyStatuses = [
        stage_dependency(Dependency, State, Build, MixEnvironment)
        || Dependency <- maps:get(dependencies, Config)
    ],
    ApplicationStatus = stage_application(
        maps:get(application, Config),
        State,
        Build,
        MixEnvironment,
        Project
    ),
    ok = require_warm_cache([ContextStatus | DependencyStatuses] ++ [ApplicationStatus]),
    ok = file:set_cwd(Project),
    %% Local workflows deliberately leave the runfiles tree. Keep hostname
    %% lookup in the VM instead of using OTP's cwd-anchored inet_gethost helper.
    inet_db:set_lookup([dns, file]),
    ok.

cleanup(ManifestPath) ->
    {ok, [Config]} = file:consult(ManifestPath),
    Workspace = required_environment("BUILD_WORKSPACE_DIRECTORY"),
    Project = filename:join(Workspace, maps:get(project_root, Config)),
    State = case os:getenv("RULES_ELIXIR_MIX_LOCAL_STATE") of
        false -> filename:join([Workspace, ".bazel", "elixir_mix", maps:get(state_name, Config)]);
        StatePath -> StatePath
    end,
    App = maps:get(app_name, maps:get(application, Config)),
    Previous = filename:join([State, "generated_project_inputs", App]),
    remove_previous_project_entries(Previous, Previous, Project).

stage_context(Config, State, Build, MixEnvironment) ->
    Fingerprint = absolute(maps:get(context_fingerprint, Config)),
    Marker = filename:join([State, "context", MixEnvironment ++ ".fingerprint"]),
    case same_file(Fingerprint, Marker) of
        true -> warm;
        false ->
            ok = remove(filename:join(Build, MixEnvironment)),
            ok = remove(filename:join([State, "compiled_inputs", MixEnvironment])),
            ok = remove(filename:join([State, "local_app_inputs", MixEnvironment])),
            ok = copy_marker(Fingerprint, Marker),
            changed
    end.

set_environment(State, Build, Project, MixEnvironment) ->
    lists:foreach(
        fun({Key, Value}) -> true = os:putenv(Key, Value) end,
        [
            {"HOME", filename:join(State, "home")},
            {"HEX_HOME", filename:join(State, "hex")},
            {"MIX_ARCHIVES", filename:join([State, "mix", "archives"])},
            {"MIX_BUILD_PATH", filename:join([Build, MixEnvironment])},
            {"MIX_BUILD_ROOT", Build},
            {"MIX_DEPS_PATH", filename:join(State, "deps")},
            {"MIX_HOME", filename:join(State, "mix")},
            {"RULES_ELIXIR_MIX_PROJECT_DIR", Project},
            {"RULES_ELIXIR_MIX_STATE_DIR", filename:join(State, "action_state")}
        ]
    ),
    case os:getenv("RULES_ELIXIR_MIX_CHILD_ERL_AFLAGS") of
        false -> ok;
        ChildFlags -> true = os:putenv("ERL_AFLAGS", ChildFlags), ok
    end.

stage_dependency(Dependency, State, Build, MixEnvironment) ->
    App = maps:get(app_name, Dependency),
    CompiledMarker = filename:join([State, "compiled_inputs", MixEnvironment, App ++ ".fingerprint"]),
    CompileFingerprint = absolute(maps:get(compile_fingerprint, Dependency)),
    Destination = filename:join([Build, MixEnvironment, "lib", App]),
    CompiledStatus = case same_file(CompileFingerprint, CompiledMarker) andalso filelib:is_dir(Destination) of
        true -> warm;
        false ->
            ok = remove(Destination),
            ok = copy_entry(absolute(maps:get(compiled_source, Dependency)), Destination),
            ok = copy_marker(CompileFingerprint, CompiledMarker),
            changed
    end,
    ProjectStatus = stage_dependency_project(Dependency, State, App),
    combine_status(CompiledStatus, ProjectStatus).

stage_dependency_project(#{project_fingerprint := none}, _State, _App) ->
    warm;
stage_dependency_project(Dependency, State, App) ->
    Fingerprint = absolute(maps:get(project_fingerprint, Dependency)),
    Marker = filename:join([State, "project_inputs", App ++ ".fingerprint"]),
    case same_file(Fingerprint, Marker) of
        true -> warm;
        false ->
            Destination = filename:join([State, "deps", App]),
            ok = remove(Destination),
            ok = filelib:ensure_dir(filename:join(Destination, ".keep")),
            lists:foreach(
                fun({Source, Relative}) ->
                    ok = copy_entry(absolute(Source), filename:join(Destination, Relative))
                end,
                maps:get(project_entries, Dependency)
            ),
            ok = copy_marker(Fingerprint, Marker),
            changed
    end.

stage_application(Application, State, Build, MixEnvironment, Project) ->
    App = maps:get(app_name, Application),
    CompileFingerprint = absolute(maps:get(compile_fingerprint, Application)),
    ProjectFingerprint = absolute(maps:get(project_fingerprint, Application)),
    CompileMarker = filename:join([State, "local_app_inputs", MixEnvironment, App ++ ".compiled.fingerprint"]),
    ProjectMarker = filename:join([State, "local_app_inputs", MixEnvironment, App ++ ".project.fingerprint"]),
    CompileCurrent = same_file(CompileFingerprint, CompileMarker) andalso
        filelib:is_dir(filename:join([Build, MixEnvironment, "lib", App])),
    ProjectFingerprintCurrent = same_file(ProjectFingerprint, ProjectMarker),
    ProjectCurrent = ProjectFingerprintCurrent andalso application_project_current(Application, State, Project),
    case CompileCurrent andalso ProjectFingerprintCurrent of
        true ->
            case ProjectCurrent of
                true -> ok;
                false -> ok = stage_application_project(Application, State, Project)
            end,
            warm;
        false ->
            ok = remove(filename:join([Build, MixEnvironment, "lib", App])),
            case ProjectCurrent of
                true -> ok;
                false -> ok = stage_application_project(Application, State, Project)
            end,
            ok = copy_marker(CompileFingerprint, CompileMarker),
            ok = copy_marker(ProjectFingerprint, ProjectMarker),
            changed
    end.

application_project_current(Application, State, Project) ->
    App = maps:get(app_name, Application),
    Previous = filename:join([State, "generated_project_inputs", App]),
    lists:all(
        fun({_Source, Relative}) ->
            same_file(filename:join(Previous, Relative), filename:join(Project, Relative))
        end,
        maps:get(project_entries, Application)
    ).

combine_status(warm, warm) -> warm;
combine_status(_First, _Second) -> changed.

require_warm_cache(Statuses) ->
    case os:getenv("RULES_ELIXIR_MIX_REQUIRE_WARM_CACHE") of
        "true" ->
            case lists:member(changed, Statuses) of
                true -> erlang:error({local_cache_was_not_warm, Statuses});
                false -> ok
            end;
        _ -> ok
    end.

stage_application_project(Application, State, Project) ->
    App = maps:get(app_name, Application),
    Previous = filename:join([State, "generated_project_inputs", App]),
    ok = remove_previous_project_entries(Previous, Previous, Project),
    ok = remove(Previous),
    lists:foreach(
        fun({Source0, Relative}) ->
            Source = absolute(Source0),
            Destination = filename:join(Project, Relative),
            case file:read_link_info(Destination) of
                {error, enoent} -> ok;
                {ok, _} -> erlang:error({generated_project_destination_exists, Destination});
                Error -> erlang:error({generated_project_destination_inspection_failed, Destination, Error})
            end,
            ok = copy_entry(Source, Destination),
            ok = copy_entry(Source, filename:join(Previous, Relative))
        end,
        maps:get(project_entries, Application)
    ),
    ok.

remove_previous_project_entries(Root, Current, Project) ->
    case file:read_link_info(Current) of
        {ok, #file_info{type = directory}} ->
            {ok, Children} = file:list_dir(Current),
            lists:foreach(
                fun(Child) ->
                    ok = remove_previous_project_entries(Root, filename:join(Current, Child), Project)
                end,
                lists:sort(Children)
            ),
            ok;
        {ok, #file_info{type = regular}} ->
            Relative = filename:join(lists:nthtail(length(filename:split(Root)), filename:split(Current))),
            Destination = filename:join(Project, Relative),
            case file:read_link_info(Destination) of
                {error, enoent} -> ok;
                {ok, #file_info{type = regular}} ->
                    case same_file(Current, Destination) of
                        true -> file:delete(Destination);
                        false -> erlang:error({generated_project_destination_modified, Destination})
                    end;
                {ok, _Info} -> erlang:error({generated_project_destination_modified, Destination});
                Error -> Error
            end;
        {error, enoent} -> ok;
        {ok, _Info} -> erlang:error({unsupported_generated_project_entry, Current});
        Error -> Error
    end.

copy_entry(Source, Destination) ->
    case filelib:is_dir(Source) of
        true ->
            ok = filelib:ensure_dir(filename:join(Destination, ".keep")),
            {ok, Children} = file:list_dir(Source),
            lists:foreach(
                fun(Child) ->
                    ok = copy_entry(filename:join(Source, Child), filename:join(Destination, Child))
                end,
                lists:sort(Children)
            );
        false ->
            ok = filelib:ensure_dir(Destination),
            {ok, _} = file:copy(Source, Destination),
            {ok, #file_info{atime = AccessTime, mtime = ModificationTime, mode = Mode}} =
                file:read_file_info(Source),
            ok = file:change_time(Destination, AccessTime, ModificationTime),
            file:change_mode(Destination, Mode)
    end.

copy_marker(Source, Destination) ->
    ok = filelib:ensure_dir(Destination),
    {ok, _} = file:copy(Source, Destination),
    ok.

same_file(First, Second) ->
    case {file:read_file(First), file:read_file(Second)} of
        {{ok, Content}, {ok, Content}} -> true;
        _ -> false
    end.

remove(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} -> file:del_dir_r(Path);
        {ok, _} -> file:delete(Path);
        {error, enoent} -> ok;
        Error -> Error
    end.

absolute(Path) ->
    filename:absname(Path).

required_environment(Key) ->
    case os:getenv(Key) of
        false -> erlang:error({missing_environment, Key});
        Value -> Value
    end.
