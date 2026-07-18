%% Runtime and static-linkage checks for an OTP toolchain built in FIPS mode.
-module(fips_runtime_test).
-export([main/1]).

main([OtpRoot0, Inspector0]) ->
    OtpRoot = filename:absname(OtpRoot0),
    Inspector = filename:absname(Inspector0),
    ok = application:load(crypto),
    ok = application:set_env(crypto, fips_mode, true),
    {ok, _} = application:ensure_all_started(crypto),
    enabled = crypto:info_fips(),
    #{link_type := static} = crypto:info(),
    approved_crypto_works(),
    approved_signatures_work(),
    prohibited_crypto_fails(),
    {ok, _} = application:ensure_all_started(ssl),
    tls_works(),
    no_loadable_crypto_nif(OtpRoot),
    no_dynamic_crypto_dependencies(OtpRoot, Inspector),
    io:format("OTP FIPS runtime verified: ~tp ~tp~n", [crypto:info(), crypto:info_lib()]),
    ok.

approved_crypto_works() ->
    <<_:32/binary>> = crypto:hash(sha256, <<"rules_elixir_mix">>),
    <<_:32/binary>> = crypto:mac(hmac, sha256, <<"key">>, <<"rules_elixir_mix">>),
    Key = <<0:256>>,
    Iv = <<0:96>>,
    Plaintext = <<"approved AES-GCM">>,
    {Ciphertext, Tag} = crypto:crypto_one_time_aead(
        aes_256_gcm,
        Key,
        Iv,
        Plaintext,
        <<>>,
        16,
        true
    ),
    Plaintext = crypto:crypto_one_time_aead(
        aes_256_gcm,
        Key,
        Iv,
        Ciphertext,
        <<>>,
        Tag,
        false
    ),
    ok.

approved_signatures_work() ->
    Message = <<"rules_elixir_mix FIPS signature test">>,
    {RsaPublic, RsaPrivate} = crypto:generate_key(rsa, {3072, 65537}),
    RsaSignature = crypto:sign(rsa, sha256, Message, RsaPrivate),
    true = crypto:verify(rsa, sha256, Message, RsaSignature, RsaPublic),
    {EcPublic, EcPrivate} = crypto:generate_key(ecdh, secp256r1),
    EcSignature = crypto:sign(ecdsa, sha256, Message, [EcPrivate, secp256r1]),
    true = crypto:verify(ecdsa, sha256, Message, EcSignature, [EcPublic, secp256r1]),
    ok.

prohibited_crypto_fails() ->
    Result = try crypto:hash(md5, <<"must fail in FIPS mode">>) of
        Digest -> {succeeded, Digest}
    catch
        Class:Reason -> {failed, Class, Reason}
    end,
    case Result of
        {failed, _, _} -> ok;
        {succeeded, Unexpected} -> erlang:error({prohibited_md5_succeeded, Unexpected})
    end.

tls_works() ->
    ApprovedSuite = #{
        cipher => aes_256_gcm,
        key_exchange => any,
        mac => aead,
        prf => sha384
    },
    ServerCredentials = public_key:pkix_test_data(#{
        root => [],
        intermediates => [],
        peer => [{key, {rsa, 3072, 65537}}, {digest, sha256}]
    }),
    CommonOptions = [
        binary,
        {active, false},
        {ciphers, [ApprovedSuite]},
        {versions, ['tlsv1.3']}
    ],
    {ok, Listener} = ssl:listen(0, ServerCredentials ++ CommonOptions),
    {ok, {_, Port}} = ssl:sockname(Listener),
    Parent = self(),
    Server = spawn_link(fun() -> tls_server(Parent, Listener) end),
    {ok, Client} = ssl:connect(
        {127, 0, 0, 1},
        Port,
        [{verify, verify_none} | CommonOptions],
        10000
    ),
    {ok, [{protocol, 'tlsv1.3'}, {selected_cipher_suite, ApprovedSuite}]} =
        ssl:connection_information(Client, [protocol, selected_cipher_suite]),
    ok = ssl:send(Client, <<"ping">>),
    {ok, <<"pong">>} = ssl:recv(Client, 4, 10000),
    receive
        {Server, tls_ok} -> ok
    after 10000 ->
        erlang:error(tls_server_timeout)
    end,
    ok = ssl:close(Client),
    ok = ssl:close(Listener),
    ok.

tls_server(Parent, Listener) ->
    {ok, Transport} = ssl:transport_accept(Listener, 10000),
    {ok, Socket} = ssl:handshake(Transport, 10000),
    {ok, <<"ping">>} = ssl:recv(Socket, 4, 10000),
    ok = ssl:send(Socket, <<"pong">>),
    ok = ssl:close(Socket),
    Parent ! {self(), tls_ok}.

no_loadable_crypto_nif(OtpRoot) ->
    Pattern = filename:join([OtpRoot, "lib", "crypto-*", "priv", "lib", "crypto.so"]),
    [] = filelib:wildcard(Pattern),
    ok.

no_dynamic_crypto_dependencies(OtpRoot, Inspector) ->
    [Beam | _] = filelib:wildcard(filename:join([OtpRoot, "erts-*", "bin", "beam.smp"])),
    Output = run(Inspector, ["-d", Beam]),
    false = contains(Output, <<"libcrypto.so">>),
    false = contains(Output, <<"libssl.so">>),
    ok.

run(Executable, Arguments) ->
    Port = open_port(
        {spawn_executable, Executable},
        [binary, exit_status, stderr_to_stdout, use_stdio, {args, Arguments}]
    ),
    await(Port, []).

await(Port, Chunks) ->
    receive
        {Port, {data, Data}} -> await(Port, [Data | Chunks]);
        {Port, {exit_status, 0}} -> iolist_to_binary(lists:reverse(Chunks));
        {Port, {exit_status, Status}} -> erlang:error({inspector_failed, Status, lists:reverse(Chunks)})
    end.

contains(Haystack, Needle) ->
    binary:match(Haystack, Needle) =/= nomatch.
