%%--------------------------------------------------------------------
%% Copyright (C) 2020-2021 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_lwm2m_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-define(PORT, 5783).

-define(LOGT(Format, Args), ct:pal("TEST_SUITE: " ++ Format, Args)).

-include_lib("emqx_gateway/src/lwm2m/include/emqx_lwm2m.hrl").
-include_lib("lwm2m_coap/include/coap.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-define(CONF_DEFAULT, <<"
gateway.lwm2m {
  xml_dir = \"../../lib/emqx_gateway/src/lwm2m/lwm2m_xml\"
  lifetime_min = 1s
  lifetime_max = 86400s
  qmode_time_windonw = 22
  auto_observe = false
  mountpoint = \"lwm2m\"
  update_msg_publish_condition = contains_object_list
  translators {
    command = {topic = \"dn/#\", qos = 0}
    response = {topic = \"up/resp\", qos = 0}
    notify = {topic = \"up/notify\", qos = 0}
    register = {topic = \"up/resp\", qos = 0}
    update = {topic = \"up/resp\", qos = 0}
  }
  listeners.udp.default {
    bind = 5783
  }
}
">>).

%%--------------------------------------------------------------------
%% Setups
%%--------------------------------------------------------------------

all() ->
    [ {group, test_grp_0_register}
    , {group, test_grp_1_read}
    , {group, test_grp_2_write}
    , {group, test_grp_create}
    , {group, test_grp_delete}
    , {group, test_grp_3_execute}
    , {group, test_grp_4_discover}
    , {group, test_grp_5_write_attr}
    , {group, test_grp_6_observe}

      %% {group, test_grp_8_object_19}
      %% {group, test_grp_9_psm_queue_mode}
    ].

suite() -> [{timetrap, {seconds, 90}}].

groups() ->
    RepeatOpt = {repeat_until_all_ok, 1},
    [
        {test_grp_0_register, [RepeatOpt],
         [
          case01_register,
          case01_register_additional_opts,
          %% case01_register_incorrect_opts, %% TODO now we can't handle partial decode packet
          case01_register_report,
          case02_update_deregister,
          case03_register_wrong_version,
          case04_register_and_lifetime_timeout,
          case05_register_wrong_epn,
          %% case06_register_wrong_lifetime, %% now, will ignore wrong lifetime
          case07_register_alternate_path_01,
          case07_register_alternate_path_02,
          case08_reregister
         ]},
     {test_grp_1_read, [RepeatOpt],
      [
       case10_read,
       case10_read_separate_ack,
       case11_read_object_tlv,
       case11_read_object_json,
       case12_read_resource_opaque,
       case13_read_no_xml
      ]},
     {test_grp_2_write, [RepeatOpt],
      [
       case20_write,
       case21_write_object,
       case22_write_error,
       case20_single_write
      ]},
     {test_grp_create, [RepeatOpt],
      [
       case_create_basic
      ]},
     {test_grp_delete, [RepeatOpt],
      [
       case_delete_basic
      ]},
     {test_grp_3_execute, [RepeatOpt],
      [
       case30_execute, case31_execute_error
      ]},
     {test_grp_4_discover, [RepeatOpt],
      [
       case40_discover
      ]},
     {test_grp_5_write_attr, [RepeatOpt],
      [
       case50_write_attribute
      ]},
     {test_grp_6_observe, [RepeatOpt],
      [
       case60_observe
      ]},
     {test_grp_7_block_wize_transfer, [RepeatOpt],
      [
       case70_read_large, case70_write_large
      ]},
     {test_grp_8_object_19, [RepeatOpt],
      [
       case80_specail_object_19_1_0_write,
       case80_specail_object_19_0_0_notify,
       case80_specail_object_19_0_0_response,
       case80_normal_object_19_0_0_read
       ]},
     {test_grp_9_psm_queue_mode, [RepeatOpt],
      [
       case90_psm_mode,
       case90_queue_mode
      ]}
    ].

init_per_suite(Config) ->
    emqx_ct_helpers:start_apps([emqx_authn]),
    Config.

end_per_suite(Config) ->
    timer:sleep(300),
    emqx_ct_helpers:stop_apps([emqx_authn]),
    Config.

init_per_testcase(_AllTestCase, Config) ->
    ok = emqx_config:init_load(emqx_gateway_schema, ?CONF_DEFAULT),
    {ok, _} = application:ensure_all_started(emqx_gateway),
    {ok, ClientUdpSock} = gen_udp:open(0, [binary, {active, false}]),

    {ok, C} = emqtt:start_link([{host, "localhost"},{port, 1883},{clientid, <<"c1">>}]),
    {ok, _} = emqtt:connect(C),
    timer:sleep(100),

    [{sock, ClientUdpSock}, {emqx_c, C} | Config].

end_per_testcase(_AllTestCase, Config) ->
    timer:sleep(300),
    gen_udp:close(?config(sock, Config)),
    emqtt:disconnect(?config(emqx_c, Config)),
    ok = application:stop(emqx_gateway).

%%--------------------------------------------------------------------
%% Cases
%%--------------------------------------------------------------------

case01_register(Config) ->
    %%----------------------------------------
    %% REGISTER command
    %%----------------------------------------
    UdpSock = ?config(sock, Config),
    Epn = "urn:oma:lwm2m:oma:3",
    MsgId = 12,
    SubTopic = list_to_binary("lwm2m/"++Epn++"/dn/#"),

    test_send_coap_request( UdpSock,
                            post,
                            sprintf("coap://127.0.0.1:~b/rd?ep=~s&lt=345&lwm2m=1", [?PORT, Epn]),
                            #coap_content{content_format = <<"text/plain">>, payload = <<"</1>, </2>, </3>, </4>, </5>">>},
                            [],
                            MsgId),

    %% checkpoint 1 - response
    #coap_message{type = Type, method = Method, id = RspId, options = Opts} =
        test_recv_coap_response(UdpSock),
    ack = Type,
    {ok, created} = Method,
    RspId = MsgId,
    Location = proplists:get_value(location_path, Opts),
    ?assertNotEqual(undefined, Location),

    %% checkpoint 2 - verify subscribed topics
    timer:sleep(100),
    ?LOGT("all topics: ~p", [test_mqtt_broker:get_subscrbied_topics()]),
    true = lists:member(SubTopic, test_mqtt_broker:get_subscrbied_topics()),

    %%----------------------------------------
    %% DE-REGISTER command
    %%----------------------------------------
    ?LOGT("start to send DE-REGISTER command", []),
    MsgId3 = 52,
    test_send_coap_request( UdpSock,
                            delete,
                            sprintf("coap://127.0.0.1:~b~s", [?PORT, join_path(Location, <<>>)]),
                            #coap_content{payload = <<>>},
                            [],
                            MsgId3),
    #coap_message{type = ack, id = RspId3, method = Method3} = test_recv_coap_response(UdpSock),
    {ok,deleted} = Method3,
    MsgId3 = RspId3,
    timer:sleep(50),
    false = lists:member(SubTopic, test_mqtt_broker:get_subscrbied_topics()).

case01_register_additional_opts(Config) ->
    %%----------------------------------------
    %% REGISTER command
    %%----------------------------------------
    UdpSock = ?config(sock, Config),
    Epn = "urn:oma:lwm2m:oma:3",
    MsgId = 12,
    SubTopic = list_to_binary("lwm2m/"++Epn++"/dn/#"),

    AddOpts = "ep=~s&lt=345&lwm2m=1&apn=psmA.eDRX0.ctnb&cust_opt=shawn&im=123&ct=1.4&mt=mdm9620&mv=1.2",
    test_send_coap_request( UdpSock,
                            post,
                            sprintf("coap://127.0.0.1:~b/rd?" ++ AddOpts, [?PORT, Epn]),
                            #coap_content{content_format = <<"text/plain">>, payload = <<"</1>, </2>, </3>, </4>, </5>">>},
                            [],
                            MsgId),

    %% checkpoint 1 - response
    #coap_message{type = Type, method = Method, id = RspId, options = Opts} =
        test_recv_coap_response(UdpSock),
    Type = ack,
    Method = {ok, created},
    RspId = MsgId,
    Location = proplists:get_value(location_path, Opts),
    ?assertNotEqual(undefined, Location),

    %% checkpoint 2 - verify subscribed topics
    timer:sleep(50),

    true = lists:member(SubTopic, test_mqtt_broker:get_subscrbied_topics()),

    %%----------------------------------------
    %% DE-REGISTER command
    %%----------------------------------------
    ?LOGT("start to send DE-REGISTER command", []),
    MsgId3 = 52,
    test_send_coap_request( UdpSock,
                            delete,
                            sprintf("coap://127.0.0.1:~b~s", [?PORT, join_path(Location, <<>>)]),
                            #coap_content{payload = <<>>},
                            [],
                            MsgId3),
    #coap_message{type = ack, id = RspId3, method = Method3} = test_recv_coap_response(UdpSock),
    {ok,deleted} = Method3,
    MsgId3 = RspId3,
    timer:sleep(50),
    false = lists:member(SubTopic, test_mqtt_broker:get_subscrbied_topics()).

case01_register_incorrect_opts(Config) ->
    %%----------------------------------------
    %% REGISTER command
    %%----------------------------------------
    UdpSock = ?config(sock, Config),
    Epn = "urn:oma:lwm2m:oma:3",
    MsgId = 12,


    AddOpts = "ep=~s&lt=345&lwm2m=1&incorrect_opt",
    test_send_coap_request( UdpSock,
                            post,
                            sprintf("coap://127.0.0.1:~b/rd?" ++ AddOpts, [?PORT, Epn]),
                            #coap_content{content_format = <<"text/plain">>, payload = <<"</1>, </2>, </3>, </4>, </5>">>},
                            [],
                            MsgId),

    %% checkpoint 1 - response
    #coap_message{type = ack, method = Method, id = MsgId} =
        test_recv_coap_response(UdpSock),
    ?assertEqual({error,bad_request}, Method).

case01_register_report(Config) ->
    %%----------------------------------------
    %% REGISTER command
    %%----------------------------------------
    UdpSock = ?config(sock, Config),
    Epn = "urn:oma:lwm2m:oma:3",
    MsgId = 12,
    SubTopic = list_to_binary("lwm2m/"++Epn++"/dn/#"),
    ReportTopic = list_to_binary("lwm2m/"++Epn++"/up/resp"),
    emqtt:subscribe(?config(emqx_c, Config), ReportTopic, qos0),
    timer:sleep(200),

    test_send_coap_request( UdpSock,
                            post,
                            sprintf("coap://127.0.0.1:~b/rd?ep=~s&lt=345&lwm2m=1", [?PORT, Epn]),
                            #coap_content{content_format = <<"text/plain">>, payload = <<"</1>, </2>, </3>, </4>, </5>">>},
                            [],
                            MsgId),

    #coap_message{type = Type, method = Method, id = RspId, options = Opts} =
        test_recv_coap_response(UdpSock),
    Type = ack,
    Method = {ok, created},
    RspId = MsgId,
    Location = proplists:get_value(location_path, Opts),
    ?assertNotEqual(undefined, Location),

    timer:sleep(50),
    true = lists:member(SubTopic, test_mqtt_broker:get_subscrbied_topics()),

    ReadResult = emqx_json:encode(#{
                                <<"msgType">> => <<"register">>,
                                <<"data">> => #{
                                    <<"alternatePath">> => <<"/">>,
                                    <<"ep">> => list_to_binary(Epn),
                                    <<"lt">> => 345,
                                    <<"lwm2m">> => <<"1">>,
                                    <<"objectList">> => [<<"/1">>, <<"/2">>, <<"/3">>, <<"/4">>, <<"/5">>]
                                }
                             }),
    ?assertEqual(ReadResult, test_recv_mqtt_response(ReportTopic)),

    %%----------------------------------------
    %% DE-REGISTER command
    %%----------------------------------------
    ?LOGT("start to send DE-REGISTER command", []),
    MsgId3 = 52,
    test_send_coap_request( UdpSock,
                            delete,
                            sprintf("coap://127.0.0.1:~b~s", [?PORT, join_path(Location, <<>>)]),
                            #coap_content{payload = <<>>},
                            [],
                            MsgId3),
    #coap_message{type = ack, id = RspId3, method = Method3} = test_recv_coap_response(UdpSock),
    {ok,deleted} = Method3,
    MsgId3 = RspId3,
    timer:sleep(50),
    false = lists:member(SubTopic, test_mqtt_broker:get_subscrbied_topics()).

case02_update_deregister(Config) ->
    %%----------------------------------------
    %% REGISTER command
    %%----------------------------------------
    UdpSock = ?config(sock, Config),
    Epn = "urn:oma:lwm2m:oma:3",
    MsgId = 12,
    SubTopic = list_to_binary("lwm2m/"++Epn++"/dn/#"),
    ReportTopic = list_to_binary("lwm2m/"++Epn++"/up/resp"),
    emqtt:subscribe(?config(emqx_c, Config), ReportTopic, qos0),
    timer:sleep(200),

    test_send_coap_request( UdpSock,
                            post,
                            sprintf("coap://127.0.0.1:~b/rd?ep=~s&lt=345&lwm2m=1", [?PORT, Epn]),
                            #coap_content{content_format = <<"text/plain">>, payload = <<"</1>, </2>, </3>, </4>, </5>">>},
                            [],
                            MsgId),
    timer:sleep(100),
    #coap_message{type = ack, method = Method, options = Opts} = test_recv_coap_response(UdpSock),
    ?assertEqual({ok,created}, Method),

    ?LOGT("Options got: ~p", [Opts]),
    Location = proplists:get_value(location_path, Opts),
    Register = emqx_json:encode(#{
                              <<"msgType">> => <<"register">>,
                              <<"data">> => #{
                                  <<"alternatePath">> => <<"/">>,
                                  <<"ep">> => list_to_binary(Epn),
                                  <<"lt">> => 345,
                                  <<"lwm2m">> => <<"1">>,
                                  <<"objectList">> => [<<"/1">>, <<"/2">>, <<"/3">>, <<"/4">>, <<"/5">>]
                              }
                            }),
    ?assertEqual(Register, test_recv_mqtt_response(ReportTopic)),

    %%----------------------------------------
    %% UPDATE command
    %%----------------------------------------
    ?LOGT("start to send UPDATE command", []),
    MsgId2 = 27,
    test_send_coap_request( UdpSock,
                            post,
                            sprintf("coap://127.0.0.1:~b~s?lt=789", [?PORT, join_path(Location, <<>>)]),
                            #coap_content{content_format = <<"text/plain">>, payload = <<"</1>, </2>, </3>, </4>, </5>, </6>">>},
                            [],
                            MsgId2),
    #coap_message{type = ack, id = RspId2, method = Method2} = test_recv_coap_response(UdpSock),
    {ok,changed} = Method2,
    MsgId2 = RspId2,
    Update = emqx_json:encode(#{
                            <<"msgType">> => <<"update">>,
                            <<"data">> => #{
                                <<"alternatePath">> => <<"/">>,
                                <<"ep">> => list_to_binary(Epn),
                                <<"lt">> => 789,
                                <<"lwm2m">> => <<"1">>,
                                <<"objectList">> => [<<"/1">>, <<"/2">>, <<"/3">>, <<"/4">>, <<"/5">>, <<"/6">>]
                            }
                        }),
    ?assertEqual(Update, test_recv_mqtt_response(ReportTopic)),

    %%----------------------------------------
    %% DE-REGISTER command
    %%----------------------------------------
    ?LOGT("start to send DE-REGISTER command", []),
    MsgId3 = 52,
    test_send_coap_request( UdpSock,
                            delete,
                            sprintf("coap://127.0.0.1:~b~s", [?PORT, join_path(Location, <<>>)]),
                            #coap_content{payload = <<>>},
                            [],
                            MsgId3),
    #coap_message{type = ack, id = RspId3, method = Method3} = test_recv_coap_response(UdpSock),
    {ok,deleted} = Method3,
    MsgId3 = RspId3,

    timer:sleep(50),
    false = lists:member(SubTopic, test_mqtt_broker:get_subscrbied_topics()).

case03_register_wrong_version(Config) ->
    %%----------------------------------------
    %% REGISTER command
    %%----------------------------------------
    UdpSock = ?config(sock, Config),
    Epn = "urn:oma:lwm2m:oma:3",
    MsgId = 12,
    SubTopic = list_to_binary("lwm2m/"++Epn++"/dn/#"),
    test_send_coap_request( UdpSock,
                            post,
                            sprintf("coap://127.0.0.1:~b/rd?ep=~s&lt=345&lwm2m=8.3", [?PORT, Epn]),
                            #coap_content{content_format = <<"text/plain">>, payload = <<"</1>, </2>, </3>, </4>, </5>">>},
                            [],
                            MsgId),
    #coap_message{type = ack, method = Method} = test_recv_coap_response(UdpSock),
    ?assertEqual({error, bad_request}, Method),
    timer:sleep(50),

    false = lists:member(SubTopic, test_mqtt_broker:get_subscrbied_topics()).

case04_register_and_lifetime_timeout(Config) ->
    %%----------------------------------------
    %% REGISTER command
    %%----------------------------------------
    UdpSock = ?config(sock, Config),
    Epn = "urn:oma:lwm2m:oma:3",
    MsgId = 12,
    SubTopic = list_to_binary("lwm2m/"++Epn++"/dn/#"),

    test_send_coap_request( UdpSock,
                            post,
                            sprintf("coap://127.0.0.1:~b/rd?ep=~s&lt=2&lwm2m=1", [?PORT, Epn]),
                            #coap_content{content_format = <<"text/plain">>, payload = <<"</1>, </2>, </3>, </4>, </5>">>},
                            [],
                            MsgId),
    timer:sleep(100),
    #coap_message{type = ack, method = Method} = test_recv_coap_response(UdpSock),
    ?assertEqual({ok,created}, Method),

    true = lists:member(SubTopic, test_mqtt_broker:get_subscrbied_topics()),

    %%----------------------------------------
    %% lifetime timeout
    %%----------------------------------------
    timer:sleep(4000),

    false = lists:member(SubTopic, test_mqtt_broker:get_subscrbied_topics()).

case05_register_wrong_epn(Config) ->
    %%----------------------------------------
    %% REGISTER command
    %%----------------------------------------
    MsgId = 12,
    UdpSock = ?config(sock, Config),

    test_send_coap_request( UdpSock,
                            post,
                            sprintf("coap://127.0.0.1:~b/rd?lt=345&lwm2m=1.0", [?PORT]),
                            #coap_content{content_format = <<"text/plain">>, payload = <<"</1>, </2>, </3>, </4>, </5>">>},
                            [],
                            MsgId),
    #coap_message{type = ack, method = Method} = test_recv_coap_response(UdpSock),
    ?assertEqual({error,bad_request}, Method).

%% case06_register_wrong_lifetime(Config) ->
%%     %%----------------------------------------
%%    %% REGISTER command
%%     %%----------------------------------------
%%     UdpSock = ?config(sock, Config),
%%     Epn = "urn:oma:lwm2m:oma:3",
%%     MsgId = 12,

%%     test_send_coap_request( UdpSock,
%%                             post,
%%                             sprintf("coap://127.0.0.1:~b/rd?ep=~s&lwm2m=1", [?PORT, Epn]),
%%                             #coap_content{content_format = <<"text/plain">>, payload = <<"</1>, </2>, </3>, </4>, </5>">>},
%%                             [],
%%                             MsgId),
%%     #coap_message{type = ack, method = Method} = test_recv_coap_response(UdpSock),
%%     ?assertEqual({error,bad_request}, Method),
%%     timer:sleep(50),
%%     ?assertEqual([], test_mqtt_broker:get_subscrbied_topics()).

case07_register_alternate_path_01(Config) ->
    %%----------------------------------------
    %% REGISTER command
    %%----------------------------------------
    UdpSock = ?config(sock, Config),
    Epn = "urn:oma:lwm2m:oma:3",
    MsgId = 12,
    SubTopic = list_to_binary("lwm2m/"++Epn++"/dn/#"),
    ReportTopic = list_to_binary("lwm2m/"++Epn++"/up/resp"),
    emqtt:subscribe(?config(emqx_c, Config), ReportTopic, qos0),
    timer:sleep(200),

    test_send_coap_request( UdpSock,
                            post,
                            sprintf("coap://127.0.0.1:~b/rd?ep=~s&lt=345&lwm2m=1", [?PORT, Epn]),
                            #coap_content{content_format = <<"text/plain">>,
                                          payload = <<"</>;rt=\"oma.lwm2m\";ct=11543,</lwm2m/1/0>,</lwm2m/2/0>,</lwm2m/3/0>">>},
                            [],
                            MsgId),
    timer:sleep(50),
    true = lists:member(SubTopic, test_mqtt_broker:get_subscrbied_topics()).

case07_register_alternate_path_02(Config) ->
    %%----------------------------------------
    %% REGISTER command
    %%----------------------------------------
    UdpSock = ?config(sock, Config),
    Epn = "urn:oma:lwm2m:oma:3",
    MsgId = 12,
    SubTopic = list_to_binary("lwm2m/"++Epn++"/dn/#"),
    ReportTopic = list_to_binary("lwm2m/"++Epn++"/up/resp"),
    emqtt:subscribe(?config(emqx_c, Config), ReportTopic, qos0),
    timer:sleep(200),

    test_send_coap_request( UdpSock,
                            post,
                            sprintf("coap://127.0.0.1:~b/rd?ep=~s&lt=345&lwm2m=1", [?PORT, Epn]),
                            #coap_content{content_format = <<"text/plain">>,
                                          payload = <<"</lwm2m>;rt=\"oma.lwm2m\";ct=11543,</lwm2m/1/0>,</lwm2m/2/0>,</lwm2m/3/0>">>},
                            [],
                            MsgId),
    timer:sleep(50),
    true = lists:member(SubTopic, test_mqtt_broker:get_subscrbied_topics()).

case08_reregister(Config) ->
    %%----------------------------------------
    %% REGISTER command
    %%----------------------------------------
    UdpSock = ?config(sock, Config),
    Epn = "urn:oma:lwm2m:oma:3",
    MsgId = 12,
    SubTopic = list_to_binary("lwm2m/"++Epn++"/dn/#"),
    ReportTopic = list_to_binary("lwm2m/"++Epn++"/up/resp"),
    emqtt:subscribe(?config(emqx_c, Config), ReportTopic, qos0),
    timer:sleep(200),

    test_send_coap_request( UdpSock,
                            post,
                            sprintf("coap://127.0.0.1:~b/rd?ep=~s&lt=345&lwm2m=1", [?PORT, Epn]),
                            #coap_content{content_format = <<"text/plain">>,
                                          payload = <<"</lwm2m>;rt=\"oma.lwm2m\";ct=11543,</lwm2m/1/0>,</lwm2m/2/0>,</lwm2m/3/0>">>},
                            [],
                            MsgId),
    timer:sleep(50),
    true = lists:member(SubTopic, test_mqtt_broker:get_subscrbied_topics()),

    ReadResult = emqx_json:encode(
                   #{
                     <<"msgType">> => <<"register">>,
                     <<"data">> => #{
                                     <<"alternatePath">> => <<"/lwm2m">>,
                                     <<"ep">> => list_to_binary(Epn),
                                     <<"lt">> => 345,
                                     <<"lwm2m">> => <<"1">>,
                                     <<"objectList">> => [<<"/1/0">>, <<"/2/0">>, <<"/3/0">>]
                                    }
                    }
                  ),
    ?assertEqual(ReadResult, test_recv_mqtt_response(ReportTopic)),
    timer:sleep(1000),

    %% the same lwm2mc client registers to server again
    test_send_coap_request( UdpSock,
                            post,
                            sprintf("coap://127.0.0.1:~b/rd?ep=~s&lt=345&lwm2m=1", [?PORT, Epn]),
                            #coap_content{content_format = <<"text/plain">>,
                                          payload = <<"</lwm2m>;rt=\"oma.lwm2m\";ct=11543,</lwm2m/1/0>,</lwm2m/2/0>,</lwm2m/3/0>">>},
                            [],
                            MsgId + 1),

    %% verify the lwm2m client is still online
    ?assertEqual(ReadResult, test_recv_mqtt_response(ReportTopic)).

case10_read(Config) ->
    UdpSock = ?config(sock, Config),
    Epn = "urn:oma:lwm2m:oma:3",
    MsgId1 = 15,
    RespTopic = list_to_binary("lwm2m/"++Epn++"/up/resp"),
    emqtt:subscribe(?config(emqx_c, Config), RespTopic, qos0),
    timer:sleep(200),
    %% step 1, device register ...
    test_send_coap_request( UdpSock,
                            post,
                            sprintf("coap://127.0.0.1:~b/rd?ep=~s&lt=345&lwm2m=1", [?PORT, Epn]),
                            #coap_content{content_format = <<"text/plain">>,
                                          payload = <<"</lwm2m>;rt=\"oma.lwm2m\";ct=11543,</lwm2m/1/0>,</lwm2m/2/0>,</lwm2m/3/0>">>},
                            [],
                            MsgId1),
    #coap_message{method = Method1} = test_recv_coap_response(UdpSock),
    ?assertEqual({ok,created}, Method1),
    test_recv_mqtt_response(RespTopic),

    %% step2,  send a READ command to device
    CmdId = 206,
    CommandTopic = <<"lwm2m/", (list_to_binary(Epn))/binary, "/dn/dm">>,
    Command =   #{
                  <<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                  <<"msgType">> => <<"read">>,
                  <<"data">> => #{
                                  <<"path">> => <<"/3/0/0">>
                                 }
                 },
    CommandJson = emqx_json:encode(Command),
    ?LOGT("CommandJson=~p", [CommandJson]),
    test_mqtt_broker:publish(CommandTopic, CommandJson, 0),
    timer:sleep(50),
    Request2 = test_recv_coap_request(UdpSock),
    #coap_message{method = Method2, options=Options2, payload=Payload2} = Request2,
    ?LOGT("LwM2M client got ~p", [Request2]),

    ?assertEqual(get, Method2),
    ?assertEqual(<<"/lwm2m/3/0/0">>, get_coap_path(Options2)),
    ?assertEqual(<<>>, Payload2),
    timer:sleep(50),

    test_send_coap_response(UdpSock, "127.0.0.1", ?PORT, {ok, content}, #coap_content{content_format = <<"text/plain">>, payload = <<"EMQ">>}, Request2, true),
    timer:sleep(100),

    ReadResult = emqx_json:encode(#{  <<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                                      <<"msgType">> => <<"read">>,
                                      <<"data">> => #{
                                                      <<"code">> => <<"2.05">>,
                                                      <<"codeMsg">> => <<"content">>,
                                                      <<"reqPath">> => <<"/3/0/0">>,
                                                      <<"content">> => [#{
                                                                          path => <<"/3/0/0">>,
                                                                          value => <<"EMQ">>
                                                                         }]
                                                     }
                                   }),
    ?assertEqual(ReadResult, test_recv_mqtt_response(RespTopic)).

case10_read_separate_ack(Config) ->
    UdpSock = ?config(sock, Config),
    Epn = "urn:oma:lwm2m:oma:3",
    MsgId1 = 15,
    ObjectList = <<"</1>, </2>, </3/0>, </4>, </5>">>,
    RespTopic = list_to_binary("lwm2m/"++Epn++"/up/resp"),

    emqtt:subscribe(?config(emqx_c, Config), RespTopic, qos0),
    timer:sleep(200),

    %% step 1, device register ...
    std_register(UdpSock, Epn, ObjectList, MsgId1, RespTopic),

    %% step2,  send a READ command to device
    CmdId = 206,
    CommandTopic = <<"lwm2m/", (list_to_binary(Epn))/binary, "/dn/dm">>,
    Command = #{
                <<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                <<"msgType">> => <<"read">>,
                <<"data">> => #{
                                <<"path">> => <<"/3/0/0">>
                               }
               },
    CommandJson = emqx_json:encode(Command),
    ?LOGT("CommandJson=~p", [CommandJson]),
    test_mqtt_broker:publish(CommandTopic, CommandJson, 0),
    timer:sleep(50),
    Request2 = test_recv_coap_request(UdpSock),
    #coap_message{method = Method2, options=Options2, payload=Payload2} = Request2,
    ?LOGT("LwM2M client got ~p", [Request2]),

    ?assertEqual(get, Method2),
    ?assertEqual(<<"/3/0/0">>, get_coap_path(Options2)),
    ?assertEqual(<<>>, Payload2),

    test_send_empty_ack(UdpSock, "127.0.0.1", ?PORT, Request2),
    ReadResultACK = emqx_json:encode(#{
                                       <<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                                       <<"msgType">> => <<"ack">>,
                                       <<"data">> => #{
                                                       <<"path">> => <<"/3/0/0">>
                                                      }
                                      }),
    ?assertEqual(ReadResultACK, test_recv_mqtt_response(RespTopic)),
    timer:sleep(100),

    test_send_coap_response(UdpSock, "127.0.0.1", ?PORT, {ok, content}, #coap_content{content_format = <<"text/plain">>, payload = <<"EMQ">>}, Request2, false),
    timer:sleep(100),

    ReadResult = emqx_json:encode(#{  <<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                                      <<"msgType">> => <<"read">>,
                                      <<"data">> => #{
                                                      <<"code">> => <<"2.05">>,
                                                      <<"codeMsg">> => <<"content">>,
                                                      <<"reqPath">> => <<"/3/0/0">>,
                                                      <<"content">> => [#{
                                                                          path => <<"/3/0/0">>,
                                                                          value => <<"EMQ">>
                                                                         }]
                                                     }
                                   }),
    ?assertEqual(ReadResult, test_recv_mqtt_response(RespTopic)).

case11_read_object_tlv(Config) ->
    %% step 1, device register ...
    Epn = "urn:oma:lwm2m:oma:3",
    MsgId1 = 15,
    UdpSock = ?config(sock, Config),
    ObjectList = <<"</1>, </2>, </3/0>, </4>, </5>">>,
    RespTopic = list_to_binary("lwm2m/"++Epn++"/up/resp"),
    emqtt:subscribe(?config(emqx_c, Config), RespTopic, qos0),
    timer:sleep(200),

    std_register(UdpSock, Epn, ObjectList, MsgId1, RespTopic),

    %% step2,  send a READ command to device
    CmdId = 207,
    CommandTopic = <<"lwm2m/", (list_to_binary(Epn))/binary, "/dn/dm">>,
    Command =   #{
                  <<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                  <<"msgType">> => <<"read">>,
                  <<"data">> => #{
                                  <<"path">> => <<"/3/0">>
                                 }
                 },
    CommandJson = emqx_json:encode(Command),
    ?LOGT("CommandJson=~p", [CommandJson]),
    test_mqtt_broker:publish(CommandTopic, CommandJson, 0),
    timer:sleep(50),
    Request2 = test_recv_coap_request(UdpSock),
    #coap_message{method = Method2} = Request2,
    ?LOGT("LwM2M client got ~p", [Request2]),

    ?assertEqual(get, Method2),
    timer:sleep(50),

    Tlv = <<16#08, 16#00, 16#3C, 16#C8, 16#00, 16#14, 16#4F, 16#70, 16#65, 16#6E, 16#20, 16#4D, 16#6F, 16#62, 16#69, 16#6C, 16#65, 16#20, 16#41, 16#6C, 16#6C, 16#69, 16#61, 16#6E, 16#63, 16#65, 16#C8, 16#01, 16#16, 16#4C, 16#69, 16#67, 16#68, 16#74, 16#77, 16#65, 16#69, 16#67, 16#68, 16#74, 16#20, 16#4D, 16#32, 16#4D, 16#20, 16#43, 16#6C, 16#69, 16#65, 16#6E, 16#74, 16#C8, 16#02, 16#09, 16#33, 16#34, 16#35, 16#30, 16#30, 16#30, 16#31, 16#32, 16#33>>,
    test_send_coap_response(UdpSock, "127.0.0.1", ?PORT, {ok, content}, #coap_content{content_format = <<"application/vnd.oma.lwm2m+tlv">>, payload = Tlv}, Request2, true),
    timer:sleep(100),

    ReadResult = emqx_json:encode(#{  <<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                                      <<"msgType">> => <<"read">>,
                                      <<"data">> => #{
                                                      <<"code">> => <<"2.05">>,
                                                      <<"codeMsg">> => <<"content">>,
                                                      <<"reqPath">> => <<"/3/0">>,
                                                      <<"content">> => [
                                                                        #{
                                                                          path => <<"/3/0/0">>,
                                                                          value => <<"Open Mobile Alliance">>
                                                                         },
                                                                        #{
                                                                          path => <<"/3/0/1">>,
                                                                          value => <<"Lightweight M2M Client">>
                                                                         },
                                                                        #{
                                                                          path => <<"/3/0/2">>,
                                                                          value => <<"345000123">>
                                                                         }
                                                                       ]
                                                     }
                                   }),
    ?assertEqual(ReadResult, test_recv_mqtt_response(RespTopic)).

case11_read_object_json(Config) ->
    %% step 1, device register ...
    UdpSock = ?config(sock, Config),
    Epn = "urn:oma:lwm2m:oma:3",
    MsgId1 = 15,

    RespTopic = list_to_binary("lwm2m/"++Epn++"/up/resp"),
    ObjectList = <<"</1>, </2>, </3/0>, </4>, </5>">>,
    emqtt:subscribe(?config(emqx_c, Config), RespTopic, qos0),
    timer:sleep(200),

    std_register(UdpSock, Epn, ObjectList, MsgId1, RespTopic),

    %% step2,  send a READ command to device
    CmdId = 206,
    CommandTopic = <<"lwm2m/", (list_to_binary(Epn))/binary, "/dn/dm">>,
    Command =   #{
                  <<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                  <<"msgType">> => <<"read">>,
                  <<"data">> => #{
                                  <<"path">> => <<"/3/0">>
                                 }
                 },
    CommandJson = emqx_json:encode(Command),
    ?LOGT("CommandJson=~p", [CommandJson]),
    test_mqtt_broker:publish(CommandTopic, CommandJson, 0),
    timer:sleep(50),
    Request2 = test_recv_coap_request(UdpSock),
    #coap_message{method = Method2} = Request2,
    ?LOGT("LwM2M client got ~p", [Request2]),

    ?assertEqual(get, Method2),
    timer:sleep(50),

    Json = <<"{\"bn\":\"/3/0\",\"e\":[{\"n\":\"0\",\"sv\":\"Open Mobile Alliance\"},{\"n\":\"1\",\"sv\":\"Lightweight M2M Client\"},{\"n\":\"2\",\"sv\":\"345000123\"}]}">>,
    test_send_coap_response(UdpSock, "127.0.0.1", ?PORT, {ok, content}, #coap_content{content_format = <<"application/vnd.oma.lwm2m+json">>, payload = Json}, Request2, true),
    timer:sleep(100),

    ReadResult = emqx_json:encode(#{  <<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                                      <<"msgType">> => <<"read">>,
                                      <<"data">> => #{
                                                      <<"code">> => <<"2.05">>,
                                                      <<"codeMsg">> => <<"content">>,
                                                      <<"reqPath">> => <<"/3/0">>,
                                                      <<"content">> => [
                                                                        #{
                                                                          path => <<"/3/0/0">>,
                                                                          value => <<"Open Mobile Alliance">>
                                                                         },
                                                                        #{
                                                                          path => <<"/3/0/1">>,
                                                                          value => <<"Lightweight M2M Client">>
                                                                         },
                                                                        #{
                                                                          path => <<"/3/0/2">>,
                                                                          value => <<"345000123">>
                                                                         }
                                                                       ]
                                                     }
                                   }),
    ?assertEqual(ReadResult, test_recv_mqtt_response(RespTopic)).

case12_read_resource_opaque(Config) ->
    %% step 1, device register ...
    UdpSock = ?config(sock, Config),
    Epn = "urn:oma:lwm2m:oma:3",
    MsgId1 = 15,
    ObjectList = <<"</1>, </2>, </3/0>, </4>, </5>">>,
    RespTopic = list_to_binary("lwm2m/"++Epn++"/up/resp"),
    emqtt:subscribe(?config(emqx_c, Config), RespTopic, qos0),
    timer:sleep(200),

    std_register(UdpSock, Epn, ObjectList, MsgId1, RespTopic),

    %% step2,  send a READ command to device
    CmdId = 206,
    CommandTopic = <<"lwm2m/", (list_to_binary(Epn))/binary, "/dn/dm">>,
    Command =   #{
                  <<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                  <<"msgType">> => <<"read">>,
                  <<"data">> => #{
                                  <<"path">> => <<"/3/0/8">>
                                 }
                 },
    CommandJson = emqx_json:encode(Command),
    ?LOGT("CommandJson=~p", [CommandJson]),
    test_mqtt_broker:publish(CommandTopic, CommandJson, 0),
    timer:sleep(50),
    Request2 = test_recv_coap_request(UdpSock),
    #coap_message{method = Method2} = Request2,
    ?LOGT("LwM2M client got ~p", [Request2]),

    ?assertEqual(get, Method2),
    timer:sleep(50),

    Opaque = <<20, 21, 22, 23>>,
    test_send_coap_response(UdpSock, "127.0.0.1", ?PORT, {ok, content}, #coap_content{content_format = <<"application/octet-stream">>, payload = Opaque}, Request2, true),
    timer:sleep(100),

    ReadResult = emqx_json:encode(#{  <<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                                      <<"msgType">> => <<"read">>,
                                      <<"data">> => #{
                                                      <<"code">> => <<"2.05">>,
                                                      <<"codeMsg">> => <<"content">>,
                                                      <<"reqPath">> => <<"/3/0/8">>,
                                                      <<"content">> => [
                                                                        #{
                                                                          path => <<"/3/0/8">>,
                                                                          value => base64:encode(Opaque)
                                                                         }
                                                                       ]
                                                     }
                                   }),
    ?assertEqual(ReadResult, test_recv_mqtt_response(RespTopic)).

case13_read_no_xml(Config) ->
    %% step 1, device register ...
    Epn = "urn:oma:lwm2m:oma:3",
    MsgId1 = 15,
    UdpSock = ?config(sock, Config),
    ObjectList = <<"</1>, </2>, </3/0>, </4>, </5>">>,
    RespTopic = list_to_binary("lwm2m/"++Epn++"/up/resp"),
    emqtt:subscribe(?config(emqx_c, Config), RespTopic, qos0),
    timer:sleep(200),

    std_register(UdpSock, Epn, ObjectList, MsgId1, RespTopic),

    %% step2,  send a READ command to device
    CmdId = 206,
    CommandTopic = <<"lwm2m/", (list_to_binary(Epn))/binary, "/dn/dm">>,
    Command =   #{
                  <<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                  <<"msgType">> => <<"read">>,
                  <<"data">> => #{
                                  <<"path">> => <<"/9723/0/0">>
                                 }
                 },
    CommandJson = emqx_json:encode(Command),
    ?LOGT("CommandJson=~p", [CommandJson]),
    test_mqtt_broker:publish(CommandTopic, CommandJson, 0),
    timer:sleep(50),
    Request2 = test_recv_coap_request(UdpSock),
    #coap_message{method = Method2} = Request2,
    ?LOGT("LwM2M client got ~p", [Request2]),

    ?assertEqual(get, Method2),
    timer:sleep(50),

    test_send_coap_response(UdpSock, "127.0.0.1", ?PORT, {ok, content}, #coap_content{content_format = <<"text/plain">>, payload = <<"EMQ">>}, Request2, true),
    timer:sleep(100),

    ReadResult = emqx_json:encode(#{  <<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                                      <<"msgType">> => <<"read">>,
                                      <<"data">> => #{
                                                      <<"reqPath">> => <<"/9723/0/0">>,
                                                      <<"code">> => <<"4.00">>,
                                                      <<"codeMsg">> => <<"bad_request">>
                                                     }
                                   }),
    ?assertEqual(ReadResult, test_recv_mqtt_response(RespTopic)).

case20_single_write(Config) ->
    %% step 1, device register ...
    Epn = "urn:oma:lwm2m:oma:3",
    MsgId1 = 15,
    UdpSock = ?config(sock, Config),
    ObjectList = <<"</1>, </2>, </3/0>, </4>, </5>">>,
    RespTopic = list_to_binary("lwm2m/"++Epn++"/up/resp"),
    emqtt:subscribe(?config(emqx_c, Config), RespTopic, qos0),
    timer:sleep(200),

    std_register(UdpSock, Epn, ObjectList, MsgId1, RespTopic),

    %% step2,  send a WRITE command to device
    CommandTopic = <<"lwm2m/", (list_to_binary(Epn))/binary, "/dn/dm">>,
    CmdId = 307,
    Command = #{<<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                <<"msgType">> => <<"write">>,
                <<"data">> => #{
                                <<"path">> => <<"/3/0/13">>,
                                <<"type">> => <<"Integer">>,
                                <<"value">> => <<"12345">>
                               }
               },
    CommandJson = emqx_json:encode(Command),
    test_mqtt_broker:publish(CommandTopic, CommandJson, 0),
    timer:sleep(50),
    Request2 = test_recv_coap_request(UdpSock),
    #coap_message{method = Method2, options=Options2, payload=Payload2} = Request2,
    Path2 = get_coap_path(Options2),
    ?assertEqual(put, Method2),
    ?assertEqual(<<"/3/0/13">>, Path2),
    Tlv_Value = <<3:2, 0:1, 0:2, 2:3, 13, 12345:16>>,
    ?assertEqual(Tlv_Value, Payload2),
    timer:sleep(50),

    test_send_coap_response(UdpSock, "127.0.0.1", ?PORT, {ok, changed}, #coap_content{}, Request2, true),
    timer:sleep(100),

    ReadResult = emqx_json:encode(#{
                                    <<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                                    <<"data">> => #{
                                                    <<"reqPath">> => <<"/3/0/13">>,
                                                    <<"code">> => <<"2.04">>,
                                                    <<"codeMsg">> => <<"changed">>
                                                   },
                                    <<"msgType">> => <<"write">>
                                   }),
    ?assertEqual(ReadResult, test_recv_mqtt_response(RespTopic)).

case20_write(Config) ->
    %% step 1, device register ...
    Epn = "urn:oma:lwm2m:oma:3",
    MsgId1 = 15,
    UdpSock = ?config(sock, Config),
    ObjectList = <<"</1>, </2>, </3/0>, </4>, </5>">>,
    RespTopic = list_to_binary("lwm2m/"++Epn++"/up/resp"),
    emqtt:subscribe(?config(emqx_c, Config), RespTopic, qos0),
    timer:sleep(200),

    std_register(UdpSock, Epn, ObjectList, MsgId1, RespTopic),

    %% step2,  send a WRITE command to device
    CommandTopic = <<"lwm2m/", (list_to_binary(Epn))/binary, "/dn/dm">>,
    CmdId = 307,
    Command = #{<<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                <<"msgType">> => <<"write">>,
                <<"data">> => #{
                                <<"basePath">> => <<"/3/0/13">>,
                                <<"content">> => [#{
                                                    type => <<"Float">>,
                                                    value => <<"12345.0">>
                                                   }]
                               }
               },
    CommandJson = emqx_json:encode(Command),
    test_mqtt_broker:publish(CommandTopic, CommandJson, 0),
    timer:sleep(50),
    Request2 = test_recv_coap_request(UdpSock),
    #coap_message{method = Method2, options=Options2, payload=Payload2} = Request2,
    Path2 = get_coap_path(Options2),
    ?assertEqual(put, Method2),
    ?assertEqual(<<"/3/0/13">>, Path2),
    Tlv_Value = <<200, 13, 8, 64,200,28,128,0,0,0,0>>,
    ?assertEqual(Tlv_Value, Payload2),
    timer:sleep(50),

    test_send_coap_response(UdpSock, "127.0.0.1", ?PORT, {ok, changed}, #coap_content{}, Request2, true),
    timer:sleep(100),

    WriteResult = emqx_json:encode(#{
                                     <<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                                     <<"data">> => #{
                                                     <<"reqPath">> => <<"/3/0/13">>,
                                                     <<"code">> => <<"2.04">>,
                                                     <<"codeMsg">> => <<"changed">>
                                                    },
                                     <<"msgType">> => <<"write">>
                                    }),
    ?assertEqual(WriteResult, test_recv_mqtt_response(RespTopic)).

case21_write_object(Config) ->
    %% step 1, device register ...
    Epn = "urn:oma:lwm2m:oma:3",
    MsgId1 = 15,
    UdpSock = ?config(sock, Config),
    ObjectList = <<"</1>, </2>, </3/0>, </4>, </5>">>,
    RespTopic = list_to_binary("lwm2m/"++Epn++"/up/resp"),
    emqtt:subscribe(?config(emqx_c, Config), RespTopic, qos0),
    timer:sleep(200),

    std_register(UdpSock, Epn, ObjectList, MsgId1, RespTopic),

    %% step2,  send a WRITE command to device
    CommandTopic = <<"lwm2m/", (list_to_binary(Epn))/binary, "/dn/dm">>,
    CmdId = 307,
    Command = #{<<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                <<"msgType">> => <<"write">>,
                <<"data">> => #{
                                <<"basePath">> => <<"/3/0/">>,
                                <<"content">> => [#{
                                                    path => <<"13">>,
                                                    type => <<"Integer">>,
                                                    value => <<"12345">>
                                                   },#{
                                                     path => <<"14">>,
                                                     type => <<"String">>,
                                                     value => <<"87x">>
                                                    }]
                               }
               },
    CommandJson = emqx_json:encode(Command),
    test_mqtt_broker:publish(CommandTopic, CommandJson, 0),
    timer:sleep(50),
    Request2 = test_recv_coap_request(UdpSock),
    #coap_message{method = Method2, options=Options2, payload=Payload2} = Request2,
    Path2 = get_coap_path(Options2),
    ?assertEqual(post, Method2),
    ?assertEqual(<<"/3/0">>, Path2),
    Tlv_Value = <<3:2, 0:1, 0:2, 2:3, 13, 12345:16,
                  3:2, 0:1, 0:2, 3:3, 14, "87x">>,
    ?assertEqual(Tlv_Value, Payload2),
    timer:sleep(50),

    test_send_coap_response(UdpSock, "127.0.0.1", ?PORT, {ok, changed}, #coap_content{}, Request2, true),
    timer:sleep(100),


    ReadResult = emqx_json:encode(#{
                                    <<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                                    <<"msgType">> => <<"write">>,
                                    <<"data">> => #{
                                                    <<"reqPath">> => <<"/3/0/">>,
                                                    <<"code">> => <<"2.04">>,
                                                    <<"codeMsg">> => <<"changed">>
                                                   }
                                   }),
    ?assertEqual(ReadResult, test_recv_mqtt_response(RespTopic)).

case22_write_error(Config) ->
    %% step 1, device register ...
    Epn = "urn:oma:lwm2m:oma:3",
    MsgId1 = 15,
    UdpSock = ?config(sock, Config),
    ObjectList = <<"</1>, </2>, </3/0>, </4>, </5>">>,
    RespTopic = list_to_binary("lwm2m/"++Epn++"/up/resp"),
    emqtt:subscribe(?config(emqx_c, Config), RespTopic, qos0),
    timer:sleep(200),

    std_register(UdpSock, Epn, ObjectList, MsgId1, RespTopic),

    %% step2,  send a WRITE command to device
    CommandTopic = <<"lwm2m/", (list_to_binary(Epn))/binary, "/dn/dm">>,
    CmdId = 307,
    Command = #{<<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                <<"msgType">> => <<"write">>,
                <<"data">> => #{
                                <<"basePath">> => <<"/3/0/1">>,
                                <<"content">> => [
                                                  #{
                                                    type => <<"Integer">>,
                                                    value => <<"12345">>
                                                   }
                                                 ]
                               }
               },
    CommandJson = emqx_json:encode(Command),
    test_mqtt_broker:publish(CommandTopic, CommandJson, 0),
    timer:sleep(50),
    Request2 = test_recv_coap_request(UdpSock),
    #coap_message{method = Method2, options=Options2} = Request2,
    Path2 = get_coap_path(Options2),
    ?assertEqual(put, Method2),
    ?assertEqual(<<"/3/0/1">>, Path2),
    timer:sleep(50),

    test_send_coap_response(UdpSock, "127.0.0.1", ?PORT, {error, bad_request}, #coap_content{}, Request2, true),
    timer:sleep(100),

    ReadResult = emqx_json:encode(#{
                                    <<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                                    <<"data">> => #{
                                                    <<"reqPath">> => <<"/3/0/1">>,
                                                    <<"code">> => <<"4.00">>,
                                                    <<"codeMsg">> => <<"bad_request">>
                                                   },
                                    <<"msgType">> => <<"write">>
                                   }),
    ?assertEqual(ReadResult, test_recv_mqtt_response(RespTopic)).

case_create_basic(Config) ->
    %% step 1, device register ...
    Epn = "urn:oma:lwm2m:oma:3",
    MsgId1 = 15,
    UdpSock = ?config(sock, Config),
    ObjectList = <<"</1>, </2>, </3/0>, </4>">>,
    RespTopic = list_to_binary("lwm2m/"++Epn++"/up/resp"),
    emqtt:subscribe(?config(emqx_c, Config), RespTopic, qos0),
    timer:sleep(200),

    std_register(UdpSock, Epn, ObjectList, MsgId1, RespTopic),

    %% step2, send a CREATE command to device
    CommandTopic = <<"lwm2m/", (list_to_binary(Epn))/binary, "/dn/dm">>,
    CmdId = 307,
    Command = #{<<"msgType">> => <<"create">>,
                <<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                <<"data">> => #{<<"content">> => [],
                                <<"basePath">> => <<"/5">>
                               }},
    CommandJson = emqx_json:encode(Command),
    test_mqtt_broker:publish(CommandTopic, CommandJson, 0),
    timer:sleep(50),
    Request2 = test_recv_coap_request(UdpSock),
    #coap_message{method = Method2, options=Options2, payload=Payload2} = Request2,
    Path2 = get_coap_path(Options2),
    ?assertEqual(post, Method2),
    ?assertEqual(<<"/5">>, Path2),
    ?assertEqual(<<"">>, Payload2),
    timer:sleep(50),

    test_send_coap_response(UdpSock, "127.0.0.1", ?PORT, {ok, created}, #coap_content{}, Request2, true),
    timer:sleep(100),

    ReadResult = emqx_json:encode(#{
                                    <<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                                    <<"data">> => #{
                                                    <<"reqPath">> => <<"/5">>,
                                                    <<"code">> => <<"2.01">>,
                                                    <<"codeMsg">> => <<"created">>
                                                   },
                                    <<"msgType">> => <<"create">>
                                   }),
    ?assertEqual(ReadResult, test_recv_mqtt_response(RespTopic)).

case_delete_basic(Config) ->
    %% step 1, device register ...
    Epn = "urn:oma:lwm2m:oma:3",
    MsgId1 = 15,
    UdpSock = ?config(sock, Config),
    ObjectList = <<"</1>, </2>, </3/0>, </4>, </5>, </5/0>">>,
    RespTopic = list_to_binary("lwm2m/"++Epn++"/up/resp"),
    emqtt:subscribe(?config(emqx_c, Config), RespTopic, qos0),
    timer:sleep(200),

    std_register(UdpSock, Epn, ObjectList, MsgId1, RespTopic),

    %% step2, send a CREATE command to device
    CommandTopic = <<"lwm2m/", (list_to_binary(Epn))/binary, "/dn/dm">>,
    CmdId = 307,
    Command = #{<<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                <<"msgType">> => <<"delete">>,
                <<"data">> => #{
                                <<"path">> => <<"/5/0">>
                               }
               },
    CommandJson = emqx_json:encode(Command),
    test_mqtt_broker:publish(CommandTopic, CommandJson, 0),
    timer:sleep(50),
    Request2 = test_recv_coap_request(UdpSock),
    #coap_message{method = Method2, options=Options2, payload=Payload2} = Request2,
    Path2 = get_coap_path(Options2),
    ?assertEqual(delete, Method2),
    ?assertEqual(<<"/5/0">>, Path2),
    ?assertEqual(<<"">>, Payload2),
    timer:sleep(50),

    test_send_coap_response(UdpSock, "127.0.0.1", ?PORT, {ok, deleted}, #coap_content{}, Request2, true),
    timer:sleep(100),

    ReadResult = emqx_json:encode(#{
                                    <<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                                    <<"data">> => #{
                                                    <<"reqPath">> => <<"/5/0">>,
                                                    <<"code">> => <<"2.02">>,
                                                    <<"codeMsg">> => <<"deleted">>
                                                   },
                                    <<"msgType">> => <<"delete">>
                                   }),
    ?assertEqual(ReadResult, test_recv_mqtt_response(RespTopic)).

case30_execute(Config) ->
    %% step 1, device register ...
    Epn = "urn:oma:lwm2m:oma:3",
    MsgId1 = 15,
    UdpSock = ?config(sock, Config),
    ObjectList = <<"</1>, </2>, </3/0>, </4>, </5>">>,
    RespTopic = list_to_binary("lwm2m/"++Epn++"/up/resp"),
    emqtt:subscribe(?config(emqx_c, Config), RespTopic, qos0),
    timer:sleep(200),

    std_register(UdpSock, Epn, ObjectList, MsgId1, RespTopic),

    %% step2,  send a WRITE command to device
    CommandTopic = <<"lwm2m/", (list_to_binary(Epn))/binary, "/dn/dm">>,
    CmdId = 307,
    Command = #{<<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                <<"msgType">> => <<"execute">>,
                <<"data">> => #{
                                <<"path">> => <<"/3/0/4">>,
                                %% "args" should not be present for "/3/0/4", only for testing the encoding here
                                <<"args">> => <<"2,7">>
                               }
               },
    CommandJson = emqx_json:encode(Command),
    test_mqtt_broker:publish(CommandTopic, CommandJson, 0),
    timer:sleep(50),
    Request2 = test_recv_coap_request(UdpSock),
    #coap_message{method = Method2, options=Options2, payload=Payload2} = Request2,
    Path2 = get_coap_path(Options2),
    ?assertEqual(post, Method2),
    ?assertEqual(<<"/3/0/4">>, Path2),
    ?assertEqual(<<"2,7">>, Payload2),
    timer:sleep(50),

    test_send_coap_response(UdpSock, "127.0.0.1", ?PORT, {ok, changed}, #coap_content{}, Request2, true),
    timer:sleep(100),

    ReadResult = emqx_json:encode(#{
                                    <<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                                    <<"data">> => #{
                                                    <<"reqPath">> => <<"/3/0/4">>,
                                                    <<"code">> => <<"2.04">>,
                                                    <<"codeMsg">> => <<"changed">>
                                                   },
                                    <<"msgType">> => <<"execute">>
                                   }),
    ?assertEqual(ReadResult, test_recv_mqtt_response(RespTopic)).

case31_execute_error(Config) ->
    %% step 1, device register ...
    Epn = "urn:oma:lwm2m:oma:3",
    MsgId1 = 15,
    UdpSock = ?config(sock, Config),
    ObjectList = <<"</1>, </2>, </3/0>, </4>, </5>">>,
    RespTopic = list_to_binary("lwm2m/"++Epn++"/up/resp"),
    emqtt:subscribe(?config(emqx_c, Config), RespTopic, qos0),
    timer:sleep(200),

    std_register(UdpSock, Epn, ObjectList, MsgId1, RespTopic),

    %% step2,  send a WRITE command to device
    CommandTopic = <<"lwm2m/", (list_to_binary(Epn))/binary, "/dn/dm">>,
    CmdId = 307,
    Command = #{<<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                <<"msgType">> => <<"execute">>,
                <<"data">> => #{
                                <<"path">> => <<"/3/0/4">>,
                                <<"args">> => <<"2,7">>
                               }
               },
    CommandJson = emqx_json:encode(Command),
    test_mqtt_broker:publish(CommandTopic, CommandJson, 0),
    timer:sleep(50),
    Request2 = test_recv_coap_request(UdpSock),
    #coap_message{method = Method2, options=Options2, payload=Payload2} = Request2,
    Path2 = get_coap_path(Options2),
    ?assertEqual(post, Method2),
    ?assertEqual(<<"/3/0/4">>, Path2),
    ?assertEqual(<<"2,7">>, Payload2),
    timer:sleep(50),

    test_send_coap_response(UdpSock, "127.0.0.1", ?PORT, {error, uauthorized}, #coap_content{}, Request2, true),
    timer:sleep(100),

    ReadResult = emqx_json:encode(#{
                                    <<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                                    <<"data">> => #{
                                                    <<"reqPath">> => <<"/3/0/4">>,
                                                    <<"code">> => <<"4.01">>,
                                                    <<"codeMsg">> => <<"unauthorized">>
                                                   },
                                    <<"msgType">> => <<"execute">>
                                   }),
    ?assertEqual(ReadResult, test_recv_mqtt_response(RespTopic)).

case40_discover(Config) ->
    %% step 1, device register ...
    Epn = "urn:oma:lwm2m:oma:3",
    MsgId1 = 15,
    UdpSock = ?config(sock, Config),
    ObjectList = <<"</1>, </2>, </3/0>, </4>, </5>">>,
    RespTopic = list_to_binary("lwm2m/"++Epn++"/up/resp"),
    emqtt:subscribe(?config(emqx_c, Config), RespTopic, qos0),
    timer:sleep(200),

    std_register(UdpSock, Epn, ObjectList, MsgId1, RespTopic),

    %% step2,  send a WRITE command to device
    CommandTopic = <<"lwm2m/", (list_to_binary(Epn))/binary, "/dn/dm">>,
    CmdId = 307,
    Command = #{<<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                <<"msgType">> => <<"discover">>,
                <<"data">> => #{
                                <<"path">> => <<"/3/0/7">>
                               } },
    CommandJson = emqx_json:encode(Command),
    test_mqtt_broker:publish(CommandTopic, CommandJson, 0),
    timer:sleep(50),
    Request2 = test_recv_coap_request(UdpSock),
    #coap_message{method = Method2, options=Options2, payload=Payload2} = Request2,
    Path2 = get_coap_path(Options2),
    ?assertEqual(get, Method2),
    ?assertEqual(<<"/3/0/7">>, Path2),
    ?assertEqual(<<>>, Payload2),
    timer:sleep(50),

    PayloadDiscover = <<"</3/0/7>;dim=8;pmin=10;pmax=60;gt=50;lt=42.2,</3/0/8>">>,
    test_send_coap_response(UdpSock,
                            "127.0.0.1",
                            ?PORT,
                            {ok, content},
                            #coap_content{content_format = <<"application/link-format">>, payload = PayloadDiscover},
                            Request2,
                            true),
    timer:sleep(100),

    ReadResult = emqx_json:encode(#{
                                    <<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                                    <<"msgType">> => <<"discover">>,
                                    <<"data">> => #{
                                                    <<"reqPath">> => <<"/3/0/7">>,
                                                    <<"code">> => <<"2.05">>,
                                                    <<"codeMsg">> => <<"content">>,
                                                    <<"content">> =>
                                                        [<<"</3/0/7>;dim=8;pmin=10;pmax=60;gt=50;lt=42.2">>, <<"</3/0/8>">>]
                                                   }
                                   }),
    ?assertEqual(ReadResult, test_recv_mqtt_response(RespTopic)).

case50_write_attribute(Config) ->
    %% step 1, device register ...
    Epn = "urn:oma:lwm2m:oma:3",
    MsgId1 = 15,
    UdpSock = ?config(sock, Config),
    ObjectList = <<"</1>, </2>, </3/0>, </4>, </5>">>,
    RespTopic = list_to_binary("lwm2m/"++Epn++"/up/resp"),
    emqtt:subscribe(?config(emqx_c, Config), RespTopic, qos0),
    timer:sleep(200),

    std_register(UdpSock, Epn, ObjectList, MsgId1, RespTopic),

    %% step2,  send a WRITE command to device
    CommandTopic = <<"lwm2m/", (list_to_binary(Epn))/binary, "/dn/dm">>,
    CmdId = 307,
    Command = #{<<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                <<"msgType">> => <<"write-attr">>,
                <<"data">> => #{
                                <<"path">> => <<"/3/0/9">>,
                                <<"pmin">> => <<"1">>,
                                <<"pmax">> => <<"5">>,
                                <<"lt">> => <<"5">>
                               } },
    CommandJson = emqx_json:encode(Command),
    test_mqtt_broker:publish(CommandTopic, CommandJson, 0),
    timer:sleep(100),
    Request2 = test_recv_coap_request(UdpSock),
    #coap_message{method = Method2, options=Options2, payload=Payload2} = Request2,
    ?LOGT("got options: ~p", [Options2]),
    Path2 = get_coap_path(Options2),
    Query2 = lists:sort(get_coap_query(Options2)),
    ?assertEqual(put, Method2),
    ?assertEqual(<<"/3/0/9">>, Path2),
    ?assertEqual(lists:sort([<<"pmax=5">>,<<"lt=5">>,<<"pmin=1">>]), Query2),
    ?assertEqual(<<>>, Payload2),
    timer:sleep(50),

    test_send_coap_response(UdpSock,
                            "127.0.0.1",
                            ?PORT,
                            {ok, changed},
                            #coap_content{},
                            Request2,
                            true),
    timer:sleep(100),

    ReadResult = emqx_json:encode(#{
                                    <<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                                    <<"data">> => #{
                                                    <<"reqPath">> => <<"/3/0/9">>,
                                                    <<"code">> => <<"2.04">>,
                                                    <<"codeMsg">> => <<"changed">>
                                                   },
                                    <<"msgType">> => <<"write-attr">>
                                   }),
    ?assertEqual(ReadResult, test_recv_mqtt_response(RespTopic)).

case60_observe(Config) ->
    %% step 1, device register ...
    Epn = "urn:oma:lwm2m:oma:3",
    MsgId1 = 15,
    UdpSock = ?config(sock, Config),
    ObjectList = <<"</1>, </2>, </3/0>, </4>, </5>">>,
    RespTopic = list_to_binary("lwm2m/"++Epn++"/up/resp"),
    RespTopicAD = list_to_binary("lwm2m/"++Epn++"/up/notify"),
    emqtt:subscribe(?config(emqx_c, Config), RespTopic, qos0),
    emqtt:subscribe(?config(emqx_c, Config), RespTopicAD, qos0),
    timer:sleep(200),

    std_register(UdpSock, Epn, ObjectList, MsgId1, RespTopic),

    %% step2,  send a OBSERVE command to device
    CommandTopic = <<"lwm2m/", (list_to_binary(Epn))/binary, "/dn/dm">>,
    CmdId = 307,
    Command = #{<<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                <<"msgType">> => <<"observe">>,
                <<"data">> => #{
                                <<"path">> => <<"/3/0/10">>
                               }
               },
    CommandJson = emqx_json:encode(Command),
    test_mqtt_broker:publish(CommandTopic, CommandJson, 0),
    timer:sleep(50),
    Request2 = test_recv_coap_request(UdpSock),
    #coap_message{method = Method2, options=Options2, payload=Payload2} = Request2,
    Path2 = get_coap_path(Options2),
    Observe = get_coap_observe(Options2),
    ?assertEqual(get, Method2),
    ?assertEqual(<<"/3/0/10">>, Path2),
    ?assertEqual(Observe, 0),
    ?assertEqual(<<>>, Payload2),
    timer:sleep(50),

    test_send_coap_observe_ack( UdpSock,
                                "127.0.0.1",
                                ?PORT,
                                {ok, content},
                                #coap_content{content_format = <<"text/plain">>, payload = <<"2048">>},
                                Request2),
    timer:sleep(100),

    ReadResult = emqx_json:encode(#{
                                    <<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                                    <<"msgType">> => <<"observe">>,
                                    <<"data">> => #{
                                                    <<"reqPath">> => <<"/3/0/10">>,
                                                    <<"code">> => <<"2.05">>,
                                                    <<"codeMsg">> => <<"content">>,
                                                    <<"content">> => [#{
                                                                        path => <<"/3/0/10">>,
                                                                        value => 2048
                                                                       }]
                                                   }
                                   }),
    ?assertEqual(ReadResult, test_recv_mqtt_response(RespTopic)),

    %% step3 the notifications
    timer:sleep(200),
    ObSeq = 3,
    test_send_coap_notif(   UdpSock,
                            "127.0.0.1",
                            ?PORT,
                            #coap_content{content_format = <<"text/plain">>, payload = <<"4096">>},
                            ObSeq,
                            Request2),
    timer:sleep(100),
    #coap_message{} = test_recv_coap_response(UdpSock),

    ReadResult2 = emqx_json:encode(#{
                                     <<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                                     <<"msgType">> => <<"notify">>,
                                     <<"seqNum">> => ObSeq,
                                     <<"data">> => #{
                                                     <<"reqPath">> => <<"/3/0/10">>,
                                                     <<"code">> => <<"2.05">>,
                                                     <<"codeMsg">> => <<"content">>,
                                                     <<"content">> => [#{
                                                                         path => <<"/3/0/10">>,
                                                                         value => 4096
                                                                        }]
                                                    }
                                    }),
    ?assertEqual(ReadResult2, test_recv_mqtt_response(RespTopicAD)),

    %% Step3. cancel observe
    CmdId3 = 308,
    Command3 = #{<<"requestID">> => CmdId3, <<"cacheID">> => CmdId3,
                 <<"msgType">> => <<"cancel-observe">>,
                 <<"data">> => #{
                                 <<"path">> => <<"/3/0/10">>
                                }
                },
    CommandJson3 = emqx_json:encode(Command3),
    test_mqtt_broker:publish(CommandTopic, CommandJson3, 0),
    timer:sleep(50),
    Request3 = test_recv_coap_request(UdpSock),
    #coap_message{method = Method3, options=Options3, payload=Payload3} = Request3,
    Path3 = get_coap_path(Options3),
    Observe3 = get_coap_observe(Options3),
    ?assertEqual(get, Method3),
    ?assertEqual(<<"/3/0/10">>, Path3),
    ?assertEqual(Observe3, 1),
    ?assertEqual(<<>>, Payload3),
    timer:sleep(50),

    test_send_coap_observe_ack( UdpSock,
                                "127.0.0.1",
                                ?PORT,
                                {ok, content},
                                #coap_content{content_format = <<"text/plain">>, payload = <<"1150">>},
                                Request3),
    timer:sleep(100),

    ReadResult3 = emqx_json:encode(#{
                                     <<"requestID">> => CmdId3, <<"cacheID">> => CmdId3,
                                     <<"msgType">> => <<"cancel-observe">>,
                                     <<"data">> => #{
                                                     <<"reqPath">> => <<"/3/0/10">>,
                                                     <<"code">> => <<"2.05">>,
                                                     <<"codeMsg">> => <<"content">>,
                                                     <<"content">> => [#{
                                                                         path => <<"/3/0/10">>,
                                                                         value => 1150
                                                                        }]
                                                    }
                                    }),
    ?assertEqual(ReadResult3, test_recv_mqtt_response(RespTopic)).

%% case80_specail_object_19_0_0_notify(Config) ->
%%                                                %% step 1, device register, with extra register options
%%     Epn = "urn:oma:lwm2m:oma:3",
%%     RegOptionWangYi = "&apn=psmA.eDRX0.ctnb&im=13456&ct=2.0&mt=MDM9206&mv=4.0",
%%     MsgId1 = 15,
%%     UdpSock = ?config(sock, Config),

%%     RespTopic = list_to_binary("lwm2m/"++Epn++"/up/resp"),
%%     emqtt:subscribe(?config(emqx_c, Config), RespTopic, qos0),
%%     timer:sleep(200),

%%     test_send_coap_request( UdpSock,
%%                             post,
%%                             sprintf("coap://127.0.0.1:~b/rd?ep=~s&lt=345&lwm2m=1"++RegOptionWangYi, [?PORT, Epn]),
%%                             #coap_content{content_format = <<"text/plain">>, payload = <<"</1>, </2>, </3>, </4>, </5>">>},
%%                             [],
%%                             MsgId1),
%%     #coap_message{method = Method1} = test_recv_coap_response(UdpSock),
%%     ?assertEqual({ok,created}, Method1),
%%     ReadResult = emqx_json:encode(#{
%%                                     <<"msgType">> => <<"register">>,
%%                                     <<"data">> => #{
%%                                                     <<"alternatePath">> => <<"/">>,
%%                                                     <<"ep">> => list_to_binary(Epn),
%%                                                     <<"lt">> => 345,
%%                                                     <<"lwm2m">> => <<"1">>,
%%                                                     <<"objectList">> => [<<"/1">>, <<"/2">>, <<"/3">>, <<"/4">>, <<"/5">>],
%%                                                     <<"apn">> => <<"psmA.eDRX0.ctnb">>,
%%                                                     <<"im">> => <<"13456">>,
%%                                                     <<"ct">> => <<"2.0">>,
%%                                                     <<"mt">> => <<"MDM9206">>,
%%                                                     <<"mv">> => <<"4.0">>
%%                                                    }
%%                                    }),
%%     ?assertEqual(ReadResult, test_recv_mqtt_response(RespTopic)),

%%                                                %% step2,  send a OBSERVE command to device
%%     CommandTopic = <<"lwm2m/", (list_to_binary(Epn))/binary, "/dn/dm">>,
%%     CmdId = 307,
%%     Command = #{<<"requestID">> => CmdId, <<"cacheID">> => CmdId,
%%                 <<"msgType">> => <<"observe">>,
%%                 <<"data">> => #{
%%                                 <<"path">> => <<"/19/0/0">>
%%                                }
%%                },
%%     CommandJson = emqx_json:encode(Command),
%%     test_mqtt_broker:publish(CommandTopic, CommandJson, 0),
%%     timer:sleep(50),
%%     Request2 = test_recv_coap_request(UdpSock),
%%     #coap_message{method = Method2, options=Options2, payload=Payload2} = Request2,
%%     Path2 = get_coap_path(Options2),
%%     Observe = get_coap_observe(Options2),
%%     ?assertEqual(get, Method2),
%%     ?assertEqual(<<"/19/0/0">>, Path2),
%%     ?assertEqual(Observe, 0),
%%     ?assertEqual(<<>>, Payload2),
%%     timer:sleep(50),

%%     test_send_coap_observe_ack( UdpSock,
%%                                 "127.0.0.1",
%%                                 ?PORT,
%%                                 {ok, content},
%%                                 #coap_content{content_format = <<"text/plain">>, payload = <<"2048">>},
%%                                 Request2),
%%     timer:sleep(100).

%% step 3, device send uplink data notifications

%% case80_specail_object_19_1_0_write(Config) ->
%%     Epn = "urn:oma:lwm2m:oma:3",
%%     RegOptionWangYi = "&apn=psmA.eDRX0.ctnb&im=13456&ct=2.0&mt=MDM9206&mv=4.0",
%%     MsgId1 = 15,
%%     UdpSock = ?config(sock, Config),
%%     RespTopic = list_to_binary("lwm2m/"++Epn++"/up/resp"),
%%     emqtt:subscribe(?config(emqx_c, Config), RespTopic, qos0),
%%     timer:sleep(200),

%%     test_send_coap_request( UdpSock,
%%                             post,
%%                             sprintf("coap://127.0.0.1:~b/rd?ep=~s&lt=345&lwm2m=1"++RegOptionWangYi, [?PORT, Epn]),
%%                             #coap_content{content_format = <<"text/plain">>, payload = <<"</1>, </2>, </3>, </4>, </5>">>},
%%                             [],
%%                             MsgId1),
%%     #coap_message{method = Method1} = test_recv_coap_response(UdpSock),
%%     ?assertEqual({ok,created}, Method1),
%%     test_recv_mqtt_response(RespTopic),

%%                                                %% step2,  send a WRITE command to device
%%     CommandTopic = <<"lwm2m/", (list_to_binary(Epn))/binary, "/dn/dm">>,
%%     CmdId = 307,
%%     Command = #{<<"requestID">> => CmdId, <<"cacheID">> => CmdId,
%%                 <<"msgType">> => <<"write">>,
%%                 <<"data">> => #{
%%                                 <<"path">> => <<"/19/1/0">>,
%%                                 <<"type">> => <<"Opaque">>,
%%                                 <<"value">> => base64:encode(<<12345:32>>)
%%                                }
%%                },

%%     CommandJson = emqx_json:encode(Command),
%%     test_mqtt_broker:publish(CommandTopic, CommandJson, 0),
%%     timer:sleep(50),
%%     Request2 = test_recv_coap_request(UdpSock),
%%     #coap_message{method = Method2, options=Options2, payload=Payload2} = Request2,
%%     Path2 = get_coap_path(Options2),
%%     ?assertEqual(put, Method2),
%%     ?assertEqual(<<"/19/1/0">>, Path2),
%%     ?assertEqual(<<3:2, 0:1, 0:2, 4:3, 0, 12345:32>>, Payload2),
%%     timer:sleep(50),

%%     test_send_coap_response(UdpSock, "127.0.0.1", ?PORT, {ok, changed}, #coap_content{}, Request2, true),
%%     timer:sleep(100),

%%     ReadResult = emqx_json:encode(#{
%%                                     <<"requestID">> => CmdId, <<"cacheID">> => CmdId,
%%                                     <<"data">> => #{
%%                                                     <<"reqPath">> => <<"/19/1/0">>,
%%                                                     <<"code">> => <<"2.04">>,
%%                                                     <<"codeMsg">> => <<"changed">>
%%                                                    },
%%                                     <<"msgType">> => <<"write">>
%%                                    }),
%%     ?assertEqual(ReadResult, test_recv_mqtt_response(RespTopic)).

case90_psm_mode(Config) ->
    server_cache_mode(Config, "ep=~s&lt=345&lwm2m=1&apn=psmA.eDRX0.ctnb").

case90_queue_mode(Config) ->
    server_cache_mode(Config, "ep=~s&lt=345&lwm2m=1&b=UQ").

server_cache_mode(Config, RegOption) ->
    #{lwm2m := LwM2M} = Gateway = emqx:get_config([gateway]),
    Gateway2 = Gateway#{lwm2m := LwM2M#{qmode_time_window => 2}},
    emqx_config:put([gateway], Gateway2),
    %% step 1, device register, with apn indicates "PSM" mode
    Epn = "urn:oma:lwm2m:oma:3",

    MsgId1 = 15,
    UdpSock = ?config(sock, Config),
    RespTopic = list_to_binary("lwm2m/"++Epn++"/up/resp"),
    emqtt:subscribe(?config(emqx_c, Config), RespTopic, qos0),
    timer:sleep(200),

    test_send_coap_request( UdpSock,
                            post,
                            sprintf("coap://127.0.0.1:~b/rd?"++RegOption, [?PORT, Epn]),
                            #coap_content{content_format = <<"text/plain">>, payload = <<"</1>, </2>, </3>, </4>, </5>">>},
                            [],
                            MsgId1),
    #coap_message{type = ack, method = Method1, options = Opts} = test_recv_coap_response(UdpSock),
    ?assertEqual({ok,created}, Method1),
    ?LOGT("Options got: ~p", [Opts]),
    Location = proplists:get_value(location_path, Opts),
    test_recv_mqtt_response(RespTopic),

    %% server not in PSM mode
    send_read_command_1(0, UdpSock),
    verify_read_response_1(0, UdpSock),

    %% server inters into PSM mode
    timer:sleep(2),

    %% verify server caches downlink commands
    send_read_command_1(1, UdpSock),
    send_read_command_1(2, UdpSock),
    send_read_command_1(3, UdpSock),

    ?assertEqual(timeout_test_recv_coap_request, test_recv_coap_request(UdpSock)),

    device_update_1(UdpSock, Location),

    verify_read_response_1(1, UdpSock),
    verify_read_response_1(2, UdpSock),
    verify_read_response_1(3, UdpSock).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Internal Functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

send_read_command_1(CmdId, _UdpSock) ->
    Epn = "urn:oma:lwm2m:oma:3",
    CommandTopic = <<"lwm2m/", (list_to_binary(Epn))/binary, "/dn/dm">>,
    Command =   #{
                  <<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                  <<"msgType">> => <<"read">>,
                  <<"data">> => #{
                                  <<"path">> => <<"/3/0/0">>
                                 }
                 },
    CommandJson = emqx_json:encode(Command),
    test_mqtt_broker:publish(CommandTopic, CommandJson, 0),
    timer:sleep(50).

verify_read_response_1(CmdId, UdpSock) ->
    Epn = "urn:oma:lwm2m:oma:3",
    RespTopic = list_to_binary("lwm2m/"++Epn++"/up/resp"),

    %% device receives a command
    Request = test_recv_coap_request(UdpSock),
    ?LOGT("LwM2M client got ~p", [Request]),

    %% device replies the commond
    test_send_coap_response(UdpSock, "127.0.0.1", ?PORT, {ok, content}, #coap_content{content_format = <<"text/plain">>, payload = <<"EMQ">>}, Request, true),

    ReadResult = emqx_json:encode(#{  <<"requestID">> => CmdId, <<"cacheID">> => CmdId,
                                      <<"msgType">> => <<"read">>,
                                      <<"data">> => #{
                                                      <<"code">> => <<"2.05">>,
                                                      <<"codeMsg">> => <<"content">>,
                                                      <<"content">> => [#{
                                                                          path => <<"/3/0/0">>,
                                                                          value => <<"EMQ">>
                                                                         }]
                                                     }
                                   }),
    ?assertEqual(ReadResult, test_recv_mqtt_response(RespTopic)).

device_update_1(UdpSock, Location) ->
    Epn = "urn:oma:lwm2m:oma:3",
    RespTopic = list_to_binary("lwm2m/"++Epn++"/up/resp"),
    ?LOGT("send UPDATE command", []),
    MsgId2 = 27,
    test_send_coap_request( UdpSock,
                            post,
                            sprintf("coap://127.0.0.1:~b~s?lt=789", [?PORT, join_path(Location, <<>>)]),
                            #coap_content{payload = <<>>},
                            [],
                            MsgId2),
    #coap_message{type = ack, id = MsgId2, method = Method2} = test_recv_coap_response(UdpSock),
    {ok,changed} = Method2,
    test_recv_mqtt_response(RespTopic).

test_recv_mqtt_response(RespTopic) ->
    receive
        {publish, #{topic := RespTopic, payload := RM}} ->
            ?LOGT("test_recv_mqtt_response Response=~p", [RM]),
            RM
    after 1000 -> timeout_test_recv_mqtt_response
    end.

test_send_coap_request(UdpSock, Method, Uri, Content, Options, MsgId) ->
    is_record(Content, coap_content) orelse error("Content must be a #coap_content!"),
    is_list(Options) orelse error("Options must be a list"),
    case resolve_uri(Uri) of
        {coap, {IpAddr, Port}, Path, Query} ->
            Request0 = lwm2m_coap_message:request(con, Method, Content, [{uri_path, Path}, {uri_query, Query} | Options]),
            Request = Request0#coap_message{id = MsgId},
            ?LOGT("send_coap_request Request=~p", [Request]),
            RequestBinary = lwm2m_coap_message_parser:encode(Request),
            ?LOGT("test udp socket send to ~p:~p, data=~p", [IpAddr, Port, RequestBinary]),
            ok = gen_udp:send(UdpSock, IpAddr, Port, RequestBinary);
        {SchemeDiff, ChIdDiff, _, _} ->
            error(lists:flatten(io_lib:format("scheme ~s or ChId ~s does not match with socket", [SchemeDiff, ChIdDiff])))
    end.

test_recv_coap_response(UdpSock) ->
    {ok, {Address, Port, Packet}} = gen_udp:recv(UdpSock, 0, 2000),
    Response = lwm2m_coap_message_parser:decode(Packet),
    ?LOGT("test udp receive from ~p:~p, data1=~p, Response=~p", [Address, Port, Packet, Response]),
    #coap_message{type = ack, method = Method, id=Id, token = Token, options = Options, payload = Payload} = Response,
    ?LOGT("receive coap response Method=~p, Id=~p, Token=~p, Options=~p, Payload=~p", [Method, Id, Token, Options, Payload]),
    Response.

test_recv_coap_request(UdpSock) ->
    case gen_udp:recv(UdpSock, 0, 2000) of
        {ok, {_Address, _Port, Packet}} ->
            Request = lwm2m_coap_message_parser:decode(Packet),
            #coap_message{type = con, method = Method, id=Id, token = Token, payload = Payload, options = Options} = Request,
            ?LOGT("receive coap request Method=~p, Id=~p, Token=~p, Options=~p, Payload=~p", [Method, Id, Token, Options, Payload]),
            Request;
        {error, Reason} ->
            ?LOGT("test_recv_coap_request failed, Reason=~p", [Reason]),
            timeout_test_recv_coap_request
    end.

test_send_coap_response(UdpSock, Host, Port, Code, Content, Request, Ack) ->
    is_record(Content, coap_content) orelse error("Content must be a #coap_content!"),
    is_list(Host) orelse error("Host is not a string"),

    {ok, IpAddr} = inet:getaddr(Host, inet),
    Response = lwm2m_coap_message:response(Code, Content, Request),
    Response2 = case Ack of
                    true -> Response#coap_message{type = ack};
                    false -> Response
                end,
    ?LOGT("test_send_coap_response Response=~p", [Response2]),
    ok = gen_udp:send(UdpSock, IpAddr, Port, lwm2m_coap_message_parser:encode(Response2)).

test_send_empty_ack(UdpSock, Host, Port, Request) ->
    is_list(Host) orelse error("Host is not a string"),
    {ok, IpAddr} = inet:getaddr(Host, inet),
    EmptyACK = lwm2m_coap_message:ack(Request),
    ?LOGT("test_send_empty_ack EmptyACK=~p", [EmptyACK]),
    ok = gen_udp:send(UdpSock, IpAddr, Port, lwm2m_coap_message_parser:encode(EmptyACK)).

test_send_coap_observe_ack(UdpSock, Host, Port, Code, Content, Request) ->
    is_record(Content, coap_content) orelse error("Content must be a #coap_content!"),
    is_list(Host) orelse error("Host is not a string"),

    {ok, IpAddr} = inet:getaddr(Host, inet),
    Response = lwm2m_coap_message:response(Code, Content, Request),
    Response1 = lwm2m_coap_message:set(observe, 0, Response),
    Response2 = Response1#coap_message{type = ack},

    ?LOGT("test_send_coap_observe_ack Response=~p", [Response2]),
    ResponseBinary = lwm2m_coap_message_parser:encode(Response2),
    ok = gen_udp:send(UdpSock, IpAddr, Port, ResponseBinary).

test_send_coap_notif(UdpSock, Host, Port, Content, ObSeq, Request) ->
    is_record(Content, coap_content) orelse error("Content must be a #coap_content!"),
    is_list(Host) orelse error("Host is not a string"),

    {ok, IpAddr} = inet:getaddr(Host, inet),
    Notif = lwm2m_coap_message:response({ok, content}, Content, Request),
    NewNotif = lwm2m_coap_message:set(observe, ObSeq, Notif),
    ?LOGT("test_send_coap_notif Response=~p", [NewNotif]),
    NotifBinary = lwm2m_coap_message_parser:encode(NewNotif),
    ?LOGT("test udp socket send to ~p:~p, data=~p", [IpAddr, Port, NotifBinary]),
    ok = gen_udp:send(UdpSock, IpAddr, Port, NotifBinary).

std_register(UdpSock, Epn, ObjectList, MsgId1, RespTopic) ->
    test_send_coap_request( UdpSock,
                            post,
                            sprintf("coap://127.0.0.1:~b/rd?ep=~s&lt=345&lwm2m=1", [?PORT, Epn]),
                            #coap_content{content_format = <<"text/plain">>, payload = ObjectList},
                            [],
                            MsgId1),
    #coap_message{method = {ok,created}} = test_recv_coap_response(UdpSock),
    test_recv_mqtt_response(RespTopic),
    timer:sleep(100).

resolve_uri(Uri) ->
    {ok, #{scheme := Scheme,
           host := Host,
           port := PortNo,
           path := Path} = URIMap} = emqx_http_lib:uri_parse(Uri),
    Query = maps:get(query, URIMap, ""),
    {ok, PeerIP} = inet:getaddr(Host, inet),
    {Scheme, {PeerIP, PortNo}, split_path(Path), split_query(Query)}.

split_path([]) -> [];
split_path([$/]) -> [];
split_path([$/ | Path]) -> split_segments(Path, $/, []).

split_query([]) -> [];
split_query(Path) -> split_segments(Path, $&, []).

split_segments(Path, Char, Acc) ->
    case string:rchr(Path, Char) of
        0 ->
            [make_segment(Path) | Acc];
        N when N > 0 ->
            split_segments(string:substr(Path, 1, N-1), Char,
                [make_segment(string:substr(Path, N+1)) | Acc])
    end.

make_segment(Seg) ->
    list_to_binary(emqx_http_lib:uri_decode(Seg)).


get_coap_path(Options) ->
    get_path(Options, <<>>).

get_coap_query(Options) ->
    proplists:get_value(uri_query, Options, []).

get_coap_observe(Options) ->
    get_observe(Options).


get_path([], Acc) ->
    %?LOGT("get_path Acc=~p", [Acc]),
    Acc;
get_path([{uri_path, Path1}|T], Acc) ->
    %?LOGT("Path=~p, Acc=~p", [Path1, Acc]),
    get_path(T, join_path(Path1, Acc));
get_path([{_, _}|T], Acc) ->
    get_path(T, Acc).

get_observe([]) ->
    undefined;
get_observe([{observe, V}|_T]) ->
    V;
get_observe([{_, _}|T]) ->
    get_observe(T).

join_path([], Acc) -> Acc;
join_path([<<"/">>|T], Acc) ->
    join_path(T, Acc);
join_path([H|T], Acc) ->
    join_path(T, <<Acc/binary, $/, H/binary>>).

sprintf(Format, Args) ->
    lists:flatten(io_lib:format(Format, Args)).
