module NoImportingEverything exposing (rule)

import Lint exposing (lint, doNothing)
import Types exposing (LintRule, Error, Direction(..))
import Ast.Statement exposing (..)


type alias Context =
    {}


rule : String -> List Error
rule input =
    lint input implementation


implementation : LintRule Context
implementation =
    { statementFn = statementFn
    , typeFn = doNothing
    , expressionFn = doNothing
    , moduleEndFn = (\ctx -> ( [], ctx ))
    , initialContext = Context
    }


error : String -> Error
error name =
    Error "NoImportingEverything" ("Do not expose everything from " ++ name)


statementFn : Context -> Direction Statement -> ( List Error, Context )
statementFn ctx node =
    case node of
        Enter (ImportStatement names alias (Just AllExport)) ->
            ( [ error <| String.join "." names ], ctx )

        _ ->
            ( [], ctx )
