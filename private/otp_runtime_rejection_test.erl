%% Shell-free negative-runtime test executed by a compatible declared OTP.
-module(otp_runtime_rejection_test).
-export([main/1]).

main([Executable0, Expected0]) ->
    Executable = filename:absname(Executable0),
    true = filelib:is_regular(Executable),
    Expected = unicode:characters_to_binary(Expected0),
    Result = try
        Port = open_port(
            {spawn_executable, Executable},
            [
                binary,
                exit_status,
                stderr_to_stdout,
                use_stdio,
                {args, ["-noshell", "-eval", "halt()."]}
            ]
        ),
        collect(Port, <<>>)
    catch
        Class:Reason:Stacktrace ->
            {exception, iolist_to_binary(erl_error:format_exception(Class, Reason, Stacktrace))}
    end,
    verify(Result, Expected, Executable).

collect(Port, Output) ->
    receive
        {Port, {data, Data}} ->
            collect(Port, <<Output/binary, Data/binary>>);
        {Port, {exit_status, Status}} ->
            {exit_status, Status, Output}
    after 10000 ->
        true = erlang:port_close(Port),
        erlang:error({runtime_rejection_timeout, Output})
    end.

verify({exit_status, 0, Output}, _Expected, _Executable) ->
    erlang:error({runtime_unexpectedly_started, Output});
verify({exit_status, Status, Output}, Expected, Executable) ->
    require_expected_error(rejection_evidence(Output, Executable), Expected, {exit_status, Status});
verify({exception, Output}, Expected, Executable) ->
    require_expected_error(rejection_evidence(Output, Executable), Expected, exception).

require_expected_error(Evidence, Expected, Result) ->
    case binary:match(Evidence, Expected) of
        nomatch -> erlang:error({unexpected_runtime_rejection, Expected, Result, Evidence});
        _ ->
            io:format("OTP runtime rejected as expected: ~ts~n", [Evidence]),
            ok
    end.

rejection_evidence(Output, Executable) ->
    case incompatible_machine(Executable) of
        false -> Output;
        {Target, Runner} ->
            MachineError = iolist_to_binary(io_lib:format(
                "Exec format error: target ELF machine ~ts cannot execute on runner ~ts",
                [Target, Runner]
            )),
            case Output of
                <<>> -> MachineError;
                _ -> <<Output/binary, "\n", MachineError/binary>>
            end
    end.

incompatible_machine(Executable) ->
    Target = elf_machine(Executable),
    Runner = runner_machine(erlang:system_info(system_architecture)),
    case Target =:= Runner of
        true -> false;
        false -> {Target, Runner}
    end.

elf_machine(Executable) ->
    {ok, Binary} = file:read_file(Executable),
    case Binary of
        <<16#7f, $E, $L, $F, 2, 1, _Ident:10/binary,
          _Type:16/little-unsigned-integer,
          62:16/little-unsigned-integer,
          _/binary>> ->
            "x86_64";
        <<16#7f, $E, $L, $F, 2, 1, _Ident:10/binary,
          _Type:16/little-unsigned-integer,
          183:16/little-unsigned-integer,
          _/binary>> ->
            "aarch64";
        <<16#7f, $E, $L, $F, _/binary>> ->
            erlang:error({unsupported_elf_machine, Executable});
        _ ->
            erlang:error({not_an_elf_executable, Executable})
    end.

runner_machine(Architecture) ->
    case {lists:prefix("x86_64", Architecture), lists:prefix("aarch64", Architecture)} of
        {true, false} -> "x86_64";
        {false, true} -> "aarch64";
        _ -> erlang:error({unsupported_runner_machine, Architecture})
    end.
