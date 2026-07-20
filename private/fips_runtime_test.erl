%% Runtime and static-linkage checks for an OTP toolchain built in FIPS mode.
-module(fips_runtime_test).
-export([main/1]).

main([OtpRoot0]) ->
    OtpRoot = filename:absname(OtpRoot0),
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
    no_dynamic_crypto_dependencies(OtpRoot),
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
    P256 = {1, 2, 840, 10045, 3, 1, 7},
    CertificateOptions = [{key, {namedCurve, P256}}, {digest, sha256}],
    ApprovedSuite = #{
        cipher => aes_256_gcm,
        key_exchange => any,
        mac => aead,
        prf => sha384
    },
    ServerCredentials = public_key:pkix_test_data(#{
        root => CertificateOptions,
        intermediates => [],
        peer => CertificateOptions
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

no_dynamic_crypto_dependencies(OtpRoot) ->
    [Beam | _] = filelib:wildcard(filename:join([OtpRoot, "erts-*", "bin", "beam.smp"])),
    Needed = elf_needed_libraries(Beam),
    false = lists:any(fun(Name) -> contains(Name, <<"libcrypto.so">>) end, Needed),
    false = lists:any(fun(Name) -> contains(Name, <<"libssl.so">>) end, Needed),
    ok.

elf_needed_libraries(Path) ->
    {ok, Binary} = file:read_file(Path),
    <<16#7f, $E, $L, $F, 2, 1, _Ident:10/binary,
      _Type:16/little-unsigned-integer,
      _Machine:16/little-unsigned-integer,
      _Version:32/little-unsigned-integer,
      _Entry:64/little-unsigned-integer,
      _ProgramOffset:64/little-unsigned-integer,
      SectionOffset:64/little-unsigned-integer,
      _Flags:32/little-unsigned-integer,
      _HeaderSize:16/little-unsigned-integer,
      _ProgramEntrySize:16/little-unsigned-integer,
      _ProgramCount:16/little-unsigned-integer,
      SectionEntrySize:16/little-unsigned-integer,
      SectionCount:16/little-unsigned-integer,
      _SectionNames:16/little-unsigned-integer,
      _/binary>> = Binary,
    Sections = [
        elf_section(Binary, SectionOffset, SectionEntrySize, Index)
     || Index <- lists:seq(0, SectionCount - 1)
    ],
    lists:append([
        elf_dynamic_libraries(Binary, Section, Sections)
     || Section <- Sections,
        maps:get(type, Section) =:= 6
    ]).

elf_section(Binary, SectionOffset, SectionEntrySize, Index) ->
    Offset = SectionOffset + Index * SectionEntrySize,
    Header = binary:part(Binary, Offset, SectionEntrySize),
    <<_Name:32/little-unsigned-integer,
      Type:32/little-unsigned-integer,
      _Flags:64/little-unsigned-integer,
      _Address:64/little-unsigned-integer,
      FileOffset:64/little-unsigned-integer,
      Size:64/little-unsigned-integer,
      Link:32/little-unsigned-integer,
      _Info:32/little-unsigned-integer,
      _Alignment:64/little-unsigned-integer,
      EntrySize:64/little-unsigned-integer,
      _/binary>> = Header,
    #{
        entry_size => EntrySize,
        link => Link,
        offset => FileOffset,
        size => Size,
        type => Type
    }.

elf_dynamic_libraries(Binary, Dynamic, Sections) ->
    StringTable = lists:nth(maps:get(link, Dynamic) + 1, Sections),
    Strings = binary:part(
        Binary,
        maps:get(offset, StringTable),
        maps:get(size, StringTable)
    ),
    Entries = binary:part(Binary, maps:get(offset, Dynamic), maps:get(size, Dynamic)),
    elf_dynamic_entries(Entries, maps:get(entry_size, Dynamic), Strings, []).

elf_dynamic_entries(_Entries, 0, _Strings, _Acc) ->
    erlang:error(invalid_elf_dynamic_entry_size);
elf_dynamic_entries(Entries, EntrySize, Strings, Acc) when byte_size(Entries) >= EntrySize ->
    <<Entry:EntrySize/binary, Rest/binary>> = Entries,
    <<Tag:64/little-signed-integer, Value:64/little-unsigned-integer, _/binary>> = Entry,
    case Tag of
        0 -> lists:reverse(Acc);
        1 -> elf_dynamic_entries(Rest, EntrySize, Strings, [elf_string(Strings, Value) | Acc]);
        _ -> elf_dynamic_entries(Rest, EntrySize, Strings, Acc)
    end;
elf_dynamic_entries(<<>>, _EntrySize, _Strings, Acc) ->
    lists:reverse(Acc).

elf_string(Strings, Offset) ->
    Tail = binary:part(Strings, Offset, byte_size(Strings) - Offset),
    [Value | _] = binary:split(Tail, <<0>>),
    Value.

contains(Haystack, Needle) ->
    binary:match(Haystack, Needle) =/= nomatch.
