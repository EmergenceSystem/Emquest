%%%-------------------------------------------------------------------
%%% @doc emquest_media — image upload/proxy routes.
%%%
%%% Split out of `emquest_handler'. Handles:
%%%   POST /media              — an uploaded image (multipart) or an
%%%                              image URL ({"url":...}), routed to velora
%%%                              and answered with a raster card.
%%%   GET  /media/prepare/:id  — proxy one poll of velora's async render.
%%%
%%% (Speech-to-text now runs on-device in the browser; the former
%%% server-side POST /stt route and its whisper.cpp proxy were removed.)
%%%
%%% The route dispatch, method check and rate-limiting stay in
%%% `emquest_handler'; each entry point here returns the Cowboy
%%% `{ok, Req, Tag}' triple ready to hand back.
%%% @end
%%%-------------------------------------------------------------------
-module(emquest_media).

-export([media_post/1, prepare/2]).

%%====================================================================
%% Route entry points
%%====================================================================

%% @doc POST /media dispatch: multipart upload vs JSON {"url":...}.
media_post(Req0) ->
    CT = cowboy_req:header(<<"content-type">>, Req0, <<>>),
    case binary:match(CT, <<"multipart/form-data">>) of
        nomatch -> media_url(Req0);
        _       -> media_upload(Req0)
    end.

%% @doc GET /media/prepare/:id — one proxied poll of velora's render.
prepare(Req0, Id) ->
    {Code, Body} = velora_prepare_poll(Id),
    {ok, cowboy_req:reply(Code, media_ct(), json:encode(Body), Req0), media_prepare}.

%%====================================================================
%% Media (image -> velora)
%%====================================================================

media_upload(Req0) ->
    case read_upload(Req0) of
        {ok, Filename, Bytes, Req1} ->
            case is_image_ext(Filename) of
                true  -> media_result(Req1, velora_upload_render(Filename, Bytes));
                false -> media_unsupported(Req1)
            end;
        {error, Reason, Req1} ->
            media_err(Req1, 400, Reason)
    end.

media_url(Req0) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case (try json:decode(Body) catch _:_ -> #{} end) of
        #{<<"url">> := Url} when is_binary(Url) ->
            case is_image_ext(Url) of
                true  -> media_result(Req1, fetch_url_render(Url));
                false -> media_unsupported(Req1)
            end;
        _ -> media_err(Req1, 400, missing_url)
    end.

%% velora's warp is asynchronous: answer the browser right away with a poll URL
%% (served at /media/prepare/:id) instead of blocking this request for the whole
%% render. A legacy synchronous velora still yields a ready card.
media_result(Req, {ok, {processing, PrepId}}) ->
    Body = #{<<"status">> => <<"processing">>,
             <<"prepare">> => PrepId,
             <<"poll">> => <<"/media/prepare/", PrepId/binary>>},
    {ok, cowboy_req:reply(202, media_ct(), json:encode(Body), Req), media};
media_result(Req, {ok, {ready, Card}}) ->
    {ok, cowboy_req:reply(200, media_ct(), json:encode(Card), Req), media};
media_result(Req, {error, Reason}) -> media_err(Req, 502, Reason).

media_unsupported(Req) ->
    {ok, cowboy_req:reply(415, media_ct(),
        json:encode(#{<<"error">> => <<"only images are supported for now">>}), Req), media}.

media_err(Req, Code, Reason) ->
    {ok, cowboy_req:reply(Code, media_ct(),
        json:encode(#{<<"error">> => media_ebin(Reason)}), Req), media}.

media_ct() -> #{<<"content-type">> => <<"application/json">>}.
media_ebin(B) when is_binary(B) -> B;
media_ebin(T) -> iolist_to_binary(io_lib:format("~p", [T])).

%%====================================================================
%% Multipart upload reading
%%====================================================================

%% Read the first multipart file part; returns {ok, Filename, Bytes, Req}.
read_upload(Req0) ->
    case cowboy_req:read_part(Req0) of
        {ok, Headers, Req1} ->
            case cow_multipart:form_data(Headers) of
                {file, _Field, Filename, _CType} ->
                    {Bytes, Req2} = read_part_all(Req1, <<>>),
                    {ok, Filename, Bytes, Req2};
                _ ->
                    {_, Req2} = read_part_all(Req1, <<>>),
                    read_upload(Req2)
            end;
        {done, Req1} -> {error, no_file, Req1}
    end.

read_part_all(Req0, Acc) ->
    case cowboy_req:read_part_body(Req0) of
        {ok, Data, Req1}   -> {<<Acc/binary, Data/binary>>, Req1};
        {more, Data, Req1} -> read_part_all(Req1, <<Acc/binary, Data/binary>>)
    end.

is_image_ext(Bin) ->
    L = string:lowercase(iolist_to_binary(Bin)),
    lists:any(fun(Ext) -> binary:match(L, Ext) =/= nomatch end,
              [<<".jpg">>, <<".jpeg">>, <<".png">>, <<".webp">>, <<".gif">>,
               <<".tif">>, <<".tiff">>, <<".jp2">>, <<".bmp">>]).

%%====================================================================
%% velora client
%%====================================================================

velora_base() -> application:get_env(emquest, velora_url, "http://localhost:8081").
tiles_base()  -> list_to_binary(application:get_env(emquest, velora_tiles_base, "https://velora.roques.me")).

%% File path: upload to velora, render, build an absolute-tiles raster card.
velora_upload_render(Filename, Bytes) ->
    {Boundary, MBody} = build_multipart(Filename, Bytes),
    UpCT = "multipart/form-data; boundary=" ++ Boundary,
    case httpc:request(post, {velora_base() ++ "/uploads", [], UpCT, MBody},
                       [{timeout, 30000}], [{body_format, binary}]) of
        {ok, {{_, S, _}, _, UpResp}} when S =:= 200; S =:= 201 ->
            case (try json:decode(UpResp) catch _:_ -> #{} end) of
                #{<<"uri">> := Uri} -> velora_render(Uri);
                _ -> {error, bad_upload_response}
            end;
        {ok, {{_, C, _}, _, _}} -> {error, {upload_http, C}};
        {error, R} -> {error, R}
    end.

%% Kick off velora's async warp. /render answers 202 {status:processing, prepare}
%% instantly (the warp is backgrounded), so this returns the prepare id for the
%% browser to poll — it does NOT block on the render. A legacy synchronous velora
%% (a ready {id,...}) still yields a ready card.
velora_render(Uri) ->
    RBody = iolist_to_binary(json:encode(#{<<"uri">> => Uri})),
    case httpc:request(post, {velora_base() ++ "/render",
                              [{"content-type", "application/json"}],
                              "application/json", RBody},
                       [{timeout, 15000}], [{body_format, binary}]) of
        {ok, {{_, S, _}, _, Resp}} when S =:= 200; S =:= 202 ->
            case json:decode(Resp) of
                #{<<"status">> := <<"processing">>, <<"prepare">> := P} ->
                    {ok, {processing, P}};
                #{<<"id">> := _} = M -> {ok, {ready, render_card(M)}}
            end;
        {ok, {{_, C, _}, _, _}} -> {error, {render_http, C}};
        {error, R} -> {error, R}
    end.

%% One poll of velora's async prepare, proxied for /media/prepare/:id. Maps
%% velora's /prepare/:id answer to {HttpCode, JsonBody} for the browser.
velora_prepare_poll(Id) ->
    Url = velora_base() ++ "/prepare/" ++ binary_to_list(Id),
    case httpc:request(get, {Url, []}, [{timeout, 15000}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, B}} ->
            case (try json:decode(B) catch _:_ -> #{} end) of
                #{<<"status">> := <<"done">>} = D ->
                    {200, (render_card(D))#{<<"status">> => <<"done">>}};
                #{<<"status">> := <<"error">>} = E ->
                    {200, #{<<"status">> => <<"error">>,
                            <<"error">> => media_ebin(maps:get(<<"error">>, E, <<"error">>))}};
                _ ->
                    {200, #{<<"status">> => <<"processing">>}}
            end;
        {ok, {{_, 404, _}, _, _}} -> {404, #{<<"status">> => <<"not_found">>}};
        {ok, {{_, C, _}, _, _}}   -> {502, #{<<"error">> => media_ebin({prepare_http, C})}};
        {error, R}                -> {502, #{<<"error">> => media_ebin(R)}}
    end.

render_card(M) ->
    Id = maps:get(<<"id">>, M),
    NZ = maps:get(<<"maxNativeZoom">>, M, 19),
    #{<<"type">> => <<"raster">>, <<"id">> => Id,
      <<"bounds">> => maps:get(<<"bounds">>, M, null),
      <<"maxNativeZoom">> => NZ,
      <<"tiles">> => <<(tiles_base())/binary, "/tiles/", Id/binary, "/{z}/{x}/{y}">>}.

%% URL path: Emquest fetches the image itself (a normal GET works with hosts that
%% reject GDAL's /vsicurl Range requests, e.g. Wikimedia), then uploads the bytes
%% to velora — the same path as a file upload. Avoids /vsicurl entirely.
fetch_url_render(Url) ->
    case fetch_image(Url) of
        {ok, Bytes} -> velora_upload_render(url_filename(Url), Bytes);
        {error, R}  -> {error, R}
    end.

fetch_image(Url) ->
    _ = application:ensure_all_started(ssl),
    emquest_safeurl:safe_get(Url,
        [{"User-Agent", "velora/1.0"}, {"accept", "image/*"}],
        [{timeout, 30000}]).

url_filename(Url) ->
    Path = case binary:split(Url, <<"?">>) of [P | _] -> P; _ -> Url end,
    case binary:split(Path, <<"/">>, [global, trim_all]) of
        [] -> <<"image">>;
        Ps -> lists:last(Ps)
    end.

build_multipart(Filename, Bytes) ->
    B  = "----emq" ++ integer_to_list(erlang:unique_integer([positive])),
    FN = binary_to_list(iolist_to_binary(Filename)),
    Body = iolist_to_binary([
        "--", B, "\r\n",
        "Content-Disposition: form-data; name=\"file\"; filename=\"", FN, "\"\r\n",
        "Content-Type: application/octet-stream\r\n\r\n",
        Bytes, "\r\n", "--", B, "--\r\n"]),
    {B, Body}.
