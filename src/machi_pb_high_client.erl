%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2015 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc Machi PB (Protocol Buffers) high-level client (prototype, API TBD)
%%
%% At the moment, this is brittle-prototype-quality code: the API is not yet
%% fully specified, there is very little error handling with respect
%% to a single socket connection, and there is no code to deal with
%% multiple connections/load balancing/error handling to several/all
%% Machi cluster servers.

-module(machi_pb_high_client).

-include("machi.hrl").
-include("machi_pb.hrl").
-include("machi_projection.hrl").

-define(DEFAULT_TIMEOUT, 10*1000).

-export([start_link/1, quit/1,
         connected_p/1,
         echo/2, echo/3,
         auth/3, auth/4,
         append_chunk/7, append_chunk/8,
         write_chunk/5, write_chunk/6,
         read_chunk/5, read_chunk/6,
         trim_chunk/4, trim_chunk/5,
         checksum_list/2, checksum_list/3,
         list_files/1, list_files/2
        ]).
-export([convert_general_status_code/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
          server_list :: p_srvr_dict(),
          sock        :: 'undefined' | port(),
          sock_id     :: integer(),
          count=0     :: non_neg_integer()
         }).

%% Official error types that is specific in Machi
-type machi_client_error_reason() :: bad_arg | wedged | bad_checksum |
                                     partition | not_written | written |
                                     trimmed | no_such_file | partial_read |
                                     bad_epoch | inet:posix().

%% @doc Creates a client process
-spec start_link(p_srvr_dict()) -> {ok, pid()} | {error, machi_client_error_reason()}.
start_link(P_srvr_list) ->
    gen_server:start_link(?MODULE, [P_srvr_list], []).

%% @doc Stops a client process.
-spec quit(pid()) -> ok.
quit(PidSpec) ->
    gen_server:call(PidSpec, quit, infinity).

connected_p(PidSpec) ->
    gen_server:call(PidSpec, connected_p, infinity).

-spec echo(pid(), string()) -> {ok, string()} | {error, machi_client_error_reason()}.
echo(PidSpec, String) ->
    echo(PidSpec, String, ?DEFAULT_TIMEOUT).

-spec echo(pid(), string(), non_neg_integer()) -> {ok, string()} | {error, machi_client_error_reason()}.
echo(PidSpec, String, Timeout) ->
    send_sync(PidSpec, {echo, String}, Timeout).

%% TODO: auth() is not implemented.  Auth requires SSL, and this client
%% doesn't support SSL yet.  This is just a placeholder and reminder.

-spec auth(pid(), string(), string()) -> ok | {error, machi_client_error_reason()}.
auth(PidSpec, User, Pass) ->
    auth(PidSpec, User, Pass, ?DEFAULT_TIMEOUT).

-spec auth(pid(), string(), string(), non_neg_integer()) -> ok | {error, machi_client_error_reason()}.
auth(PidSpec, User, Pass, Timeout) ->
    send_sync(PidSpec, {auth, User, Pass}, Timeout).

-spec append_chunk(pid(), CoC_namespace::binary(), CoC_locator::integer(), Prefix::binary(), Chunk::binary(),
                   CSum::binary(), ChunkExtra::non_neg_integer()) ->
                          {ok, Filename::string(), Offset::machi_dt:file_offset()} |
                          {error, machi_client_error_reason()}.
append_chunk(PidSpec, CoC_namespace, CoC_locator, Prefix, Chunk, CSum, ChunkExtra) ->
    append_chunk(PidSpec, CoC_namespace, CoC_locator, Prefix, Chunk, CSum, ChunkExtra, ?DEFAULT_TIMEOUT).

-spec append_chunk(pid(), CoC_namespace::binary(), CoC_locator::integer(), Prefix::binary(),
                   Chunk::binary(), CSum::binary(),
                   ChunkExtra::non_neg_integer(),
                   Timeout::non_neg_integer()) ->
                          {ok, Filename::string(), Offset::machi_dt:file_offset()} |
                          {error, machi_client_error_reason()}.
append_chunk(PidSpec, CoC_namespace, CoC_locator, Prefix, Chunk, CSum, ChunkExtra, Timeout) ->
    send_sync(PidSpec, {append_chunk, CoC_namespace, CoC_locator, Prefix, Chunk, CSum, ChunkExtra}, Timeout).

-spec write_chunk(pid(), File::string(), machi_dt:file_offset(),
                  Chunk::binary(), CSum::binary()) ->
                         ok | {error, machi_client_error_reason()}.
write_chunk(PidSpec, File, Offset, Chunk, CSum) ->
    write_chunk(PidSpec, File, Offset, Chunk, CSum, ?DEFAULT_TIMEOUT).

-spec write_chunk(pid(), File::string(), machi_dt:file_offset(),
                  Chunk::binary(), CSum::binary(), Timeout::non_neg_integer()) ->
                         ok | {error, machi_client_error_reason()}.
write_chunk(PidSpec, File, Offset, Chunk, CSum, Timeout) ->
    send_sync(PidSpec, {write_chunk, File, Offset, Chunk, CSum}, Timeout).

%% @doc Tries to read a chunk of a specified file. It returns `{ok,
%% {Chunks, TrimmedChunks}}' for live file while it returns `{error,
%% trimmed}' if all bytes of the file was trimmed.
-spec read_chunk(pid(), File::string(), machi_dt:file_offset(), machi_dt:chunk_size(),
                 [{flag_no_checksum | flag_no_chunk | needs_trimmed, boolean()}]) ->
                        {ok, {Chunks::[{File::string(), machi_dt:file_offset(), machi_dt:chunk_size(), binary()}],
                              Trimmed::[{File::string(), machi_dt:file_offset(), machi_dt:chunk_size()}]}} |
                        {error, machi_client_error_reason()}.
read_chunk(PidSpec, File, Offset, Size, Options) ->
    read_chunk(PidSpec, File, Offset, Size, Options, ?DEFAULT_TIMEOUT).

-spec read_chunk(pid(), File::string(), machi_dt:file_offset(), machi_dt:chunk_size(),
                 [{flag_no_checksum | flag_no_chunk | needs_trimmed, boolean()}],
                 Timeout::non_neg_integer()) ->
                        {ok, {Chunks::[{File::string(), machi_dt:file_offset(), machi_dt:chunk_size(), binary()}],
                              Trimmed::[{File::string(), machi_dt:file_offset(), machi_dt:chunk_size()}]}} |
                        {error, machi_client_error_reason()}.
read_chunk(PidSpec, File, Offset, Size, Options, Timeout) ->
    send_sync(PidSpec, {read_chunk, File, Offset, Size, Options}, Timeout).

%% @doc Trims arbitrary binary range of any file. If a specified range
%% has any byte trimmed, it fails and returns `{error, trimmed}'.
%% Otherwise it trims all bytes in that range. If there are
%% overlapping chunks with client-specified checksum, they will cut
%% off and checksum are re-calculated in server side.  TODO: Add
%% option specifying whether to trigger GC.
-spec trim_chunk(pid(), string(), non_neg_integer(), machi_dt:chunk_size()) ->
                        ok | {error, machi_client_error_reason()}.
trim_chunk(PidSpec, File, Offset, Size) ->
    trim_chunk(PidSpec, File, Offset, Size, ?DEFAULT_TIMEOUT).

trim_chunk(PidSpec, File, Offset, Size, Timeout) ->
    send_sync(PidSpec, {trim_chunk, File, Offset, Size}, Timeout).

%% @doc Returns a binary that has checksums and chunks encoded inside
%% (This is because encoding-decoding them are inefficient). TODO:
%% return a structured list of them.
-spec checksum_list(pid(), string()) -> {ok, binary()} | {error, machi_client_error_reason()}.
checksum_list(PidSpec, File) ->
    checksum_list(PidSpec, File, ?DEFAULT_TIMEOUT).

checksum_list(PidSpec, File, Timeout) ->
    send_sync(PidSpec, {checksum_list, File}, Timeout).

list_files(PidSpec) ->
    list_files(PidSpec, ?DEFAULT_TIMEOUT).

list_files(PidSpec, Timeout) ->
    send_sync(PidSpec, {list_files}, Timeout).

send_sync(PidSpec, Cmd, Timeout) ->
    gen_server:call(PidSpec, {send_sync, Cmd}, Timeout).

%%%%%%%%%%%%%%%%%%%%%%%%%%%

init([P_srvr_list]) ->
    {ok, #state{server_list=P_srvr_list}}.

handle_call(quit, _From, S) ->
    {stop, normal, ok, S};
handle_call(connected_p, _From, #state{sock=Port}=S)
  when is_port(Port) ->
    {reply, true, S};
handle_call(connected_p, _From, #state{sock=undefined}=S) ->
    S2 = try_connect(S),
    {reply, is_port(S2#state.sock), S2};
handle_call({send_sync, _Cmd}, _From, #state{sock=undefined}=S) ->
    {reply, not_connected, S};
handle_call({send_sync, Cmd}, _From, S) ->
    {Reply, S2} = do_send_sync(Cmd, try_connect(S)),
    {reply, Reply, S2};
handle_call(_Request, _From, S) ->
    Reply = whaaaaaaaaaaaaaaaaaaaa,
    {reply, Reply, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(_Info, S) ->
    io:format(user, "~s:handle_info: ~p\n", [?MODULE, _Info]),
    {noreply, S}.

terminate(_Reason, _S) ->
    ok.

code_change(_OldVsn, S, _Extra) ->
    {ok, S}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%

try_connect(#state{sock=Sock}=S) when is_port(Sock) ->
    S;
try_connect(#state{server_list=Ps}=S) ->
    case lists:foldl(fun(_, Sock) when is_port(Sock) ->
                             Sock;
                        (P, _) ->
                             do_connect_to_pb_listener(P)
                     end, unused, Ps) of
        Sock when is_port(Sock) ->
            {id, Index} = erlang:port_info(Sock, id),
            S#state{sock=Sock, sock_id=Index, count=0};
        _Else ->
            S
    end.

do_connect_to_pb_listener(P) ->
    try
        {ok, Sock} = gen_tcp:connect(P#p_srvr.address, P#p_srvr.port,
                                     ?PB_PACKET_OPTS ++
                                     [binary, {active, false}]),
        Sock
    catch _X:_Y ->
            io:format(user, "\n~p ~p @ ~p\n", [_X, _Y, erlang:get_stacktrace()]),
            bummer
    end.

do_send_sync(Cmd, S) ->
    do_send_sync2(Cmd, S).

do_send_sync2({echo, String}, #state{sock=Sock}=S) ->
    try
        ReqID = <<0>>,
        R1a = #mpb_request{req_id=ReqID, do_not_alter=1,
                           echo=#mpb_echoreq{message=String}},
        Bin1a = machi_pb:encode_mpb_request(R1a),
        ok = gen_tcp:send(Sock, Bin1a),
        {ok, Bin1B} = gen_tcp:recv(Sock, 0),
        case (catch machi_pb:decode_mpb_response(Bin1B)) of
            #mpb_response{req_id=ReqID, echo=Echo} when Echo /= undefined ->
                {Echo#mpb_echoresp.message, S};
            #mpb_response{req_id=ReqID, generic=G} when G /= undefined ->
                #mpb_errorresp{code=Code, msg=Msg, extra=Extra} = G,
                {{error, {Code, Msg, Extra}}, S}
        end
    catch X:Y ->
            Res = {bummer, {X, Y, erlang:get_stacktrace()}},
            {Res, S}
    end;
do_send_sync2({auth, User, Pass}, #state{sock=Sock}=S) ->
    try
        ReqID = <<0>>,
        R1a = #mpb_request{req_id=ReqID, do_not_alter=1,
                           auth=#mpb_authreq{user=User, password=Pass}},
        Bin1a = machi_pb:encode_mpb_request(R1a),
        ok = gen_tcp:send(Sock, Bin1a),
        {ok, Bin1B} = gen_tcp:recv(Sock, 0),
        case (catch machi_pb:decode_mpb_response(Bin1B)) of
            #mpb_response{req_id=ReqID, auth=Auth} when Auth /= undefined ->
                {Auth#mpb_authresp.code, S};
            #mpb_response{req_id=ReqID, generic=G} when G /= undefined ->
                #mpb_errorresp{code=Code, msg=Msg, extra=Extra} = G,
                {{error, {Code, Msg, Extra}}, S}
        end
    catch X:Y ->
            Res = {bummer, {X, Y, erlang:get_stacktrace()}},
            {Res, S}
    end;
do_send_sync2({append_chunk, CoC_Namespace, CoC_Locator,
               Prefix, Chunk, CSum, ChunkExtra},
             #state{sock=Sock, sock_id=Index, count=Count}=S) ->
    try
        ReqID = <<Index:64/big, Count:64/big>>,
        CSumT = convert_csum_req(CSum, Chunk),
        Req = #mpb_appendchunkreq{coc_namespace=CoC_Namespace,
                                  coc_locator=CoC_Locator,
                                  prefix=Prefix,
                                  chunk=Chunk,
                                  csum=CSumT,
                                  chunk_extra=ChunkExtra},
        R1a = #mpb_request{req_id=ReqID, do_not_alter=1,
                           append_chunk=Req},
        Bin1a = machi_pb:encode_mpb_request(R1a),
        ok = gen_tcp:send(Sock, Bin1a),
        {ok, Bin1B} = gen_tcp:recv(Sock, 0),
        case (catch machi_pb:decode_mpb_response(Bin1B)) of
            #mpb_response{req_id=ReqID, append_chunk=R} when R /= undefined ->
                Result = convert_append_chunk_resp(R),
                {Result, S#state{count=Count+1}};
            #mpb_response{req_id=ReqID, generic=G} when G /= undefined ->
                #mpb_errorresp{code=Code, msg=Msg, extra=Extra} = G,
                {{error, {Code, Msg, Extra}}, S#state{count=Count+1}}
        end
    catch X:Y ->
            Res = {bummer, {X, Y, erlang:get_stacktrace()}},
            {Res, S#state{count=Count+1}}
    end;
do_send_sync2({write_chunk, File, Offset, Chunk, CSum},
             #state{sock=Sock, sock_id=Index, count=Count}=S) ->
    try
        ReqID = <<Index:64/big, Count:64/big>>,
        CSumT = convert_csum_req(CSum, Chunk),
        Req = #mpb_writechunkreq{chunk=
                                     #mpb_chunk{chunk=Chunk,
                                                file_name=File,
                                                offset=Offset,
                                                csum=CSumT}},
        R1a = #mpb_request{req_id=ReqID, do_not_alter=1,
                           write_chunk=Req},
        Bin1a = machi_pb:encode_mpb_request(R1a),
        ok = gen_tcp:send(Sock, Bin1a),
        {ok, Bin1B} = gen_tcp:recv(Sock, 0),
        case (catch machi_pb:decode_mpb_response(Bin1B)) of
            #mpb_response{req_id=ReqID, write_chunk=R} when R /= undefined ->
                Result = convert_write_chunk_resp(R),
                {Result, S#state{count=Count+1}};
            #mpb_response{req_id=ReqID, generic=G} when G /= undefined ->
                #mpb_errorresp{code=Code, msg=Msg, extra=Extra} = G,
                {{error, {Code, Msg, Extra}}, S#state{count=Count+1}}
        end
    catch X:Y ->
            Res = {bummer, {X, Y, erlang:get_stacktrace()}},
            {Res, S#state{count=Count+1}}
    end;
do_send_sync2({read_chunk, File, Offset, Size, Options},
             #state{sock=Sock, sock_id=Index, count=Count}=S) ->
    try
        ReqID = <<Index:64/big, Count:64/big>>,
        FlagNoChecksum = proplists:get_value(no_checksum, Options, false),
        FlagNoChunk = proplists:get_value(no_chunk, Options, false),
        NeedsTrimmed = proplists:get_value(needs_trimmed, Options, false),
        Req = #mpb_readchunkreq{chunk_pos=#mpb_chunkpos{file_name=File,
                                                        offset=Offset,
                                                        chunk_size=Size},
                                flag_no_checksum=machi_util:bool2int(FlagNoChecksum),
                                flag_no_chunk=machi_util:bool2int(FlagNoChunk),
                                flag_needs_trimmed=machi_util:bool2int(NeedsTrimmed)},
        R1a = #mpb_request{req_id=ReqID, do_not_alter=1,
                           read_chunk=Req},
        Bin1a = machi_pb:encode_mpb_request(R1a),
        ok = gen_tcp:send(Sock, Bin1a),
        {ok, Bin1B} = gen_tcp:recv(Sock, 0),
        case (catch machi_pb:decode_mpb_response(Bin1B)) of
            #mpb_response{req_id=ReqID, read_chunk=R} when R /= undefined ->
                Result = convert_read_chunk_resp(R),
                {Result, S#state{count=Count+1}};
            #mpb_response{req_id=ReqID, generic=G} when G /= undefined ->
                #mpb_errorresp{code=Code, msg=Msg, extra=Extra} = G,
                {{error, {Code, Msg, Extra}}, S#state{count=Count+1}}
        end
    catch X:Y ->
            Res = {bummer, {X, Y, erlang:get_stacktrace()}},
            {Res, S#state{count=Count+1}}
    end;
do_send_sync2({trim_chunk, File, Offset, Size},
              #state{sock=Sock, sock_id=Index, count=Count}=S) ->
    try
        ReqID = <<Index:64/big, Count:64/big>>,
        Req = #mpb_trimchunkreq{chunk_pos=#mpb_chunkpos{file_name=File,
                                                        offset=Offset,
                                                        chunk_size=Size}},
        R1a = #mpb_request{req_id=ReqID, do_not_alter=1,
                           trim_chunk=Req},
        Bin1a = machi_pb:encode_mpb_request(R1a),
        ok = gen_tcp:send(Sock, Bin1a),
        {ok, Bin1B} = gen_tcp:recv(Sock, 0),
        case (catch machi_pb:decode_mpb_response(Bin1B)) of
            #mpb_response{req_id=ReqID, trim_chunk=R} when R /= undefined ->
                Result = convert_trim_chunk_resp(R),
                {Result, S#state{count=Count+1}};
            #mpb_response{req_id=ReqID, generic=G} when G /= undefined ->
                #mpb_errorresp{code=Code, msg=Msg, extra=Extra} = G,
                {{error, {Code, Msg, Extra}}, S#state{count=Count+1}}
        end
    catch X:Y ->
            Res = {bummer, {X, Y, erlang:get_stacktrace()}},
            {Res, S#state{count=Count+1}}
    end;
do_send_sync2({checksum_list, File},
             #state{sock=Sock, sock_id=Index, count=Count}=S) ->
    try
        ReqID = <<Index:64/big, Count:64/big>>,
        Req = #mpb_checksumlistreq{file=File},
        R1a = #mpb_request{req_id=ReqID, do_not_alter=1,
                           checksum_list=Req},
        Bin1a = machi_pb:encode_mpb_request(R1a),
        ok = gen_tcp:send(Sock, Bin1a),
        {ok, Bin1B} = gen_tcp:recv(Sock, 0),
        case (catch machi_pb:decode_mpb_response(Bin1B)) of
            #mpb_response{req_id=ReqID, checksum_list=R} when R /= undefined ->
                Result = convert_checksum_list_resp(R),
                {Result, S#state{count=Count+1}};
            #mpb_response{req_id=ReqID, generic=G} when G /= undefined ->
                #mpb_errorresp{code=Code, msg=Msg, extra=Extra} = G,
                {{error, {Code, Msg, Extra}}, S#state{count=Count+1}}
        end
    catch X:Y ->
            Res = {bummer, {X, Y, erlang:get_stacktrace()}},
            {Res, S#state{count=Count+1}}
    end;
do_send_sync2({list_files},
             #state{sock=Sock, sock_id=Index, count=Count}=S) ->
    try
        ReqID = <<Index:64/big, Count:64/big>>,
        Req = #mpb_listfilesreq{},
        R1a = #mpb_request{req_id=ReqID, do_not_alter=1,
                           list_files=Req},
        Bin1a = machi_pb:encode_mpb_request(R1a),
        ok = gen_tcp:send(Sock, Bin1a),
        {ok, Bin1B} = gen_tcp:recv(Sock, 0),
        case (catch machi_pb:decode_mpb_response(Bin1B)) of
            #mpb_response{req_id=ReqID, list_files=R} when R /= undefined ->
                Result = convert_list_files_resp(R),
                {Result, S#state{count=Count+1}};
            #mpb_response{req_id=ReqID, generic=G} when G /= undefined ->
                #mpb_errorresp{code=Code, msg=Msg, extra=Extra} = G,
                {{error, {Code, Msg, Extra}}, S#state{count=Count+1}}
        end
    catch X:Y ->
            Res = {bummer, {X, Y, erlang:get_stacktrace()}},
            {Res, S#state{count=Count+1}}
    end.

convert_csum_req(none, Chunk) ->
    #mpb_chunkcsum{type='CSUM_TAG_CLIENT_SHA',
                   csum=machi_util:checksum_chunk(Chunk)};
convert_csum_req({client_sha, CSumBin}, _Chunk) ->
    #mpb_chunkcsum{type='CSUM_TAG_CLIENT_SHA',
                   csum=CSumBin}.

convert_append_chunk_resp(#mpb_appendchunkresp{status='OK', chunk_pos=CP}) ->
    #mpb_chunkpos{offset=Offset, chunk_size=Size, file_name=File} = CP,
    {ok, {Offset, Size, list_to_binary(File)}};
convert_append_chunk_resp(#mpb_appendchunkresp{status=Status}) ->
    convert_general_status_code(Status).

convert_general_status_code('OK') ->
    ok;
convert_general_status_code('BAD_ARG') ->
    {error, bad_arg};
convert_general_status_code('WEDGED') ->
    {error, wedged};
convert_general_status_code('BAD_CHECKSUM') ->
    {error, bad_checksum};
convert_general_status_code('PARTITION') ->
    {error, partition};
convert_general_status_code('NOT_WRITTEN') ->
    {error, not_written};
convert_general_status_code('WRITTEN') ->
    {error, written};
convert_general_status_code('TRIMMED') ->
    {error, trimmed};
convert_general_status_code('NO_SUCH_FILE') ->
    {error, no_such_file};
convert_general_status_code('PARTIAL_READ') ->
    {error, partial_read};
convert_general_status_code('BAD_EPOCH') ->
    {error, bad_epoch};
convert_general_status_code('BAD_JOSS') ->
    throw({error, bad_joss_taipan_fixme}).

convert_write_chunk_resp(#mpb_writechunkresp{status='OK'}) ->
    ok;
convert_write_chunk_resp(#mpb_writechunkresp{status=Status}) ->
    convert_general_status_code(Status).

convert_read_chunk_resp(#mpb_readchunkresp{status='OK', chunks=PB_Chunks, trimmed=PB_Trimmed}) ->
    Chunks = lists:map(fun(#mpb_chunk{offset=Offset,
                                      file_name=File,
                                      chunk=Chunk,
                                      csum=#mpb_chunkcsum{type=T, csum=Ck}}) ->
                               %% TODO: cleanup export
                               Csum = <<(machi_pb_translate:conv_to_csum_tag(T)):8, Ck/binary>>,
                               {File, Offset, Chunk, Csum}
                       end, PB_Chunks),
    Trimmed = lists:map(fun(#mpb_chunkpos{file_name=File,
                                          offset=Offset,
                                          chunk_size=Size}) ->
                                {File, Offset, Size}
                        end, PB_Trimmed),
    {ok, {Chunks, Trimmed}};
convert_read_chunk_resp(#mpb_readchunkresp{status=Status}) ->
    convert_general_status_code(Status).

convert_trim_chunk_resp(#mpb_trimchunkresp{status='OK'}) ->
    ok;
convert_trim_chunk_resp(#mpb_trimchunkresp{status=Status}) ->
    convert_general_status_code(Status).

convert_checksum_list_resp(#mpb_checksumlistresp{status='OK', chunk=Chunk}) ->
    {ok, Chunk};
convert_checksum_list_resp(#mpb_checksumlistresp{status=Status}) ->
    convert_general_status_code(Status).

convert_list_files_resp(#mpb_listfilesresp{status='OK', files=Files}) ->
    FileInfo = [{Size, list_to_binary(File)} ||
                   #mpb_fileinfo{file_size=Size,
                                 file_name=File} <- Files],
    {ok, FileInfo};
convert_list_files_resp(#mpb_listfilesresp{status=Status}) ->
    convert_general_status_code(Status).
