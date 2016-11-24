%% Copyright 2016, Bernard Notarianni
%%
%% Licensed under the Apache License, Version 2.0 (the "License"); you may not
%% use this file except in compliance with the License. You may obtain a copy of
%% the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
%% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
%% License for the specific language governing permissions and limitations under
%% the License.

-module(barrel_http_SUITE).

-export([all/0,
         end_per_suite/1,
         end_per_testcase/2,
         init_per_suite/1,
         init_per_testcase/2]).

-export([info_database/1,
         all_docs/1,
         changes_normal/1,
         changes_longpoll/1,
         changes_longpoll_heartbeat/1,
         changes_eventsource/1,
         create_database/1,
         system_doc/1]).

all() -> [ info_database
         , all_docs
         , changes_normal
         , changes_longpoll
         , changes_longpoll_heartbeat
         , changes_eventsource
         , create_database
         , system_doc
         ].

init_per_suite(Config) ->
  {ok, _} = application:ensure_all_started(barrel_http),
  Config.

init_per_testcase(_, Config) ->
  {true, Conn} = barrel:create_database(testdb, <<"testdb">>),
  [{conn, Conn} |Config].

end_per_testcase(_, Config) ->
  Conn = proplists:get_value(conn, Config),
  ok = barrel:delete_database(Conn),
  Config.

end_per_suite(Config) ->
  catch erocksdb:destroy(<<"testdb">>), Config.

%% ----------

info_database(_Config) ->
  {200, R1} = req(get, "/testdb/testdb"),
  A1 = jsx:decode(R1, [return_maps]),
  <<"testdb">> = maps:get(<<"name">>, A1),
  %% TODO refactor
  %% {404, _} = req(get, "/unknwondb"),
  ok.

create_database(_Config) ->
  Cat = "{\"_id\": \"cat\", \"name\" : \"tom\"}",
  {400, _} = req(put, "/testdb/newdb/cat", Cat),
  {201, _} = req(put, "/testdb/newdb", []),
  {201, _} = req(put, "/testdb/newdb/cat", Cat),
  ok.

put_cat() ->
  Doc = "{\"_id\": \"cat\", \"name\" : \"tom\"}",
  {201, R} = req(put, "/testdb/testdb/cat", Doc),
  J = jsx:decode(R, [return_maps]),
  binary_to_list(maps:get(<<"rev">>, J)).


delete_cat(CatRevId) ->
  {200, R3} = req(delete, "/testdb/testdb/cat?rev=" ++ CatRevId),
  A3 = jsx:decode(R3, [return_maps]),
  true = maps:get(<<"ok">>, A3),
  A3.

put_dog() ->
  Doc = "{\"_id\": \"dog\", \"name\": \"spike\"}",
  {201, R} = req(put, "/testdb/testdb/dog", Doc),
  J = jsx:decode(R, [return_maps]),
  binary_to_list(maps:get(<<"rev">>, J)).

all_docs(_Config) ->
  {200, R1} = req(get, "/testdb/testdb/_all_docs"),
  A1 = jsx:decode(R1, [return_maps, {labels, attempt_atom}]),
  Rows1 = maps:get(rows, A1),
  0 = length(Rows1),

  put_cat(),
  DogRevId = put_dog(),

  {200, R2} = req(get, "/testdb/testdb/_all_docs"),
  A2 = jsx:decode(R2, [return_maps, {labels, attempt_atom}]),
  Rows2 = maps:get(rows, A2),
  2 = length(Rows2),
  Row = hd(Rows2),
  <<"dog">> = maps:get(id, Row),
  DogRevId = binary_to_list(maps:get(rev, Row)),
  ok.

system_doc(_Config) ->
  Doc = "{\"_id\": \"cat\", \"name\" : \"tom\"}",
  {201, _} = req(put, "/testdb/testdb/_system/cat", Doc),
  {200, R} = req(get, <<"/testdb/testdb/_system/cat">>),
  J = jsx:decode(R, [return_maps]),
  #{<<"name">> := <<"tom">>} = J,
  {200, _} = req(put, "/testdb/testdb/_system/cat", "{}"),
  ok.


%%=======================================================================

changes_normal(_Config) ->
  put_cat(),
  put_dog(),

  {200, R1} = req(get, "/testdb/testdb/_changes"),
  A1 = jsx:decode(R1, [return_maps]),
  2 = maps:get(<<"last_seq">>, A1),
  Results1 = maps:get(<<"results">>, A1),
  2 = length(Results1),

  {200, R2} = req(get, "/testdb/testdb/_changes?since=1"),
  A2 = jsx:decode(R2, [return_maps]),
  2 = maps:get(<<"last_seq">>, A2),
  Results2 = maps:get(<<"results">>, A2),
  1 = length(Results2),
  ok.

%%=======================================================================

changes_longpoll(_Config) ->
  Url = <<"http://localhost:8080/testdb/testdb/_changes?feed=longpoll">>,
  Opts = [async, {recv_timeout, infinity}],
  LoopFun = fun(Loop, Ref) ->
                receive
                  {hackney_response, Ref, {status, StatusInt, _Reason}} ->
                    200 = StatusInt,
                    Loop(Loop, Ref);
                  {hackney_response, Ref, {headers, _Headers}} ->
                    Loop(Loop, Ref);
                  {hackney_response, Ref, done} ->
                    ok;
                  {hackney_response, Ref, <<>>} ->
                    Loop(Loop, Ref);
                  {hackney_response, Ref, Bin} ->
                    R = jsx:decode(Bin,[return_maps]),
                    Results = maps:get(<<"results">>, R),
                    [_OnlyOneChange] = Results,
                    Loop(Loop, Ref);

                  Else ->
                    ct:fail("Unexpected answer from longpoll: ~p", [Else]),
                    ok
                after 2000 ->
                    {error, timeout}
                end
            end,
  {ok, ClientRef} = hackney:get(Url, [], <<>>, Opts),
  CatRevId = put_cat(),
  delete_cat(CatRevId),
  ok = LoopFun(LoopFun, ClientRef),
  {ok, ClientRef2} = hackney:get(Url, [], <<>>, Opts),
  ok=  LoopFun(LoopFun, ClientRef2).

changes_longpoll_heartbeat(_Config) ->
  {ok, Socket} = gen_tcp:connect({127,0,0,1}, 8080, [binary, {active,true}]),
  Request = ["GET /testdb/testdb/_changes?feed=longpoll&heartbeat=20 HTTP/1.1\r\n",
             "Host:localhost:8080\r\n",
             "Accept: application/json\r\n",
             "\r\n"],
  [ok = gen_tcp:send(Socket, L) || L <- Request],
  timer:sleep(100),
  CatRevId = put_cat(),
  delete_cat(CatRevId),
  LoopFun = fun(Loop,Acc) ->
                receive
                  {tcp,_,<<"HTTP/1.1", _/binary>>} ->
                    Loop(Loop, Acc);
                  {tcp,_,Data} ->
                    case Data of
                      <<"1\r\n\n\r\n">> ->
                        Loop(Loop, [heartbeat|Acc]);
                      Other ->
                        {ok, [Other|Acc]}
                    end;
                  {tcp_closed,_} ->
                    %% cowboy does not close connection
                    %% we dont expect to receive this one
                    {error, unexpected_connection_close};
                  Other ->
                    {error, {tcp, Other}}
                after 2000 ->
                    {error, timeout}
                end
            end,
  {ok, Data} = LoopFun(LoopFun, []),
  HeartBeats = tl(Data),
  true = length(HeartBeats) > 1,
  [heartbeat = H || H <- HeartBeats],
  ok.

%%=======================================================================

changes_eventsource(_Config) ->
  Self = self(),
  Pid = spawn(fun () -> wait_response([], 4, Self) end),
  Url = <<"http://localhost:8080/testdb/testdb/_changes?feed=eventsource">>,
  Opts = [async, {stream_to, Pid}],
  {ok, Ref} = hackney:get(Url, [], <<>>, Opts),
  CatRevId = put_cat(),
  delete_cat(CatRevId),
  receive
    {Ref, done} ->
      ct:fail(expected_more_data);
    {Msgs, received_as_expected} ->
      [[200, <<"OK">>], _Headers, _CatPut, _CatDelete] = Msgs
  after 2000 ->
      ct:fail(eventsource_timeout)
  end.

wait_response(Msgs, 0, Parent) ->
  Parent ! {lists:reverse(Msgs), received_as_expected};
wait_response(Msgs, Expected, Parent) ->
  N = Expected - 1,
  receive
    {hackney_response, _Ref, {status, StatusInt, Reason}} ->
      wait_response([[StatusInt,Reason]|Msgs], N, Parent);
    {hackney_response, _Ref, {headers, Headers}} ->
      wait_response([Headers|Msgs], N, Parent);
    {hackney_response, Ref, done} ->
      Parent ! {Ref, Msgs, done},
      ok;
    {hackney_response, _Ref, Bin} ->
      wait_response([Bin|Msgs], N, Parent);
    _Else ->
      ok
  end.

%%=======================================================================

req(Method, Route) ->
  req(Method,Route,[]).

req(Method, Route, Map) when is_map(Map) ->
  Body = jsx:encode(Map),
  req(Method, Route, Body);

req(Method, Route, String) when is_list(String) ->
  Body = list_to_binary(String),
  req(Method, Route, Body);

req(Method, Route, Body) when is_binary(Body) ->
  Server = "http://localhost:8080",
  Path = list_to_binary(Server ++ Route),
  Headers = [{<<"Content-Type">>, <<"application/json">>}],
  {ok, Code, _Headers, Ref} = hackney:request(Method, Path, Headers, Body, []),
  {ok, Answer} = hackney:body(Ref),
  {Code, Answer}.
