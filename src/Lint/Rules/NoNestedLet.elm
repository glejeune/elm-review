module Lint.Rules.NoNestedLet exposing (rule)

{-|
@docs rule

# Fail

    a = let b = 1
        in  let c = 2
            in b + c

# Success

    a = let
          b = 1
          c = 2
        in
          b + c
-}

import Ast.Expression exposing (..)
import Lint exposing (lint, doNothing)
import Lint.Types exposing (LintRule, Error, Direction(..))


type alias Context =
    {}


{-| Forbid nesting let expressions directly.

    rules =
        [ NoNestedLet.rule
        ]
-}
rule : String -> List Error
rule input =
    lint input implementation


implementation : LintRule Context
implementation =
    { statementFn = doNothing
    , typeFn = doNothing
    , expressionFn = expressionFn
    , moduleEndFn = (\ctx -> ( [], ctx ))
    , initialContext = Context
    }


error : Error
error =
    Error "NoNestedLet" "Do not nest Let expressions directly"


expressionFn : Context -> Direction Expression -> ( List Error, Context )
expressionFn ctx node =
    case node of
        Enter (Let declarations (Let _ _)) ->
            ( [ error ], ctx )

        _ ->
            ( [], ctx )