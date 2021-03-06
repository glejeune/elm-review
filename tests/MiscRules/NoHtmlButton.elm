module MiscRules.NoHtmlButton exposing (rule)

import Elm.Syntax.Expression exposing (Expression(..))
import Elm.Syntax.Node as Node exposing (Node)
import Review.Rule as Rule exposing (Direction, Error, Rule)
import Scope


rule : Rule
rule =
    Rule.newModuleRuleSchema "NoHtmlButton" initialContext
        -- Scope.addModuleVisitors should be added before your own visitors
        |> Scope.addModuleVisitors
        |> Rule.withExpressionVisitor expressionVisitor
        |> Rule.fromModuleRuleSchema
        |> Rule.ignoreErrorsForFiles [ "src/Button.elm" ]


type alias Context =
    -- Scope expects a context with a record, containing the `scope` field.
    { scope : Scope.ModuleContext
    }


initialContext : Context
initialContext =
    { scope = Scope.initialModuleContext
    }


expressionVisitor : Node Expression -> Direction -> Context -> ( List (Error {}), Context )
expressionVisitor node direction context =
    case ( direction, Node.value node ) of
        ( Rule.OnEnter, FunctionOrValue moduleName "button" ) ->
            if Scope.realModuleName context.scope "button" moduleName == [ "Html" ] then
                ( [ Rule.error
                        { message = "Do not use `Html.button` directly"
                        , details = [ "At fruits.com, we've built a nice `Button` module that suits our needs better. Using this module instead of `Html.button` ensures we have a consistent button experience across the website." ]
                        }
                        (Node.range node)
                  ]
                , context
                )

            else
                ( [], context )

        _ ->
            ( [], context )
