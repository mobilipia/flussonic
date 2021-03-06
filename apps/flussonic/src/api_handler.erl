%%% @author     Max Lapshin <max@maxidoors.ru> [http://erlyvideo.org]
%%% @copyright  2010-2012 Max Lapshin
%%% @doc        api handler
%%% @reference  See <a href="http://erlyvideo.org" target="_top">http://erlyvideo.org</a> for more information
%%% @end
%%%
%%%
%%% This file is part of erlyvideo.
%%% 
%%% erlmedia is free software: you can redistribute it and/or modify
%%% it under the terms of the GNU General Public License as published by
%%% the Free Software Foundation, either version 3 of the License, or
%%% (at your option) any later version.
%%%
%%% erlmedia is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%% GNU General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with erlmedia.  If not, see <http://www.gnu.org/licenses/>.
%%%
%%%---------------------------------------------------------------------------------------
-module(api_handler).
-author('Max Lapshin <max@maxidoors.ru>').
-include("log.hrl").

-behaviour(cowboy_http_handler).
-export([init/3, handle/2, terminate/3]).
-export([websocket_init/3, websocket_handle/3,
    websocket_info/3, websocket_terminate/3]).
-include_lib("eunit/include/eunit.hrl").
-include("flu_event.hrl").
-include_lib("erlmedia/include/video_frame.hrl").
-include_lib("erlmedia/include/media_info.hrl").

-export([routes/1]).

routes(Options) ->
  [
    {"/", api_handler, [{mode,mainpage}|Options]},
    {"/admin", api_handler, [{mode,mainpage}|Options]},
    {"/erlyvideo/api/sendlogs", api_handler, [{mode,sendlogs}|Options]},
    {"/erlyvideo/api/reload", api_handler, [{mode,reload}|Options]},
    {"/erlyvideo/api/events", api_handler, [{mode,events}|Options]},
    {"/erlyvideo/api/streams", api_handler, [{mode,streams}|Options]},
    {"/erlyvideo/api/server", api_handler, [{mode,server}|Options]},
    {"/erlyvideo/api/sessions", api_handler, [{mode,sessions}|Options]},
    {"/erlyvideo/api/pulse", api_handler, [{mode,pulse}|Options]},
    {"/erlyvideo/api/stream_health/[...]", api_handler, [{mode,health}|Options]},
    {"/erlyvideo/api/stream_restart/[...]", api_handler, [{mode,stream_restart}|Options]},
    {"/erlyvideo/api/media_info/[...]", api_handler, [{mode,media_info}|Options]},
    {"/erlyvideo/api/dvr_status/:year/:month/:day/[...]", dvr_handler, [{mode,status}|Options]},
    {"/erlyvideo/api/dvr_previews/:year/:month/:day/:hour/:minute/[...]", dvr_handler, [{mode,previews}|Options]}
  ].




%% Cowboy API

to_lower(undefined) -> undefined;
to_lower(Bin) -> cowboy_bstr:to_lower(Bin).

init({_Any,http}, Req, Opts) ->
  {Upgrade, Req1} = cowboy_req:header(<<"upgrade">>, Req),
  case to_lower(Upgrade) of
    <<"websocket">> ->
      % check_auth(Req, Opts, http_auth, init, fun() ->
        {upgrade, protocol, cowboy_websocket}
      % end)
      ;
    undefined ->
      Mode = proplists:get_value(mode, Opts),
      {ok, Req1, {Mode,Opts}}
  end.

handle(Req, {reload, Opts}) ->
  check_auth(Req, Opts, admin, fun() -> 
    {ok, R1} = cowboy_req:reply(200, [{<<"Content-Type">>, <<"application/json">>}], "true\n", Req),
    spawn(fun() -> flu:reconf() end),
    {ok, R1, undefined}
  end);

handle(Req, {events, _Opts}) ->
  {Accept, _Req1} = cowboy_req:header(<<"accept">>, Req),
  case Accept of
    <<"text/event-stream">> ->
      % FIXME: migrate to loop handler
      [Transport, Socket] = cowboy_req:get([transport, socket], Req),
      is_port(Socket) andalso inet:setopts(Socket, [{send_timeout,10000}]),
      Transport:send(Socket, "HTTP 200 OK\r\nConnection: keep-alive\r\n"
        "Cache-Control: no-cache\r\nContent-Type: text/event-stream\r\n\r\n"),
      flu_event:subscribe_to_events(self()),
      events_sse_loop(Transport,Socket);
    _ ->
    {ok, R1} = cowboy_req:reply(400, [], "Should use SSE or WebSockets\n", Req),
    {ok, R1, undefined}
  end;


handle(Req, {mainpage, Opts}) ->
  check_auth(Req, Opts, http_auth, fun() ->
    case file:read_file("priv/index.html") of
      {ok, HTML} ->
        {ok, R1} = cowboy_req:reply(200, [{<<"Content-Type">>, <<"text/html">>}], HTML, Req),
        {ok, R1, undefined};
      {error, enoent} ->
        {ok, R1} = cowboy_req:reply(404, [{<<"Content-Type">>, <<"text/plain">>}], "not found\n", Req),
        {ok, R1, undefined}
    end
  end);

handle(Req, {server, Opts}) ->
  check_auth(Req, Opts, http_auth, fun() ->
    {ok, R1} = cowboy_req:reply(200, [{<<"Content-Type">>, <<"application/json">>}], [mochijson2:encode(flu:json_info()), "\n"], Req),
    {ok, R1, undefined}
  end);

handle(Req, {sessions, Opts}) ->
  check_auth(Req, Opts, http_auth, fun() ->
    {Name, Req1} = cowboy_req:qs_val(<<"name">>,Req),
    List = case Name of
      undefined -> flu_session:json_list();
      _ -> flu_session:json_list(Name)
    end,
    {ok, R1} = cowboy_req:reply(200, [{<<"Content-Type">>, <<"application/json">>}], [mochijson2:encode(List), "\n"], Req1),
    {ok, R1, undefined}
  end);


handle(Req, {sendlogs, Opts}) ->
  check_auth(Req, Opts, http_auth, fun() ->
    case log_uploader:upload() of
      {ok, Ticket} ->
        lager:warning("Logs were uploaded to erlyvideo.org with ticket ~s", [Ticket]),
        {ok, R1} = cowboy_req:reply(200, [{<<"Content-Type">>, <<"application/json">>}], [mochijson2:encode([{ticket,Ticket}]), "\n"], Req),
        {ok, R1, undefined};
      {error, Error} ->
        lager:warning("Problem with uploading logs to erlyvideo.org: ~p", [Error]),
        {ok, R1} = cowboy_req:reply(200, [{<<"Content-Type">>, <<"application/json">>}], [mochijson2:encode([{error,Error}]), "\n"], Req),
        {ok, R1, undefined}
    end
  end);


handle(Req, {pulse, Opts}) ->
  check_auth(Req, Opts, http_auth, fun() ->
    {ok, R1} = cowboy_req:reply(200, [{<<"Content-Type">>, <<"application/json">>}], [mochijson2:encode(pulse:json_list()), "\n"], Req),
    {ok, R1, undefined}
  end);


handle(Req, {streams, Opts}) ->
  check_auth(Req, Opts, http_auth, fun() ->
    {ok, R1} = cowboy_req:reply(200, [{<<"Content-Type">>, <<"application/json">>}], [mochijson2:encode(flu_stream:json_list()), "\n"], Req),
    {ok, R1, undefined}
  end);


handle(Req, {stream_restart, Opts}) ->
  check_auth(Req, Opts, admin, fun() -> 
    {PathInfo, _} = cowboy_req:path_info(Req),
    Name = flu:join(PathInfo, "/"),
    case flu_stream:find(Name) of
      {ok, Pid} ->
        erlang:exit(Pid, shutdown),
        {ok, R1} = cowboy_req:reply(200, [{<<"Content-Type">>, <<"application/json">>}], "true\n", Req),
        {ok, R1, undefined};
      _ ->
        {ok, R1} = cowboy_req:reply(200, [{<<"Content-Type">>, <<"application/json">>}], "false\n", Req),
        {ok, R1, undefined}
    end
  end);

handle(Req, {media_info, Opts}) ->
  check_auth(Req, Opts, http_auth, fun() ->
    {PathInfo, _} = cowboy_req:path_info(Req),
    Name = flu:join(PathInfo, "/"),

    case flu_media:find_or_open(Name) of
      {ok, {Type, Pid}} ->
        MediaInfo = case Type of
          file -> flu_file:media_info(Pid);
          stream -> flu_stream:media_info(Pid)
        end,
        case MediaInfo of
          #media_info{} ->
            JSON = video_frame:media_info_to_json(MediaInfo),
            {ok, R1} = cowboy_req:reply(200, [{<<"Content-Type">>, <<"application/json">>}], [mochijson2:encode(JSON), "\n"], Req),
            {ok, R1, undefined};
          _ ->
            {ok, R1} = cowboy_req:reply(404, [], <<"undefined\n">>, Req),
            {ok, R1, undefined}
        end;
      {error, _} ->
        {ok, R1} = cowboy_req:reply(404, [], <<"undefined\n">>, Req),
        {ok, R1, undefined}
    end
  end);



handle(Req, {health, Opts}) ->
  check_auth(Req, Opts, http_auth, fun() ->
    {PathInfo, _} = cowboy_req:path_info(Req),
    Name = flu:join(PathInfo, "/"),
    StreamInfo = proplists:get_value(Name, flu_stream:list(), []),
    Delay = proplists:get_value(ts_delay, StreamInfo),
    Limit = 5000,
    {ok, R1} = if
      is_number(Delay) andalso Delay < Limit ->
        cowboy_req:reply(200, [{<<"Content-Type">>, <<"application/json">>}], <<"true\n">>, Req);
      true ->
        cowboy_req:reply(412, [{<<"Content-Type">>, <<"application/json">>}], <<"false\n">>, Req)
    end,
    {ok, R1, undefined}
  end).

terminate(_,_,_) -> ok.


events_sse_loop(Transport, Socket) ->
  receive
    #flu_event{event = Evt} = Event ->
      Cmd = io_lib:format("event: ~s\ndata: ~s\n\n", [Evt, flu_event:to_json(Event)]),
      case Transport:send(Socket, Cmd) of
        ok -> ok;
        {error, _} -> exit(normal)
      end;
    Else ->
      ?D({unknown_message, Else})
  end,
  events_sse_loop(Transport,Socket).


websocket_init(_TransportName, Req, Opts) ->
  Mode = proplists:get_value(mode, Opts),
  case Mode of
    events -> flu_event:subscribe_to_events(self());
    _ -> ok
  end,
  {ok, Req, {Mode,Opts}}.

websocket_handle({text, <<"pulse">>}, Req, State) ->
  JSON = iolist_to_binary(mochijson2:encode(pulse:json_list())),
  {reply, {text,JSON}, Req, State};

websocket_handle({text, <<"streams">>}, Req, State) ->
  JSON = iolist_to_binary(mochijson2:encode(flu_stream:json_list())),
  {reply, {text,JSON}, Req, State};

websocket_handle({text, <<"server">>}, Req, State) ->
  JSON = iolist_to_binary(mochijson2:encode(flu:json_info())),
  {reply, {text,JSON}, Req, State};

websocket_handle({text, <<"sessions">>}, Req, State) ->
  JSON = iolist_to_binary(mochijson2:encode(flu_session:json_list())),
  {reply, {text,JSON}, Req, State};

websocket_handle({text, <<"sessions?name=", Name/binary>>}, Req, State) ->
  JSON = iolist_to_binary(mochijson2:encode(flu_session:json_list(Name))),
  {reply, {text,JSON}, Req, State};

websocket_handle(_Data, Req, State) ->
  {ok, Req, State}.

websocket_info(#flu_event{} = Event, Req, State) ->
  {reply, {text, flu_event:to_json(Event)}, Req, State};

websocket_info(_Info, Req, State) ->
  lager:info("api_websocket msg: ~p~n", [_Info]),
  {ok, Req, State}.


websocket_terminate(_Reason, _Req, _State) -> ok.



check_auth(Req, Opts, Class, Fun) ->
  check_auth(Req, Opts, Class, handle, Fun).
  

check_auth(Req, Opts, Class, Caller, Fun) ->
  case lists:keyfind(Class, 1, Opts) of
    {Class, Login, Password} ->
      check_password(Req, Login, Password, Caller, Fun);
    false ->
      case lists:keyfind(auth, 1, Opts) of
        {auth, Login, Password} -> check_password(Req, Login, Password, Caller, Fun);
        false -> Fun()
      end
  end.
      
check_password(Req, Login, Password, Caller, Fun) ->
  {Auth, Req1} = cowboy_req:header(<<"authorization">>, Req),
  GoodAuth = iolist_to_binary(["Basic ", base64:encode_to_string(Login++":"++Password)]),
  if Auth == GoodAuth -> Fun();
  true -> 
    {ok, Req2} = cowboy_req:reply(401, [{<<"Www-Authenticate">>, <<"Basic realm=Flussonic">>}], "401 Forbidden\n", Req1),
    case Caller of
      handle -> {ok, Req2, undefined};
      init -> {shutdown, Req2, undefined}
    end
  end.






