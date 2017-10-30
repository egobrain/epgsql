%%% Copyright (C) 2008 - Will Glozer.  All rights reserved.

-module(epgsql_binary).

-export([new_codec/2,
         update_codec/2,
         type_to_oid/2,
         typeinfo_to_name_array/2,
         typeinfo_to_oid_info/2,
         oid_to_name/2,
         oid_to_info/2,
         oid_to_decoder/3,
         decode/2, encode/3, supports/2]).
%% Composite type decoders
-export([decode_record/3, decode_array/3]).

-export_type([codec/0, decoder/0]).

-include("protocol.hrl").

-opaque codec() :: {module(), epgsql_oid_db:db()}.
-opaque decoder() :: {fun((binary(), epgsql:type_name(), epgsql_codec:codec_state()) -> any()),
                      epgsql:type_name(),
                      epgsql_codec:state()}.

-define(RECORD_OID, 2249).
-define(RECORD_ARRAY_OID, 2287).

-spec new_codec(module(), epgsql_sock:pg_sock()) -> codec().
new_codec(OidDb, PgSock) ->
    Codecs = default_codecs(),
    Oids = default_oids(),
    new_codec(OidDb, PgSock, Codecs, Oids).

new_codec(OidDb, PgSock, Codecs, Oids) ->
    CodecEntries = epgsql_codec:init_mods(Codecs, PgSock),
    Types = OidDb:join_codecs_oids(Oids, CodecEntries),
    {OidDb, OidDb:from_list(Types)}.

-spec update_codec([epgsql_oid_db:type_info()], codec()) -> codec().
update_codec(TypeInfos, {OidDb, Db}) ->
    {OidDb, OidDb:update(TypeInfos, Db)}.

-spec oid_to_name(epgsql_oid_db:oid(), codec()) -> Type | {unknown_oid, epgsql_oid_db:oid()} when
      Type :: epgsql:type_name() | {array, epgsql:type_name()}.
oid_to_name(Oid, Codec) ->
    case oid_to_info(Oid, Codec) of
        undefined ->
            {unknown_oid, Oid};
        Type ->
            case epgsql_oid_db:type_to_oid_info(Type) of
                {_, Name, true} -> {array, Name};
                {_, Name, false} -> Name
            end
    end.

type_to_oid({array, Name}, Codec) ->
    type_to_oid(Name, true, Codec);
type_to_oid(Name, Codec) ->
    type_to_oid(Name, false, Codec).

-spec type_to_oid(epgsql:type_name(), boolean(), codec()) -> epgsql_oid_db:oid().
type_to_oid(TypeName, IsArray, {OidDb, Db}) ->
    OidDb:oid_by_name(TypeName, IsArray, Db).

type_to_oid_info({array, Name}, Codec) ->
    type_to_info(Name, true, Codec);
type_to_oid_info(Name, Codec) ->
    type_to_info(Name, false, Codec).

-spec oid_to_info(epgsql_oid_db:oid(), codec()) -> epgsql_oid_db:type_info() | undefined.
oid_to_info(Oid, {OidDb, Db}) ->
    OidDb:find_by_oid(Oid, Db).

-spec type_to_info(epgsql:type_name(), boolean(), codec()) -> epgsql_oid_db:type_info().
type_to_info(TypeName, IsArray, {OidDb, Db}) ->
    OidDb:find_by_name(TypeName, IsArray, Db).

typeinfo_to_name_array({unknown_oid, _} = Unknown, _) -> Unknown;
typeinfo_to_name_array(TypeInfo, {OidDb, _}) ->
    case OidDb:type_to_oid_info(TypeInfo) of
        {_, Name, false} -> Name;
        {_, Name, true} -> {array, Name}
    end.

typeinfo_to_oid_info({unknown_oid, _} = Unknown, _) -> Unknown;
typeinfo_to_oid_info(TypeInfo, {OidDb, _}) ->
    OidDb:type_to_oid_info(TypeInfo).

%%
%% Decode
%%

-spec decode(binary(), decoder()) -> any().
decode(Bin, {Fun, TypeName, State}) ->
    Fun(Bin, TypeName, State).

-spec oid_to_decoder(epgsql_oid_db:oid(), binary | text, codec()) -> decoder().
oid_to_decoder(?RECORD_OID, binary, Codec) ->
    {fun ?MODULE:decode_record/3, record, Codec};
oid_to_decoder(?RECORD_ARRAY_OID, binary, Codec) ->
    %% See `make_array_decoder/3'
    {fun ?MODULE:decode_array/3, [], oid_to_decoder(?RECORD_OID, binary, Codec)};
oid_to_decoder(Oid, Format, {OidDb, Db}) ->
    case OidDb:find_by_oid(Oid, Db) of
        undefined when Format == binary ->
            {fun epgsql_codec_noop:decode/3, undefined, []};
        undefined when Format == text ->
            {fun epgsql_codec_noop:decode_text/3, undefined, []};
        Type ->
            make_decoder(Type, Format, OidDb)
    end.

-spec make_decoder(epgsql_oid_db:type_info(), binary | text, module()) -> decoder().
make_decoder(Type, Format, OidDb) ->
    {Name, Mod, State} = OidDb:type_to_codec_entry(Type),
    {_Oid, Name, IsArray} = OidDb:type_to_oid_info(Type),
    make_decoder(Name, Mod, State, Format, IsArray).

make_decoder(_Name, _Mod, _State, text, true) ->
    %% Don't try to decode text arrays
    {fun epgsql_codec_noop:decode_text/3, undefined, []};
make_decoder(Name, Mod, State, text, false) ->
    %% decode_text/3 is optional callback. If it's not defined, do NOOP.
    case erlang:function_exported(Mod, decode_text, 3) of
        true ->
            {fun Mod:decode_text/3, Name, State};
        false ->
            {fun epgsql_codec_noop:decode_text/3, undefined, []}
    end;
make_decoder(Name, Mod, State, binary, true) ->
    make_array_decoder(Name, Mod, State);
make_decoder(Name, Mod, State, binary, false) ->
    {fun Mod:decode/3, Name, State}.


%% Array decoding
%%% $PG$/src/backend/utils/adt/arrayfuncs.c
make_array_decoder(Name, Mod, State) ->
    {fun ?MODULE:decode_array/3, [], {fun Mod:decode/3, Name, State}}.

decode_array(<<NDims:?int32, _HasNull:?int32, _Oid:?int32, Rest/binary>>, _, ElemDecoder) ->
    %% 4b: n_dimensions;
    %% 4b: flags;
    %% 4b: Oid // should be the same as in column spec;
    %%   (4b: n_elements;
    %%    4b: lower_bound) * n_dimensions
    %% (dynamic-size data)
    %% Lower bound - eg, zero-bound or 1-bound or N-bound array. We ignore it, see
    %% https://www.postgresql.org/docs/current/static/arrays.html#arrays-io
    {Dims, Data} = erlang:split_binary(Rest, NDims * 2 * 4),
    Lengths = [Len || <<Len:?int32, _LBound:?int32>> <= Dims],
    {Array, <<>>} = decode_array1(Data, Lengths, ElemDecoder),
    Array.

decode_array1(Data, [], _)  ->
    %% zero-dimensional array
    {[], Data};
decode_array1(Data, [Len], ElemDecoder) ->
    %% 1-dimensional array
    decode_elements(Data, [], Len, ElemDecoder);
decode_array1(Data, [Len | T], ElemDecoder) ->
    %% multidimensional array
    F = fun(_N, Rest) -> decode_array1(Rest, T, ElemDecoder) end,
    lists:mapfoldl(F, Data, lists:seq(1, Len)).

decode_elements(Rest, Acc, 0, _ElDec) ->
    {lists:reverse(Acc), Rest};
decode_elements(<<-1:?int32, Rest/binary>>, Acc, N, ElDec) ->
    decode_elements(Rest, [null | Acc], N - 1, ElDec);
decode_elements(<<Len:?int32, Value:Len/binary, Rest/binary>>, Acc, N, ElemDecoder) ->
    Value2 = decode(Value, ElemDecoder),
    decode_elements(Rest, [Value2 | Acc], N - 1, ElemDecoder).



%% Record decoding
%% $PG$/src/backend/utils/adt/rowtypes.c
decode_record(<<Size:?int32, Bin/binary>>, record, Codec) ->
    list_to_tuple(decode_record1(Bin, Size, Codec)).

decode_record1(<<>>, 0, _Codec) -> [];
decode_record1(<<_Type:?int32, -1:?int32, Rest/binary>>, Size, Codec) ->
    [null | decode_record1(Rest, Size - 1, Codec)];
decode_record1(<<Oid:?int32, Len:?int32, ValueBin:Len/binary, Rest/binary>>, Size, {OidDb, Db} = Codec) ->
    Value =
        case OidDb:find_by_oid(Oid, Db) of
            undefined -> ValueBin;
            Type ->
                {Name, Mod, State} = OidDb:type_to_codec_entry(Type),
                Mod:decode(ValueBin, Name, State)
        end,
    [Value | decode_record1(Rest, Size - 1, Codec)].


%%
%% Encode
%%
-spec encode(epgsql:type_name() | {array, epgsql:type_name()}, any(), codec()) -> iolist().
encode(TypeName, Value, {OidDb, _Db} = Codec) ->
    Type = type_to_oid_info(TypeName, Codec),
    encode_with_type(Type, Value, OidDb).

encode_with_type(Type, Value, OidDb) ->
    {Name, Mod, State} = OidDb:type_to_codec_entry(Type),
    case OidDb:type_to_oid_info(Type) of
        {_ArrayOid, _, true} ->
            %FIXME: check if this OID is the same as was returned by 'Describe'
            ElementOid = OidDb:type_to_element_oid(Type),
            encode_array(Value, ElementOid, {Mod, Name, State});
        {_Oid, _, false} ->
            encode_value(Value, {Mod, Name, State})
    end.

encode_value(Value, {Mod, Name, State}) ->
    Payload = Mod:encode(Value, Name, State),
    [<<(iolist_size(Payload)):?int32>> | Payload].


%% Number of dimensions determined at encode-time by introspection of data, so,
%% we can't encode array of lists (eg. strings).
encode_array(Array, Oid, ValueEncoder) ->
    {Data, {NDims, Lengths}} = encode_array(Array, 0, [], ValueEncoder),
    Lens = [<<N:?int32, 1:?int32>> || N <- lists:reverse(Lengths)],
    Hdr  = <<NDims:?int32, 0:?int32, Oid:?int32>>,
    Payload  = [Hdr, Lens, Data],
    [<<(iolist_size(Payload)):?int32>> | Payload].

encode_array([], NDims, Lengths, _Codec) ->
    {[], {NDims, Lengths}};
encode_array([H | _] = Array, NDims, Lengths, ValueEncoder) when not is_list(H) ->
    F = fun(E, Len) -> {encode_value(E, ValueEncoder), Len + 1} end,
    {Data, Len} = lists:mapfoldl(F, 0, Array),
    {Data, {NDims + 1, [Len | Lengths]}};
encode_array(Array, NDims, Lengths, Codec) ->
    Lengths2 = [length(Array) | Lengths],
    F = fun(A2, {_NDims, _Lengths}) -> encode_array(A2, NDims, Lengths2, Codec) end,
    {Data, {NDims2, Lengths3}} = lists:mapfoldl(F, {NDims, Lengths2}, Array),
    {Data, {NDims2 + 1, Lengths3}}.


%% Supports
supports(RecOid, _) when RecOid == ?RECORD_OID; RecOid == ?RECORD_ARRAY_OID ->
    true;
supports(Oid, {OidDb, Db}) ->
    OidDb:find_by_oid(Oid, Db) =/= undefined.

%% Default codec set
-spec default_codecs() -> [epgsql_codec:codec_entry()].
default_codecs() ->
    [{epgsql_codec_boolean,[]},
     {epgsql_codec_bpchar,[]},
     {epgsql_codec_datetime,[]},
     {epgsql_codec_float,[]},
     {epgsql_codec_geometric, []},
     %% {epgsql_codec_hstore, []},
     {epgsql_codec_integer,[]},
     {epgsql_codec_intrange,[]},
     {epgsql_codec_json,[]},
     {epgsql_codec_net,[]},
     %% {epgsql_codec_postgis,[]},
     {epgsql_codec_text,[]},
     {epgsql_codec_uuid,[]}].

-spec default_oids() -> [epgsql_oid_db:oid_entry()].
default_oids() ->
    [{bool, 16, 1000},
     {bpchar, 1042, 1014},
     {bytea, 17, 1001},
     {char, 18, 1002},
     {cidr, 650, 651},
     {date, 1082, 1182},
     {float4, 700, 1021},
     {float8, 701, 1022},
     %% {geometry, 17063, 17071},
     %% {hstore, 16935, 16940},
     {inet, 869, 1041},
     {int2, 21, 1005},
     {int4, 23, 1007},
     {int4range, 3904, 3905},
     {int8, 20, 1016},
     {int8range, 3926, 3927},
     {interval, 1186, 1187},
     {json, 114, 199},
     {jsonb, 3802, 3807},
     {point, 600, 1017},
     {text, 25, 1009},
     {time, 1083, 1183},
     {timestamp, 1114, 1115},
     {timestamptz, 1184, 1185},
     {timetz, 1266, 1270},
     {uuid, 2950, 2951},
     {varchar, 1043, 1015}].
