% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

% @doc
% This module decodes and validates JWT tokens. Almost all property
% checks are optional. If not checked, the presence or validity of the
% field is not verified. Signature check is mandatory, though.

-module(jwtf).

-export([
    encode/3,
    decode/3
]).

-define(ALGS, [
    {<<"RS256">>, {public_key, sha256}}, % RSA PKCS#1 signature with SHA-256
    {<<"RS384">>, {public_key, sha384}},
    {<<"RS512">>, {public_key, sha512}},
    {<<"ES256">>, {public_key, sha256}},
    {<<"ES384">>, {public_key, sha384}},
    {<<"ES512">>, {public_key, sha512}},
    {<<"HS256">>, {hmac, sha256}},
    {<<"HS384">>, {hmac, sha384}},
    {<<"HS512">>, {hmac, sha512}}]).

-define(VALID_ALGS, proplists:get_keys(?ALGS)).


% @doc encode
% Encode the JSON Header and Claims using Key and Alg obtained from Header
-spec encode(term(), term(), term()) ->
    {ok, binary()} | no_return().
encode(Header = {HeaderProps}, Claims, Key) ->
    try
        Alg = case prop(<<"alg">>, HeaderProps) of
            undefined ->
                throw(missing_alg);
            Val ->
                Val
        end,
        EncodedHeader = b64url:encode(jiffy:encode(Header)),
        EncodedClaims = b64url:encode(jiffy:encode(Claims)),
        Message = <<EncodedHeader/binary, $., EncodedClaims/binary>>,
        SignatureOrMac = case verification_algorithm(Alg) of
            {public_key, Algorithm} ->
                public_key:sign(Message, Algorithm, Key);
            {hmac, Algorithm} ->
                crypto:hmac(Algorithm, Key, Message)
        end,
        EncodedSignatureOrMac = b64url:encode(SignatureOrMac),
        {ok, <<Message/binary, $., EncodedSignatureOrMac/binary>>}
    catch
        throw:Error ->
            {error, Error}
    end.


% @doc decode
% Decodes the supplied encoded token, checking
% for the attributes defined in Checks and calling
% the key store function to retrieve the key needed
% to verify the signature
decode(EncodedToken, Checks, KS) ->
    try
        [Header, Payload, Signature] = split(EncodedToken),
        validate(Header, Payload, Signature, Checks, KS),
        {ok, decode_json(Payload)}
    catch
        throw:Error ->
            {error, Error}
    end.


% @doc verification_algorithm
% Return {VerificationMethod, Algorithm} tuple for the specified Alg
-spec verification_algorithm(binary()) ->
    {atom(), atom()} | no_return().
verification_algorithm(Alg) ->
    case lists:keyfind(Alg, 1, ?ALGS) of
        {Alg, Val} ->
            Val;
        false ->
            throw(invalid_alg)
    end.


validate(Header0, Payload0, Signature, Checks, KS) ->
    Header1 = props(decode_json(Header0)),
    validate_header(Header1, Checks),

    Payload1 = props(decode_json(Payload0)),
    validate_payload(Payload1, Checks),

    Alg = prop(<<"alg">>, Header1),
    Key = key(Header1, Checks, KS),
    verify(Alg, Header0, Payload0, Signature, Key).


validate_header(Props, Checks) ->
    validate_typ(Props, Checks),
    validate_alg(Props, Checks).


validate_typ(Props, Checks) ->
    Required = prop(typ, Checks),
    TYP = prop(<<"typ">>, Props),
    case {Required, TYP} of
        {undefined, _} ->
            ok;
        {true, undefined} ->
            throw(missing_typ);
        {true, <<"JWT">>} ->
            ok;
        {true, _} ->
            throw(invalid_typ)
    end.


validate_alg(Props, Checks) ->
    Required = prop(alg, Checks),
    Alg = prop(<<"alg">>, Props),
    case {Required, Alg} of
        {undefined, _} ->
            ok;
        {true, undefined} ->
            throw(missing_alg);
        {true, Alg} ->
            case lists:member(Alg, ?VALID_ALGS) of
                true ->
                    ok;
                false ->
                    throw(invalid_alg)
            end
    end.


%% Not all these fields have to be present, but if they _are_ present
%% they must be valid.
validate_payload(Props, Checks) ->
    validate_iss(Props, Checks),
    validate_iat(Props, Checks),
    validate_nbf(Props, Checks),
    validate_exp(Props, Checks).


validate_iss(Props, Checks) ->
    ExpectedISS = prop(iss, Checks),
    ActualISS = prop(<<"iss">>, Props),

    case {ExpectedISS, ActualISS} of
        {undefined, _} ->
            ok;
        {_ISS, undefined} ->
            throw(missing_iss);
        {ISS, ISS} ->
            ok;
        {_, _} ->
            throw(invalid_iss)
    end.


validate_iat(Props, Checks) ->
    Required = prop(iat, Checks),
    IAT = prop(<<"iat">>, Props),

    case {Required, IAT} of
        {undefined, _} ->
            ok;
        {true, undefined} ->
            throw(missing_iat);
        {true, IAT} when is_integer(IAT) ->
            ok;
        {true, _} ->
            throw(invalid_iat)
    end.


validate_nbf(Props, Checks) ->
    Required = prop(nbf, Checks),
    NBF = prop(<<"nbf">>, Props),

    case {Required, NBF} of
        {undefined, _} ->
            ok;
        {true, undefined} ->
            throw(missing_nbf);
        {true, IAT} ->
            assert_past(<<"nbf">>, IAT)
    end.


validate_exp(Props, Checks) ->
    Required = prop(exp, Checks),
    EXP = prop(<<"exp">>, Props),

    case {Required, EXP} of
        {undefined, _} ->
            ok;
        {true, undefined} ->
            throw(missing_exp);
        {true, EXP} ->
            assert_future(<<"exp">>, EXP)
    end.


key(Props, Checks, KS) ->
    Alg = prop(<<"alg">>, Props),
    Required = prop(kid, Checks),
    KID = prop(<<"kid">>, Props),
    case {Required, KID} of
        {true, undefined} ->
            throw(missing_kid);
        {_, KID} ->
            KS(Alg, KID)
    end.


verify(Alg, Header, Payload, SignatureOrMac0, Key) ->
    Message = <<Header/binary, $., Payload/binary>>,
    SignatureOrMac1 = b64url:decode(SignatureOrMac0),
    {VerificationMethod, Algorithm} = verification_algorithm(Alg),
    case VerificationMethod of
        public_key ->
            public_key_verify(Algorithm, Message, SignatureOrMac1, Key);
        hmac ->
            hmac_verify(Algorithm, Message, SignatureOrMac1, Key)
    end.


public_key_verify(Algorithm, Message, Signature, PublicKey) ->
    case public_key:verify(Message, Algorithm, Signature, PublicKey) of
        true ->
            ok;
        false ->
            throw(bad_signature)
    end.


hmac_verify(Algorithm, Message, HMAC, SecretKey) ->
    case crypto:hmac(Algorithm, SecretKey, Message) of
        HMAC ->
            ok;
        _ ->
            throw(bad_hmac)
    end.


split(EncodedToken) ->
    case binary:split(EncodedToken, <<$.>>, [global]) of
        [_, _, _] = Split -> Split;
        _ -> throw(malformed_token)
    end.


decode_json(Encoded) ->
    case b64url:decode(Encoded) of
        {error, Reason} ->
            throw(Reason);
        Decoded ->
            jiffy:decode(Decoded)
    end.

props({Props}) ->
    Props;

props(_) ->
    throw(not_object).


assert_past(Name, Time) ->
    case Time < now_seconds() of
        true ->
            ok;
        false ->
            throw(<<Name/binary, " not in past">>)
    end.

assert_future(Name, Time) ->
    case Time > now_seconds() of
        true ->
            ok;
        false ->
            throw(<<Name/binary, " not in future">>)
    end.


now_seconds() ->
    {MegaSecs, Secs, _MicroSecs} = os:timestamp(),
    MegaSecs * 1000000 + Secs.


prop(Prop, Props) ->
    proplists:get_value(Prop, Props).


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

encode(Header0, Payload0) ->
    Header1 = b64url:encode(jiffy:encode(Header0)),
    Payload1 = b64url:encode(jiffy:encode(Payload0)),
    Sig = b64url:encode(<<"bad">>),
    <<Header1/binary, $., Payload1/binary, $., Sig/binary>>.

valid_header() ->
    {[{<<"typ">>, <<"JWT">>}, {<<"alg">>, <<"RS256">>}]}.

jwt_io_pubkey() ->
    PublicKeyPEM = <<"-----BEGIN PUBLIC KEY-----\n"
                  "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDdlatRjRjogo3WojgGH"
                  "FHYLugdUWAY9iR3fy4arWNA1KoS8kVw33cJibXr8bvwUAUparCwlvdbH6"
                  "dvEOfou0/gCFQsHUfQrSDv+MuSUMAe8jzKE4qW+jK+xQU9a03GUnKHkkl"
                  "e+Q0pX/g6jXZ7r1/xAK5Do2kQ+X5xK9cipRgEKwIDAQAB\n"
                  "-----END PUBLIC KEY-----\n">>,
    [PEMEntry] = public_key:pem_decode(PublicKeyPEM),
    public_key:pem_entry_decode(PEMEntry).


missing_typ_test() ->
    Encoded = encode({[]}, []),
    ?assertEqual({error, missing_typ}, decode(Encoded, [typ], nil)).


invalid_typ_test() ->
    Encoded = encode({[{<<"typ">>, <<"NOPE">>}]}, []),
    ?assertEqual({error, invalid_typ}, decode(Encoded, [typ], nil)).


missing_alg_test() ->
    Encoded = encode({[{<<"typ">>, <<"NOPE">>}]}, []),
    ?assertEqual({error, missing_alg}, decode(Encoded, [alg], nil)).


invalid_alg_test() ->
    Encoded = encode({[{<<"typ">>, <<"JWT">>}, {<<"alg">>, <<"NOPE">>}]}, []),
    ?assertEqual({error, invalid_alg}, decode(Encoded, [alg], nil)).


missing_iss_test() ->
    Encoded = encode(valid_header(), {[]}),
    ?assertEqual({error, missing_iss}, decode(Encoded, [{iss, right}], nil)).


invalid_iss_test() ->
    Encoded = encode(valid_header(), {[{<<"iss">>, <<"wrong">>}]}),
    ?assertEqual({error, invalid_iss}, decode(Encoded, [{iss, right}], nil)).


missing_iat_test() ->
    Encoded = encode(valid_header(), {[]}),
    ?assertEqual({error, missing_iat}, decode(Encoded, [iat], nil)).


invalid_iat_test() ->
    Encoded = encode(valid_header(), {[{<<"iat">>, <<"hello">>}]}),
    ?assertEqual({error, invalid_iat}, decode(Encoded, [iat], nil)).


missing_nbf_test() ->
    Encoded = encode(valid_header(), {[]}),
    ?assertEqual({error, missing_nbf}, decode(Encoded, [nbf], nil)).


invalid_nbf_test() ->
    Encoded = encode(valid_header(), {[{<<"nbf">>, 32503680000}]}),
    ?assertEqual({error, <<"nbf not in past">>}, decode(Encoded, [nbf], nil)).


missing_exp_test() ->
    Encoded = encode(valid_header(), {[]}),
    ?assertEqual({error, missing_exp}, decode(Encoded, [exp], nil)).


invalid_exp_test() ->
    Encoded = encode(valid_header(), {[{<<"exp">>, 0}]}),
    ?assertEqual({error, <<"exp not in future">>}, decode(Encoded, [exp], nil)).


missing_kid_test() ->
    Encoded = encode({[]}, {[]}),
    ?assertEqual({error, missing_kid}, decode(Encoded, [kid], nil)).


public_key_not_found_test() ->
    Encoded = encode(
        {[{<<"alg">>, <<"RS256">>}, {<<"kid">>, <<"1">>}]},
        {[]}),
    KS = fun(_, _) -> throw(not_found) end,
    Expected = {error, not_found},
    ?assertEqual(Expected, decode(Encoded, [], KS)).


bad_rs256_sig_test() ->
    Encoded = encode(
        {[{<<"typ">>, <<"JWT">>}, {<<"alg">>, <<"RS256">>}]},
        {[]}),
    KS = fun(<<"RS256">>, undefined) -> jwt_io_pubkey() end,
    ?assertEqual({error, bad_signature}, decode(Encoded, [], KS)).


bad_hs256_sig_test() ->
    Encoded = encode(
        {[{<<"typ">>, <<"JWT">>}, {<<"alg">>, <<"HS256">>}]},
        {[]}),
    KS = fun(<<"HS256">>, undefined) -> <<"bad">> end,
    ?assertEqual({error, bad_hmac}, decode(Encoded, [], KS)).


malformed_token_test() ->
    ?assertEqual({error, malformed_token}, decode(<<"a.b.c.d">>, [], nil)).


%% jwt.io generated
hs256_test() ->
    EncodedToken = <<"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6IjEyMzQ1Ni"
                     "J9.eyJpc3MiOiJodHRwczovL2Zvby5jb20iLCJpYXQiOjAsImV4cCI"
                     "6MTAwMDAwMDAwMDAwMDAsImtpZCI6ImJhciJ9.iS8AH11QHHlczkBn"
                     "Hl9X119BYLOZyZPllOVhSBZ4RZs">>,
    KS = fun(<<"HS256">>, <<"123456">>) -> <<"secret">> end,
    Checks = [{iss, <<"https://foo.com">>}, iat, exp, typ, alg, kid],
    ?assertMatch({ok, _}, catch decode(EncodedToken, Checks, KS)).


%% pip install PyJWT
%% > import jwt
%% > jwt.encode({'foo':'bar'}, 'secret', algorithm='HS384')
hs384_test() ->
    EncodedToken = <<"eyJhbGciOiJIUzM4NCIsInR5cCI6IkpXVCJ9.eyJmb28iOiJiYXIif"
                     "Q.2quwghs6I56GM3j7ZQbn-ASZ53xdBqzPzTDHm_CtVec32LUy-Ezy"
                     "L3JjIe7WjL93">>,
    KS = fun(<<"HS384">>, _) -> <<"secret">> end,
    ?assertMatch({ok, {[{<<"foo">>,<<"bar">>}]}}, catch decode(EncodedToken, [], KS)).


%% pip install PyJWT
%% > import jwt
%% > jwt.encode({'foo':'bar'}, 'secret', algorithm='HS512')
hs512_test() ->
    EncodedToken = <<"eyJhbGciOiJIUzUxMiIsInR5cCI6IkpXVCJ9.eyJmb28iOiJiYX"
                     "IifQ.WePl7achkd0oGNB8XRF_LJwxlyiPZqpdNgdKpDboAjSTsW"
                     "q-aOGNynTp8TOv8KjonFym8vwFwppXOLoLXbkIaQ">>,
    KS = fun(<<"HS512">>, _) -> <<"secret">> end,
    ?assertMatch({ok, {[{<<"foo">>,<<"bar">>}]}}, catch decode(EncodedToken, [], KS)).


%% jwt.io generated
rs256_test() ->
    EncodedToken = <<"eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0N"
                     "TY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiYWRtaW4iOnRydWV9.Ek"
                     "N-DOsnsuRjRO6BxXemmJDm3HbxrbRzXglbN2S4sOkopdU4IsDxTI8j"
                     "O19W_A4K8ZPJijNLis4EZsHeY559a4DFOd50_OqgHGuERTqYZyuhtF"
                     "39yxJPAjUESwxk2J5k_4zM3O-vtd1Ghyo4IbqKKSy6J9mTniYJPenn"
                     "5-HIirE">>,

    Checks = [sig, alg],
    KS = fun(<<"RS256">>, undefined) -> jwt_io_pubkey() end,

    ExpectedPayload = {[
        {<<"sub">>, <<"1234567890">>},
        {<<"name">>, <<"John Doe">>},
        {<<"admin">>, true}
    ]},

    ?assertMatch({ok, ExpectedPayload}, decode(EncodedToken, Checks, KS)).


encode_missing_alg_test() ->
    ?assertEqual({error, missing_alg},
        encode({[]}, {[]}, <<"foo">>)).


encode_invalid_alg_test() ->
    ?assertEqual({error, invalid_alg},
        encode({[{<<"alg">>, <<"BOGUS">>}]}, {[]}, <<"foo">>)).


encode_decode_test_() ->
    [{Alg, encode_decode(Alg)} || Alg <- ?VALID_ALGS].


encode_decode(Alg) ->
    {EncodeKey, DecodeKey} = case verification_algorithm(Alg) of
        {public_key, Algorithm} ->
            jwtf_test_util:create_keypair();
        {hmac, Algorithm} ->
            Key = <<"a-super-secret-key">>,
            {Key, Key}
    end,
    Claims = claims(),
    {ok, Encoded} = encode(header(Alg), Claims, EncodeKey),
    KS = fun(_, _) -> DecodeKey end,
    {ok, Decoded} = decode(Encoded, [], KS),
    ?_assertMatch(Claims, Decoded).


header(Alg) ->
    {[
        {<<"typ">>, <<"JWT">>},
        {<<"alg">>, Alg},
        {<<"kid">>, <<"20170520-00:00:00">>}
    ]}.


claims() ->
    EpochSeconds = 1496205841,
    {[
        {<<"iat">>, EpochSeconds},
        {<<"exp">>, EpochSeconds + 3600}
    ]}.

-endif.
