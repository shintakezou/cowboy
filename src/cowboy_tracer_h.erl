%% Copyright (c) 2017, Loïc Hoguin <essen@ninenines.eu>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

-module(cowboy_tracer_h).
-behavior(cowboy_stream).

-export([init/3]).
-export([data/4]).
-export([info/3]).
-export([terminate/3]).
-export([early_error/5]).

-export([tracer_process/3]).
-export([system_continue/3]).
-export([system_terminate/4]).
-export([system_code_change/4]).

-type match_predicate()
	:: fun((cowboy_stream:streamid(), cowboy_req:req(), cowboy:opts()) -> boolean()).

-type tracer_match_specs() :: [match_predicate()
	| {method, binary()}
	| {host, binary()}
	| {path, binary()}
	| {path_start, binary()}
	| {header, binary()}
	| {header, binary(), binary()}
	| {peer_ip, inet:ip_address()}
].
-export_type([tracer_match_specs/0]).

-spec init(cowboy_stream:streamid(), cowboy_req:req(), cowboy:opts())
	-> {cowboy_stream:commands(), any()}.
init(StreamID, Req, Opts) ->
	Result = init_tracer(StreamID, Req, Opts),
	{Commands, Next} = cowboy_stream:init(StreamID, Req, Opts),
	case Result of
		no_tracing -> {Commands, Next};
		{tracing, TracerPid} -> {[{spawn, TracerPid, 5000}|Commands], Next}
	end.

-spec data(cowboy_stream:streamid(), cowboy_stream:fin(), cowboy_req:resp_body(), State)
	-> {cowboy_stream:commands(), State} when State::any().
data(StreamID, IsFin, Data, Next) ->
	cowboy_stream:data(StreamID, IsFin, Data, Next).

-spec info(cowboy_stream:streamid(), any(), State)
	-> {cowboy_stream:commands(), State} when State::any().
info(StreamID, Info, Next) ->
	cowboy_stream:info(StreamID, Info, Next).

-spec terminate(cowboy_stream:streamid(), cowboy_stream:reason(), any()) -> any().
terminate(StreamID, Reason, Next) ->
	cowboy_stream:terminate(StreamID, Reason, Next).

-spec early_error(cowboy_stream:streamid(), cowboy_stream:reason(),
	cowboy_stream:partial_req(), Resp, cowboy:opts()) -> Resp
	when Resp::cowboy_stream:resp_command().
early_error(StreamID, Reason, PartialReq, Resp, Opts) ->
	cowboy_stream:early_error(StreamID, Reason, PartialReq, Resp, Opts).

%% Internal.

init_tracer(StreamID, Req, Opts=#{tracer_match_specs := List, tracer_callback := _}) ->
	case match(List, StreamID, Req, Opts) of
		false ->
			no_tracing;
		true ->
			start_tracer(StreamID, Req, Opts)
	end;
%% When the options tracer_match_specs or tracer_callback
%% are not provided we do not enable tracing.
init_tracer(_, _, _) ->
	no_tracing.

match([], _, _, _) ->
	true;
match([Predicate|Tail], StreamID, Req, Opts) when is_function(Predicate) ->
	case Predicate(StreamID, Req, Opts) of
		true -> match(Tail, StreamID, Req, Opts);
		false -> false
	end;
match([{method, Value}|Tail], StreamID, Req=#{method := Value}, Opts) ->
	match(Tail, StreamID, Req, Opts);
match([{host, Value}|Tail], StreamID, Req=#{host := Value}, Opts) ->
	match(Tail, StreamID, Req, Opts);
match([{path, Value}|Tail], StreamID, Req=#{path := Value}, Opts) ->
	match(Tail, StreamID, Req, Opts);
match([{path_start, PathStart}|Tail], StreamID, Req=#{path := Path}, Opts) ->
	Len = byte_size(PathStart),
	case Path of
		<<PathStart:Len/binary, _/bits>> -> match(Tail, StreamID, Req, Opts);
		_ -> false
	end;
match([{header, Name}|Tail], StreamID, Req=#{headers := Headers}, Opts) ->
	case Headers of
		#{Name := _} -> match(Tail, StreamID, Req, Opts);
		_ -> false
	end;
match([{header, Name, Value}|Tail], StreamID, Req=#{headers := Headers}, Opts) ->
	case Headers of
		#{Name := Value} -> match(Tail, StreamID, Req, Opts);
		_ -> false
	end;
match([{peer_ip, IP}|Tail], StreamID, Req=#{peer := {IP, _}}, Opts) ->
	match(Tail, StreamID, Req, Opts);
match(_, _, _, _) ->
	false.

%% We only start the tracer if one wasn't started before.
start_tracer(StreamID, Req, Opts) ->
	case erlang:trace_info(self(), tracer) of
		{tracer, []} ->
			TracerPid = proc_lib:spawn_link(?MODULE, tracer_process, [StreamID, Req, Opts]),
			erlang:trace_pattern({'_', '_', '_'}, [{'_', [], [{return_trace}]}], [local]),
			erlang:trace_pattern(on_load, [{'_', [], [{return_trace}]}], [local]),
			erlang:trace(self(), true, [
				send, 'receive', call, return_to, procs, ports,
				monotonic_timestamp, set_on_spawn, {tracer, TracerPid}
			]),
			{tracing, TracerPid};
		_ ->
			no_tracing
	end.

%% Tracer process.

-spec tracer_process(_, _, _) -> no_return().
tracer_process(StreamID, Req=#{pid := Parent}, Opts=#{tracer_callback := Fun}) ->
	%% This is necessary because otherwise the tracer could stop
	%% before it has finished processing the events in its queue.
	process_flag(trap_exit, true),
	State = Fun(init, {StreamID, Req, Opts}),
	tracer_loop(Parent, Fun, State).

tracer_loop(Parent, Fun, State0) ->
	receive
		Msg when element(1, Msg) =:= trace_ts ->
			State = Fun(Msg, State0),
			tracer_loop(Parent, Fun, State);
		{'EXIT', Parent, Reason} ->
			tracer_terminate(Reason, Fun, State0);
		{system, From, Request} ->
			sys:handle_system_msg(Request, From, Parent, ?MODULE, [], {Fun, State0});
		Msg ->
			error_logger:error_msg("~p: Tracer process received stray message ~9999p~n",
				[?MODULE, Msg]),
			tracer_loop(Parent, Fun, State0)
	end.

tracer_terminate(Reason, Fun, State) ->
	_ = Fun(terminate, State),
	exit(Reason).

%% System callbacks.

-spec system_continue(pid(), _, {fun(), any()}) -> no_return().
system_continue(Parent, _, {Fun, State}) ->
	tracer_loop(Parent, Fun, State).

-spec system_terminate(any(), _, _, _) -> no_return().
system_terminate(Reason, _, _, {Fun, State}) ->
	tracer_terminate(Reason, Fun, State).

-spec system_code_change(Misc, _, _, _) -> {ok, Misc} when Misc::any().
system_code_change(Misc, _, _, _) ->
	{ok, Misc}.
