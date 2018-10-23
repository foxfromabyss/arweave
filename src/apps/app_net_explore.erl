-module(app_net_explore).
-export([graph/0, graph/1]).
-export([get_all_nodes/0, get_live_nodes/0]).
-export([filter_offline_nodes/1]).
-export([get_nodes_connectivity/0]).
-export([generate_gephi_csv/0]).
-export([get_peers_clock_diff/0]).

-export([get_peers_clock_diff/1]).

%%% Tools for building a map of connected peers.
%%% Requires graphviz for visualisation.

%% The directory generated files should be saved to.
-define(OUTPUT_DIR, "net-explore-output").

%% @doc Build a snapshot graph in PNG form of the current state of the network.
graph() ->
    io:format("Getting live peers...~n"),
    graph(get_live_nodes()).
graph(Nodes) ->
    io:format("Generating connection map...~n"),
    Map = generate_map(Nodes),
    ar:d(Map),
    io:format("Generating dot file...~n"),
    Timestamp = erlang:timestamp(),
    DotFile = filename(Timestamp, "graph", "dot"),
    ok = filelib:ensure_dir(DotFile),
    PngFile = filename(Timestamp, "graph", "png"),
    ok = filelib:ensure_dir(PngFile),
    ok = generate_dot_file(DotFile, Map),
    io:format("Generating PNG image...~n"),
    os:cmd("dot -Tpng " ++ DotFile ++ " -o " ++ PngFile),
    io:format("Done! Image written to: '" ++ PngFile ++ "'~n").


%% @doc Return a list of nodes that are active and connected to the network.
get_live_nodes() ->
    filter_offline_nodes(get_all_nodes()).

%% @doc Return a list of all nodes that are claimed to be in the network.
get_all_nodes() ->
    get_all_nodes([], ar_bridge:get_remote_peers(whereis(http_bridge_node))).
get_all_nodes(Acc, []) -> Acc;
get_all_nodes(Acc, [Peer|Peers]) ->
    io:format("Getting peers from ~s... ", [ar_util:format_peer(Peer)]),
    MorePeers = ar_http_iface:get_peers(Peer),
    io:format(" got ~w!~n", [length(MorePeers)]),
    get_all_nodes(
        [Peer|Acc],
        (ar_util:unique(Peers ++ MorePeers)) -- [Peer|Acc]
    ).

%% @doc Remove offline nodes from a list of peers.
filter_offline_nodes(Peers) ->
    lists:filter(
        fun(Peer) ->
            ar_http_iface:get_info(Peer) =/= info_unavailable
        end,
        Peers
    ).

%% @doc Return a three-tuple with every live host in the network, it's average
%% position by peers connected to it, the number of peers connected to it.
get_nodes_connectivity() ->
    nodes_connectivity(generate_map(get_live_nodes())).

%% @doc Create a CSV file with all connections in the network suitable for
%% importing into Gephi - The Open Graph Viz Platform (https://gephi.org/). The
%% weight is based on the Wildfire ranking.
generate_gephi_csv() ->
    generate_gephi_csv(get_live_nodes()).

get_peers_clock_diff() ->
    get_peers_clock_diff(get_all_nodes()).

%% @doc Return a map of every peers connections.
%% Returns a list of tuples with arity 2. The first element is the local peer,
%% the second element is the list of remote peers it talks to.
generate_map(Peers) ->
    lists:map(
        fun(Peer) ->
            {
                Peer,
                lists:filter(
                    fun(RemotePeer) ->
                        lists:member(RemotePeer, Peers)
                    end,
                    ar_http_iface:get_peers(Peer)
                )
            }
        end,
        Peers
    ).

%% @doc Generate a filename with path for storing files generated by this module.
filename(Type, Extension) ->
    filename(erlang:timestamp(), Type, Extension).

filename(Timestamp, Type, Extension) ->
    {{Year, Month, Day}, {Hour, Minute, Second}} =
        calendar:now_to_datetime(Timestamp),
    StrTime =
        lists:flatten(
            io_lib:format(
                "~4..0w-~2..0w-~2..0wT~2..0w:~2..0w:~2..0w",
                [Year, Month, Day, Hour, Minute, Second]
            )
        ),
    lists:flatten(
        io_lib:format(
            "~s/~s-~s.~s",
            [?OUTPUT_DIR, Type, StrTime, Extension]
        )
    ).

%% @doc Generate a dot file that can be rendered into a PNG.
generate_dot_file(File, Map) ->
    case file:open(File, [write]) of
        {ok, IoDevice} ->
            io:fwrite(IoDevice, "digraph network_map { ~n", []),
            io:fwrite(IoDevice,
                      "    init [style=filled,color=\".7 .3 .9\"];~n", []),
            do_generate_dot_file(Map, IoDevice),
            ok;
        _ ->
            io:format("Failed to open file for writing.~n"),
            io_error
    end.

do_generate_dot_file([], File) ->
    io:fwrite(File, "} ~n", []),
    file:close(File);
do_generate_dot_file([Host|Rest], File) ->
    {IP, Peers} = Host,
    lists:foreach(
        fun(Peer) ->
            io:fwrite(
                File,
                "\t\"~s\"  ->  \"~s\";  ~n",
                [ar_util:format_peer(IP), ar_util:format_peer(Peer)])
        end,
        Peers
    ),
    do_generate_dot_file(Rest, File).

%% @doc Takes a host-to-connections map and returns a three-tuple with every
%% live host in the network, it's average position by peers connected to it, the
%% number of peers connected to it.
nodes_connectivity(ConnectionMap) ->
    WithoutScore = [{Host, empty_score} || {Host, _} <- ConnectionMap],
    WithoutScoreMap = maps:from_list(WithoutScore),
    WithScoreMap = avg_connectivity_score(add_connectivity_score(WithoutScoreMap,
                                                                 ConnectionMap)),
    WithScore = [{Host, SumPos, Count} || {Host, {SumPos, Count}}
                                          <- maps:to_list(WithScoreMap)],
    lists:keysort(2, WithScore).

%% @doc Updates the connectivity intermediate scores according the connection
%% map.
add_connectivity_score(ScoreMap, []) ->
    ScoreMap;
add_connectivity_score(ScoreMap, [{_, Connections} | ConnectionMap]) ->
    NewScoreMap = add_connectivity_score1(ScoreMap, add_list_position(Connections)),
    add_connectivity_score(NewScoreMap, ConnectionMap).

%% @doc Updates the connectivity scores according the connection map.
add_connectivity_score1(ScoreMap, []) ->
    ScoreMap;
add_connectivity_score1(ScoreMap, [{Host, Position} | Connections]) ->
    Updater = fun
        (empty_score) ->
            {Position, 1};
        ({PositionSum, Count}) ->
            {PositionSum + Position, Count + 1}
    end,
    NewScoreMap = maps:update_with(Host, Updater, ScoreMap),
    add_connectivity_score1(NewScoreMap, Connections).

%% @doc Wraps each element in the list in a two-tuple where the second element
%% is the element's position in the list.
add_list_position(List) ->
    add_list_position(List, 1, []).

add_list_position([], _, Acc) ->
    lists:reverse(Acc);
add_list_position([Item | List], Position, Acc) ->
    NewAcc = [{Item, Position} | Acc],
    add_list_position(List, Position + 1, NewAcc).

%% @doc Replace the intermediate score (the sum of all positions and the number
%% of connections) with the average position and the number of connections.
avg_connectivity_score(Hosts) ->
    Mapper = fun (_, {PositionSum, Count}) ->
        {PositionSum / Count, Count}
    end,
    maps:map(Mapper, Hosts).

%% @doc Like generate_gephi_csv/0 but takes a list of the nodes to use in the
%% export.
generate_gephi_csv(Nodes) ->
    generate_gephi_csv1(generate_map(Nodes)).

%% @doc Like generate_gephi_csv/0 but takes the host-to-peers map to use in the
%% export.
generate_gephi_csv1(Map) ->
    {IoDevice, File} = create_gephi_file(),
    write_gephi_csv_header(IoDevice),
    write_gephi_csv_rows(gephi_edges(Map), IoDevice),
    ok = file:close(IoDevice),
    io:format("Gephi CSV file written to: '" ++ File ++ "'~n").

%% @doc Create the new CSV file in write mode and return the IO device and the
%% filename.
create_gephi_file() ->
    CsvFile = filename("gephi", "csv"),
    ok = filelib:ensure_dir(CsvFile),
    {ok, IoDevice} = file:open(CsvFile, [write]),
    {IoDevice, CsvFile}.

%% @doc Write the CSV header line to the IO device.
write_gephi_csv_header(IoDevice) ->
    Header = <<"Source,Target,Weight\n">>,
    ok = file:write(IoDevice, Header).

%% @doc Transform the host to peers map into a list of all connections where
%% each connection is a three-tuple of host, peer, weight.
gephi_edges(Map) ->
    gephi_edges(Map, []).

gephi_edges([], Acc) ->
    Acc;
gephi_edges([{Host, Peers} | Map], Acc) ->
    PeersWithPosition = add_list_position(Peers),
    Folder = fun ({Peer, Position}, FolderAcc) ->
        [{Host, Peer, 1 / Position} | FolderAcc]
    end,
    NewAcc = lists:foldl(Folder, Acc, PeersWithPosition),
    gephi_edges(Map, NewAcc).

%% @doc Write the list of connections to the IO device.
write_gephi_csv_rows([], _) ->
    done;
write_gephi_csv_rows([Edge | Edges], IoDevice) ->
    {Host, Peer, Weight} = Edge,
    Row = io_lib:format("~s,~s,~f\n", [ar_util:format_peer(Host),
                                       ar_util:format_peer(Peer),
                                       Weight]),
    ok = file:write(IoDevice, Row),
    write_gephi_csv_rows(Edges, IoDevice).

get_peers_clock_diff(Peers) ->
    [{Peer, get_peer_clock_diff(Peer)} || Peer <- Peers].

get_peer_clock_diff(Peer) ->
    Start = os:system_time(second),
    PeerTime = ar_http_iface:get_time(Peer),
    End = os:system_time(second),
    peer_clock_diff(Start, PeerTime, End).

peer_clock_diff(_, unknown, _) ->
    unknown;
peer_clock_diff(CheckStart, PeerTime, _) when PeerTime < CheckStart ->
    PeerTime - CheckStart;
peer_clock_diff(_, PeerTime, CheckEnd) when PeerTime > CheckEnd ->
    PeerTime - CheckEnd;
peer_clock_diff(_, _, _) ->
    0.
