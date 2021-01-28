port module Packages.API exposing (main)

import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode exposing (Value)
import Packages.Dynamo as Dynamo
import Packages.FQPackage as FQPackage exposing (FQPackage)
import Packages.RootSite as RootSite
import Parser exposing (Parser)
import Serverless
import Serverless.Conn as Conn exposing (method, request, respond, route)
import Serverless.Conn.Body as Body
import Serverless.Conn.Request exposing (Method(..), Request, body)
import Task
import Time exposing (Posix)
import Tuple
import Url
import Url.Parser exposing ((</>), (<?>), int, map, oneOf, s, top)
import Url.Parser.Query as Query



-- Serverless program.


port requestPort : Serverless.RequestPort msg


port responsePort : Serverless.ResponsePort msg


type alias Conn =
    Conn.Conn Config () Route Msg


main : Serverless.Program Config () Route Msg
main =
    Serverless.httpApi
        { configDecoder = configDecoder
        , initialModel = ()
        , parseRoute = routeParser
        , endpoint = router
        , update = update
        , interopPorts = [ Dynamo.dynamoResponsePort ]
        , requestPort = requestPort
        , responsePort = responsePort
        }



--, Decode.map DynamoOk Decode.value
-- Configuration


type alias Config =
    { dynamoDbNamespace : String
    }


configDecoder : Decoder Config
configDecoder =
    Decode.field "DYNAMODB_NAMESPACE" Decode.string
        |> Decode.map Config



-- Route and query parsing.


type Route
    = AllPackages
    | AllPackagesSince Int
    | ElmJson String String String
    | EndpointJson String String String
    | Refresh


routeParser : Url.Url -> Maybe Route
routeParser =
    oneOf
        [ map AllPackages (s "all-packages")
        , map AllPackagesSince (s "all-packages" </> s "since" </> Url.Parser.int)
        , map ElmJson (s "packages" </> Url.Parser.string </> Url.Parser.string </> Url.Parser.string </> s "elm.json")
        , map EndpointJson (s "packages" </> Url.Parser.string </> Url.Parser.string </> Url.Parser.string </> s "endpoint.json")
        , map Refresh (s "refresh")
        ]
        |> Url.Parser.parse


router : Conn -> ( Conn, Cmd Msg )
router conn =
    case ( method conn, Debug.log "route" <| route conn ) of
        -- The original package site API
        ( GET, AllPackages ) ->
            ( conn, RootSite.fetchAllPackages PassthroughAllPackages )

        ( POST, AllPackagesSince since ) ->
            ( conn, RootSite.fetchAllPackagesSince since |> Task.attempt PassthroughAllPackagesSince )

        ( GET, ElmJson author name version ) ->
            ( conn, RootSite.fetchElmJson PassthroughElmJson author name version )

        ( GET, EndpointJson author name version ) ->
            ( conn, RootSite.fetchEndpointJson PassthroughEndpointJson author name version )

        -- The enhanced API
        ( GET, AllPackagesSince since ) ->
            ( conn, RootSite.fetchAllPackagesSince since |> Task.attempt PassthroughAllPackagesSince )

        ( GET, Refresh ) ->
            -- Query the table to see what we know about.
            -- If its empty, refresh since 0.
            -- If its got stuff, refresh since what we know about.
            ( conn
            , RootSite.fetchAllPackagesSince 11350
                |> Task.map2 Tuple.pair Time.now
                |> Task.attempt (RefreshPackages 11350)
            )

        ( _, _ ) ->
            respond ( 405, Body.text "Method not allowed" ) conn



-- Side effects.


type Msg
    = PassthroughAllPackages (Result Http.Error Decode.Value)
    | PassthroughAllPackagesSince (Result Http.Error (List FQPackage))
    | PassthroughElmJson (Result Http.Error Decode.Value)
    | PassthroughEndpointJson (Result Http.Error Decode.Value)
    | RefreshPackages Int (Result Http.Error ( Posix, List FQPackage ))
    | SeqNoSaved


update : Msg -> Conn -> ( Conn, Cmd Msg )
update msg conn =
    case Debug.log "update" msg of
        PassthroughAllPackages result ->
            case result of
                Ok val ->
                    respond ( 200, Body.json val ) conn

                Err err ->
                    respond ( 500, Body.text "Got error when trying to contact package.elm-lang.com." ) conn

        PassthroughAllPackagesSince result ->
            case result of
                Ok val ->
                    respond ( 200, Body.json (Encode.list FQPackage.encode val) ) conn

                Err _ ->
                    respond ( 500, Body.text "Got error when trying to contact package.elm-lang.com." ) conn

        PassthroughElmJson result ->
            case result of
                Ok val ->
                    respond ( 200, Body.json val ) conn

                Err _ ->
                    respond ( 500, Body.text "Got error when trying to contact package.elm-lang.com." ) conn

        PassthroughEndpointJson result ->
            case result of
                Ok val ->
                    respond ( 200, Body.json val ) conn

                Err _ ->
                    respond ( 500, Body.text "Got error when trying to contact package.elm-lang.com." ) conn

        RefreshPackages from result ->
            case result of
                Ok ( timestamp, packageList ) ->
                    -- Save the package list to the table.
                    -- Trigger the processing jobs to populate them all.
                    let
                        seqNo =
                            List.length packageList + from
                    in
                    ( conn, Cmd.none )
                        |> andThen saveAllPackages
                        |> andThen (saveSeqNo timestamp seqNo (always SeqNoSaved))

                Err err ->
                    respond ( 500, Body.text "Got error when trying to contact package.elm-lang.com." ) conn

        SeqNoSaved ->
            let
                _ =
                    Debug.log "update" "Sequence number saved ok."
            in
            ( conn, Cmd.none )
                |> andThen createdOk


andThen : (model -> ( model, Cmd msg )) -> ( model, Cmd msg ) -> ( model, Cmd msg )
andThen fn ( model, cmd ) =
    let
        ( nextModel, nextCmd ) =
            fn model
    in
    ( nextModel, Cmd.batch [ cmd, nextCmd ] )


saveAllPackages : Conn -> ( Conn, Cmd Msg )
saveAllPackages conn =
    ( conn, Cmd.none )


saveSeqNo : Posix -> Int -> (Value -> Msg) -> Conn -> ( Conn, Cmd Msg )
saveSeqNo timestamp seqNo responseDecoder conn =
    Dynamo.put
        elmSeqDynamoDBTableEncoder
        (fqTableName "eco-elm-seq" conn)
        { label = "latest"
        , seq = seqNo
        , updatedAt = timestamp
        }
        responseDecoder
        conn


createdOk : Conn -> ( Conn, Cmd Msg )
createdOk conn =
    respond ( 201, Body.empty ) conn



-- DynamoDB Tables


fqTableName : String -> Conn -> String
fqTableName name conn =
    (Conn.config conn).dynamoDbNamespace ++ "-" ++ name


type alias ElmSeqDynamoDBTable =
    { label : String
    , seq : Int
    , updatedAt : Posix
    }


elmSeqDynamoDBTableEncoder : ElmSeqDynamoDBTable -> Value
elmSeqDynamoDBTableEncoder record =
    Encode.object
        [ ( "label", Encode.string record.label )
        , ( "seq", Encode.int record.seq )
        , ( "updatedAt", Encode.int (Time.posixToMillis record.updatedAt) )
        ]
