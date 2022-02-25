%%--------------------------------------------------------------------
%% Copyright (c) 2020-2022 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------
-module(emqx_bridge_api).

-behaviour(minirest_api).

-include_lib("typerefl/include/types.hrl").
-include_lib("emqx/include/logger.hrl").

-import(hoconsc, [mk/2, array/1, enum/1]).

%% Swagger specs from hocon schema
-export([ api_spec/0
        , paths/0
        , schema/1
        , namespace/0
        ]).

%% API callbacks
-export([ '/bridges'/2
        , '/bridges/:id'/2
        , '/bridges/:id/operation/:operation'/2
        ]).

-export([ lookup_from_local_node/2
        ]).

-define(TYPES, [mqtt, http]).

-define(CONN_TYPES, [mqtt]).

-define(TRY_PARSE_ID(ID, EXPR),
    try emqx_bridge:parse_bridge_id(Id) of
        {BridgeType, BridgeName} ->
            EXPR
    catch
        error:{invalid_bridge_id, Id0} ->
            {400, error_msg('INVALID_ID', <<"invalid_bridge_id: ", Id0/binary,
                ". Bridge Ids must be of format {type}:{name}">>)}
    end).

-define(METRICS(MATCH, SUCC, FAILED, RATE, RATE_5, RATE_MAX),
    #{  matched => MATCH,
        success => SUCC,
        failed => FAILED,
        rate => RATE,
        rate_last5m => RATE_5,
        rate_max => RATE_MAX
    }).
-define(metrics(MATCH, SUCC, FAILED, RATE, RATE_5, RATE_MAX),
    #{  matched := MATCH,
        success := SUCC,
        failed := FAILED,
        rate := RATE,
        rate_last5m := RATE_5,
        rate_max := RATE_MAX
    }).

namespace() -> "bridge".

api_spec() ->
    emqx_dashboard_swagger:spec(?MODULE, #{check_schema => false}).

paths() -> ["/bridges", "/bridges/:id", "/bridges/:id/operation/:operation"].

error_schema(Code, Message) when is_atom(Code) ->
    error_schema([Code], Message);
error_schema(Codes, Message) when is_list(Message) ->
    error_schema(Codes, list_to_binary(Message));
error_schema(Codes, Message) when is_list(Codes) andalso is_binary(Message) ->
    emqx_dashboard_swagger:error_codes(Codes, Message).

get_response_body_schema() ->
    emqx_dashboard_swagger:schema_with_examples(emqx_bridge_schema:get_response(),
        bridge_info_examples(get)).

param_path_operation() ->
    path_param(operation, enum([start, stop, restart]), <<"start">>).

param_path_id() ->
    path_param(id, binary(), <<"http:my_http_bridge">>).

path_param(Name, Type, Example) ->
    {Name, mk(Type,
        #{ in => path
         , required => true
         , example => Example
         })}.

bridge_info_array_example(Method) ->
    [Config || #{value := Config} <- maps:values(bridge_info_examples(Method))].

bridge_info_examples(Method) ->
    maps:merge(conn_bridge_examples(Method), #{
        <<"http_bridge">> => #{
            summary => <<"HTTP Bridge">>,
            value => info_example(http, awesome, Method)
        }
    }).

conn_bridge_examples(Method) ->
    lists:foldl(fun(Type, Acc) ->
            SType = atom_to_list(Type),
            KeyIngress = bin(SType ++ "_ingress"),
            KeyEgress = bin(SType ++ "_egress"),
            maps:merge(Acc, #{
                KeyIngress => #{
                    summary => bin(string:uppercase(SType) ++ " Ingress Bridge"),
                    value => info_example(Type, ingress, Method)
                },
                KeyEgress => #{
                    summary => bin(string:uppercase(SType) ++ " Egress Bridge"),
                    value => info_example(Type, egress, Method)
                }
            })
        end, #{}, ?CONN_TYPES).

info_example(Type, Direction, Method) ->
    maps:merge(info_example_basic(Type, Direction),
               method_example(Type, Direction, Method)).

method_example(Type, Direction, get) ->
    SType = atom_to_list(Type),
    SDir = atom_to_list(Direction),
    SName = case Type of
        http -> "my_" ++ SType ++ "_bridge";
        _ -> "my_" ++ SDir ++ "_" ++ SType ++ "_bridge"
    end,
    #{
        id => bin(SType ++ ":" ++ SName),
        type => bin(SType),
        name => bin(SName),
        metrics => ?METRICS(0, 0, 0, 0, 0, 0),
        node_metrics => [
            #{node => node(),
              metrics => ?METRICS(0, 0, 0, 0, 0, 0)}
        ]
    };
method_example(Type, Direction, post) ->
    SType = atom_to_list(Type),
    SDir = atom_to_list(Direction),
    SName = case Type of
        http -> "my_" ++ SType ++ "_bridge";
        _ -> "my_" ++ SDir ++ "_" ++ SType ++ "_bridge"
    end,
    #{
        type => bin(SType),
        name => bin(SName)
    };
method_example(_Type, _Direction, put) ->
    #{}.

info_example_basic(http, _) ->
    #{
        url => <<"http://localhost:9901/messages/${topic}">>,
        request_timeout => <<"15s">>,
        connect_timeout => <<"15s">>,
        max_retries => 3,
        retry_interval => <<"10s">>,
        pool_type => <<"random">>,
        pool_size => 4,
        enable_pipelining => true,
        ssl => #{enable => false},
        local_topic => <<"emqx_http/#">>,
        method => post,
        body => <<"${payload}">>
    };
info_example_basic(mqtt, ingress) ->
    #{
        connector => <<"mqtt:my_mqtt_connector">>,
        direction => ingress,
        remote_topic => <<"aws/#">>,
        remote_qos => 1,
        local_topic => <<"from_aws/${topic}">>,
        local_qos => <<"${qos}">>,
        payload => <<"${payload}">>,
        retain => <<"${retain}">>
    };
info_example_basic(mqtt, egress) ->
    #{
        connector => <<"mqtt:my_mqtt_connector">>,
        direction => egress,
        local_topic => <<"emqx/#">>,
        remote_topic => <<"from_emqx/${topic}">>,
        remote_qos => <<"${qos}">>,
        payload => <<"${payload}">>,
        retain => false
    }.

schema("/bridges") ->
    #{
        operationId => '/bridges',
        get => #{
            tags => [<<"bridges">>],
            summary => <<"List Bridges">>,
            description => <<"List all created bridges">>,
            responses => #{
                200 => emqx_dashboard_swagger:schema_with_example(
                        array(emqx_bridge_schema:get_response()),
                        bridge_info_array_example(get))
            }
        },
        post => #{
            tags => [<<"bridges">>],
            summary => <<"Create Bridge">>,
            description => <<"Create a new bridge">>,
            requestBody => emqx_dashboard_swagger:schema_with_examples(
                            emqx_bridge_schema:post_request(),
                            bridge_info_examples(post)),
            responses => #{
                201 => get_response_body_schema(),
                400 => error_schema('BAD_REQUEST', "Create bridge failed")
            }
        }
    };

schema("/bridges/:id") ->
    #{
        operationId => '/bridges/:id',
        get => #{
            tags => [<<"bridges">>],
            summary => <<"Get Bridge">>,
            description => <<"Get a bridge by Id">>,
            parameters => [param_path_id()],
            responses => #{
                200 => get_response_body_schema(),
                404 => error_schema('NOT_FOUND', "Bridge not found")
            }
        },
        put => #{
            tags => [<<"bridges">>],
            summary => <<"Update Bridge">>,
            description => <<"Update a bridge">>,
            parameters => [param_path_id()],
            requestBody => emqx_dashboard_swagger:schema_with_examples(
                            emqx_bridge_schema:put_request(),
                            bridge_info_examples(put)),
            responses => #{
                200 => get_response_body_schema(),
                404 => error_schema('NOT_FOUND', "Bridge not found"),
                400 => error_schema('BAD_REQUEST', "Update bridge failed")
            }
        },
        delete => #{
            tags => [<<"bridges">>],
            summary => <<"Delete Bridge">>,
            description => <<"Delete a bridge">>,
            parameters => [param_path_id()],
            responses => #{
                204 => <<"Bridge deleted">>
            }
        }
    };

schema("/bridges/:id/operation/:operation") ->
    #{
        operationId => '/bridges/:id/operation/:operation',
        post => #{
            tags => [<<"bridges">>],
            summary => <<"Start/Stop/Restart Bridge">>,
            description => <<"Start/Stop/Restart bridges on a specific node">>,
            parameters => [
                param_path_id(),
                param_path_operation()
            ],
            responses => #{
                500 => error_schema('INTERNAL_ERROR', "Operation Failed"),
                200 => <<"Operation success">>
            }
        }
    }.

'/bridges'(post, #{body := #{<<"type">> := BridgeType} = Conf0}) ->
    Conf = filter_out_request_body(Conf0),
    BridgeName = emqx_misc:gen_id(),
    case emqx_bridge:lookup(BridgeType, BridgeName) of
        {ok, _} ->
            {400, error_msg('ALREADY_EXISTS', <<"bridge already exists">>)};
        {error, not_found} ->
            case ensure_bridge_created(BridgeType, BridgeName, Conf) of
                ok -> lookup_from_all_nodes(BridgeType, BridgeName, 201);
                {error, Error} -> {400, Error}
            end
    end;
'/bridges'(get, _Params) ->
    {200, zip_bridges([[format_resp(Data) || Data <- emqx_bridge_proto_v1:list_bridges(Node)]
                       || Node <- mria_mnesia:running_nodes()])}.

'/bridges/:id'(get, #{bindings := #{id := Id}}) ->
    ?TRY_PARSE_ID(Id, lookup_from_all_nodes(BridgeType, BridgeName, 200));

'/bridges/:id'(put, #{bindings := #{id := Id}, body := Conf0}) ->
    Conf = filter_out_request_body(Conf0),
    ?TRY_PARSE_ID(Id,
        case emqx_bridge:lookup(BridgeType, BridgeName) of
            {ok, _} ->
                case ensure_bridge_created(BridgeType, BridgeName, Conf) of
                    ok ->
                        lookup_from_all_nodes(BridgeType, BridgeName, 200);
                    {error, Error} ->
                        {400, Error}
                end;
            {error, not_found} ->
                {404, error_msg('NOT_FOUND',<<"bridge not found">>)}
        end);

'/bridges/:id'(delete, #{bindings := #{id := Id}}) ->
    ?TRY_PARSE_ID(Id,
        case emqx_conf:remove(emqx_bridge:config_key_path() ++ [BridgeType, BridgeName],
                #{override_to => cluster}) of
            {ok, _} -> {204};
            {error, Reason} ->
                {500, error_msg('UNKNOWN_ERROR', Reason)}
        end).

lookup_from_all_nodes(BridgeType, BridgeName, SuccCode) ->
    Nodes = mria_mnesia:running_nodes(),
    case is_ok(emqx_bridge_proto_v1:lookup_from_all_nodes(Nodes, BridgeType, BridgeName)) of
        {ok, [{ok, _} | _] = Results} ->
            {SuccCode, format_bridge_info([R || {ok, R} <- Results])};
        {ok, [{error, not_found} | _]} ->
            {404, error_msg('NOT_FOUND', <<"not_found">>)};
        {error, ErrL} ->
            {500, error_msg('UNKNOWN_ERROR', ErrL)}
    end.

lookup_from_local_node(BridgeType, BridgeName) ->
    case emqx_bridge:lookup(BridgeType, BridgeName) of
        {ok, Res} -> {ok, format_resp(Res)};
        Error -> Error
    end.

'/bridges/:id/operation/:operation'(post, #{bindings :=
        #{id := Id, operation := Op}}) ->
    ?TRY_PARSE_ID(Id, case operation_to_conf_req(Op) of
        invalid -> {400, error_msg('BAD_REQUEST', <<"invalid operation">>)};
        UpReq ->
            case emqx_conf:update(emqx_bridge:config_key_path() ++ [BridgeType, BridgeName],
                    {UpReq, BridgeType, BridgeName}, #{override_to => cluster}) of
                {ok, _} -> {200};
                {error, {pre_config_update, _, bridge_not_found}} ->
                    {404, error_msg('NOT_FOUND', <<"bridge not found">>)};
                {error, Reason} ->
                    {500, error_msg('UNKNOWN_ERROR', Reason)}
            end
    end).

operation_to_conf_req(<<"start">>) -> start;
operation_to_conf_req(<<"stop">>) -> stop;
operation_to_conf_req(<<"restart">>) -> restart;
operation_to_conf_req(_) -> invalid.

ensure_bridge_created(BridgeType, BridgeName, Conf) ->
    case emqx_conf:update(emqx_bridge:config_key_path() ++ [BridgeType, BridgeName],
            Conf, #{override_to => cluster}) of
        {ok, _} -> ok;
        {error, Reason} ->
            {error, error_msg('BAD_REQUEST', Reason)}
    end.

zip_bridges([BridgesFirstNode | _] = BridgesAllNodes) ->
    lists:foldl(fun(#{id := Id}, Acc) ->
            Bridges = pick_bridges_by_id(Id, BridgesAllNodes),
            [format_bridge_info(Bridges) | Acc]
        end, [], BridgesFirstNode).

pick_bridges_by_id(Id, BridgesAllNodes) ->
    lists:foldl(fun(BridgesOneNode, Acc) ->
            case [Bridge || Bridge = #{id := Id0} <- BridgesOneNode, Id0 == Id] of
                [BridgeInfo] -> [BridgeInfo | Acc];
                [] ->
                    ?SLOG(warning, #{msg => "bridge_inconsistent_in_cluster", bridge => Id}),
                    Acc
            end
        end, [], BridgesAllNodes).

format_bridge_info([FirstBridge | _] = Bridges) ->
    Res = maps:remove(node, FirstBridge),
    NodeStatus = collect_status(Bridges),
    NodeMetrics = collect_metrics(Bridges),
    Res#{ status => aggregate_status(NodeStatus)
        , node_status => NodeStatus
        , metrics => aggregate_metrics(NodeMetrics)
        , node_metrics => NodeMetrics
        }.

collect_status(Bridges) ->
    [maps:with([node, status], B) || B <- Bridges].

aggregate_status(AllStatus) ->
    Head = fun ([A|_]) -> A end,
    HeadVal = Head(AllStatus),
    AllRes = lists:all(fun (#{status := Val}) -> Val == HeadVal end, AllStatus),
    case AllRes of
        true -> HeadVal;
        false -> inconsistent
    end.

collect_metrics(Bridges) ->
    [maps:with([node, metrics], B) || B <- Bridges].

aggregate_metrics(AllMetrics) ->
    InitMetrics = ?METRICS(0,0,0,0,0,0),
    lists:foldl(fun(#{metrics := ?metrics(Match1, Succ1, Failed1, Rate1, Rate5m1, RateMax1)},
                    ?metrics(Match0, Succ0, Failed0, Rate0, Rate5m0, RateMax0)) ->
            ?METRICS(Match1 + Match0, Succ1 + Succ0, Failed1 + Failed0,
                     Rate1 + Rate0, Rate5m1 + Rate5m0, RateMax1 + RateMax0)
        end, InitMetrics, AllMetrics).

format_resp(#{id := Id, raw_config := RawConf,
              resource_data := #{status := Status, metrics := Metrics}}) ->
    {Type, BridgeName} = emqx_bridge:parse_bridge_id(Id),
    RawConf#{
        id => Id,
        type => Type,
        name => maps:get(<<"name">>, RawConf, BridgeName),
        node => node(),
        status => Status,
        metrics => format_metrics(Metrics)
    }.

format_metrics(#{
        counters := #{failed := Failed, exception := Ex, matched := Match, success := Succ},
        rate := #{
            matched := #{current := Rate, last5m := Rate5m, max := RateMax}
        } }) ->
    ?METRICS(Match, Succ, Failed + Ex, Rate, Rate5m, RateMax).


is_ok(ResL) ->
    case lists:filter(fun({ok, _}) -> false; (_) -> true end, ResL) of
        [] -> {ok, [Res || {ok, Res} <- ResL]};
        ErrL -> {error, ErrL}
    end.

filter_out_request_body(Conf) ->
    ExtraConfs = [<<"id">>, <<"type">>, <<"status">>, <<"node_status">>,
        <<"node_metrics">>, <<"metrics">>, <<"node">>],
    maps:without(ExtraConfs, Conf).

error_msg(Code, Msg) when is_binary(Msg) ->
    #{code => Code, message => Msg};
error_msg(Code, Msg) ->
    #{code => Code, message => bin(io_lib:format("~p", [Msg]))}.

bin(S) when is_list(S) ->
    list_to_binary(S).
