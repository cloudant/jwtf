%%%-------------------------------------------------------------------
%% @doc epep top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(jwtf_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
    Children = [child(jwks)],
    {ok, { {one_for_all, 5, 10}, Children} }.

%%====================================================================
%% Internal functions
%%====================================================================

child(Child) ->
    {Child, {Child, start_link, []}, permanent, 1000, worker, [Child]}.
