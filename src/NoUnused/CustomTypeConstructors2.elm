module NoUnused.CustomTypeConstructors2 exposing (rule)

{-| Forbid having unused custom type constructors in a file.


# Rule

@docs rule

-}

import Dict exposing (Dict)
import Elm.Module
import Elm.Project
import Elm.Syntax.Declaration as Declaration exposing (Declaration)
import Elm.Syntax.Exposing as Exposing
import Elm.Syntax.Expression as Expression exposing (Expression)
import Elm.Syntax.Module as Module exposing (Module)
import Elm.Syntax.ModuleName exposing (ModuleName)
import Elm.Syntax.Node as Node exposing (Node)
import Elm.Syntax.Signature exposing (Signature)
import Elm.Syntax.TypeAnnotation as TypeAnnotation exposing (TypeAnnotation)
import Review.Rule as Rule exposing (Direction, Error, Rule)
import Scope2 as Scope
import Set exposing (Set)


{-| Forbid having unused custom type constructors in a file.

    config =
        [ NoUnused.CustomTypeConstructors.rule
        ]

Note that this does not report a constructor if it is exposed in the module, even
if it is not used anywhere in the project. For a more accurate detection of
unused constructors (and functions) across your project, you might want to check
out [elm-xref](https://github.com/zwilias/elm-xref). You may still want to use
this rule in your config so that you get notified of unused constructors earlier
in your editor, rather than when running your tests or [elm-xref](https://github.com/zwilias/elm-xref).


## Fail

    module A exposing (a)

    type MyType
        = UsedType
        | UnusedType -- Will get reported

    a =
        UsedType


## Success

    module A exposing (ExposedType(..))

    type MyType
        = UsedType

    a =
        UsedType

    type ExposedType
        = A
        | B
        | C

    -----------------------
    module A exposing (..)

    type ExposedType
        = A
        | B
        | C

-}
rule : Rule
rule =
    Rule.newProjectRuleSchema "NoUnused.CustomTypeConstructors"
        { moduleVisitor = moduleVisitor
        , initProjectContext = initProjectContext
        , fromProjectToModule = fromProjectToModule
        , fromModuleToProject = fromModuleToProject
        , foldProjectContexts = foldProjectContexts
        }
        |> Scope.addProjectVisitors
        |> Rule.withElmJsonProjectVisitor elmJsonVisitor
        |> Rule.withFinalProjectEvaluation finalProjectEvaluation
        |> Rule.fromProjectRuleSchema



-- MODULE VISITOR


moduleVisitor : Rule.ModuleRuleSchema {} ModuleContext -> Rule.ModuleRuleSchema { hasAtLeastOneVisitor : () } ModuleContext
moduleVisitor schema =
    schema
        |> Scope.addModuleVisitors
        |> Rule.withModuleDefinitionVisitor moduleDefinitionVisitor
        |> Rule.withDeclarationListVisitor declarationListVisitor
        |> Rule.withDeclarationVisitor declarationVisitor
        |> Rule.withExpressionVisitor expressionVisitor



-- CONTEXT


type alias ModuleNameAsString =
    String


type alias CustomTypeName =
    String


type alias ConstructorName =
    String


type ExposedConstructors
    = ExposedConstructors
        { moduleKey : Rule.ModuleKey
        , customTypes : Dict CustomTypeName (Dict ConstructorName (Node ConstructorName))
        }


type alias ProjectContext =
    { scope : Scope.ProjectContext
    , exposedModules : Set ModuleNameAsString
    , exposedConstructors : Dict ModuleNameAsString ExposedConstructors
    , usedConstructors : Dict ModuleNameAsString (Set ConstructorName)
    }


type alias ModuleContext =
    { scope : Scope.ModuleContext
    , exposedCustomTypesWithConstructors : Set CustomTypeName
    , isExposed : Bool
    , exposesEverything : Bool
    , declaredTypesWithConstructors : Dict CustomTypeName (Dict ConstructorName (Node ConstructorName))
    , usedFunctionsOrValues : Dict ModuleNameAsString (Set ConstructorName)
    , phantomVariables : List ( CustomTypeName, Int )
    }


initProjectContext : ProjectContext
initProjectContext =
    { scope = Scope.initProjectContext
    , exposedModules = Set.empty
    , exposedConstructors = Dict.empty
    , usedConstructors = Dict.empty
    }


fromProjectToModule : Rule.ModuleKey -> Node ModuleName -> ProjectContext -> ModuleContext
fromProjectToModule _ (Node.Node _ moduleName) projectContext =
    { scope = Scope.fromProjectToModule projectContext.scope
    , exposedCustomTypesWithConstructors = Set.empty
    , isExposed = Set.member (String.join "." moduleName) projectContext.exposedModules
    , exposesEverything = False
    , declaredTypesWithConstructors = Dict.empty
    , usedFunctionsOrValues = Dict.empty
    , phantomVariables = []
    }


fromModuleToProject : Rule.ModuleKey -> Node ModuleName -> ModuleContext -> ProjectContext
fromModuleToProject moduleKey moduleName moduleContext =
    let
        localUsed : Set ConstructorName
        localUsed =
            moduleContext.usedFunctionsOrValues
                |> Dict.get ""
                |> Maybe.withDefault Set.empty

        moduleNameAsString : ModuleNameAsString
        moduleNameAsString =
            String.join "." <| Node.value moduleName
    in
    { scope = Scope.fromModuleToProject moduleName moduleContext.scope
    , exposedModules = Set.empty
    , exposedConstructors =
        if moduleContext.isExposed then
            Dict.empty

        else
            Dict.singleton
                moduleNameAsString
                (ExposedConstructors
                    { moduleKey = moduleKey
                    , customTypes = moduleContext.declaredTypesWithConstructors
                    }
                )
    , usedConstructors =
        moduleContext.usedFunctionsOrValues
            |> Dict.remove ""
            |> Dict.insert moduleNameAsString localUsed
    }


foldProjectContexts : ProjectContext -> ProjectContext -> ProjectContext
foldProjectContexts newContext previousContext =
    { scope = Scope.foldProjectContexts previousContext.scope newContext.scope
    , exposedModules = previousContext.exposedModules

    -- TODO
    , exposedConstructors = Dict.union newContext.exposedConstructors previousContext.exposedConstructors
    , usedConstructors =
        Dict.merge
            Dict.insert
            (\key newUsed previousUsed dict -> Dict.insert key (Set.union newUsed previousUsed) dict)
            Dict.insert
            newContext.usedConstructors
            previousContext.usedConstructors
            Dict.empty
    }



-- ELM.JSON VISITOR


elmJsonVisitor : Maybe { elmJsonKey : Rule.ElmJsonKey, project : Elm.Project.Project } -> ProjectContext -> ProjectContext
elmJsonVisitor maybeElmJson projectContext =
    case maybeElmJson |> Maybe.map .project of
        Just (Elm.Project.Package package) ->
            let
                exposedModules : List Elm.Module.Name
                exposedModules =
                    case package.exposed of
                        Elm.Project.ExposedList list ->
                            list

                        Elm.Project.ExposedDict list ->
                            List.concatMap Tuple.second list

                exposedNames : Set String
                exposedNames =
                    exposedModules
                        |> List.map Elm.Module.toString
                        |> Set.fromList
            in
            { projectContext | exposedModules = exposedNames }

        Just (Elm.Project.Application _) ->
            projectContext

        Nothing ->
            projectContext



-- MODULE DEFINITION VISITOR


moduleDefinitionVisitor : Node Module -> ModuleContext -> ( List nothing, ModuleContext )
moduleDefinitionVisitor moduleNode context =
    case Module.exposingList (Node.value moduleNode) of
        Exposing.All _ ->
            ( [], { context | exposesEverything = True } )

        Exposing.Explicit list ->
            let
                names : List String
                names =
                    List.filterMap
                        (\node ->
                            case Node.value node of
                                Exposing.TypeExpose { name, open } ->
                                    Just name

                                _ ->
                                    Nothing
                        )
                        list
            in
            ( []
            , { context
                | exposedCustomTypesWithConstructors =
                    Set.union (Set.fromList names) context.exposedCustomTypesWithConstructors
              }
            )



-- DECLARATION LIST VISITOR


declarationListVisitor : List (Node Declaration) -> ModuleContext -> ( List nothing, ModuleContext )
declarationListVisitor nodes context =
    ( [], List.foldl register context nodes )


register : Node Declaration -> ModuleContext -> ModuleContext
register node context =
    case Node.value node of
        Declaration.CustomTypeDeclaration { name, generics, constructors } ->
            let
                nonPhantomVariables : Set String
                nonPhantomVariables =
                    constructors
                        |> List.concatMap (Node.value >> .arguments)
                        |> List.concatMap collectGenericsFromTypeAnnotation
                        |> Set.fromList

                phantomVariables : List ( String, Int )
                phantomVariables =
                    generics
                        |> List.map Node.value
                        |> List.indexedMap Tuple.pair
                        |> List.filter (\( _, genericName ) -> not <| Set.member genericName nonPhantomVariables)
                        |> List.map (\( indexOfPhantomVariable, _ ) -> ( Node.value name, indexOfPhantomVariable ))
            in
            { context | phantomVariables = phantomVariables ++ context.phantomVariables }

        _ ->
            context



-- DECLARATION VISITOR


declarationVisitor : Node Declaration -> Direction -> ModuleContext -> ( List nothing, ModuleContext )
declarationVisitor node direction context =
    case ( direction, Node.value node ) of
        ( Rule.OnEnter, Declaration.CustomTypeDeclaration { name, constructors } ) ->
            -- if Set.member (Node.value name) context.exposedCustomTypesWithConstructors then
            --     ( [], context )
            --
            -- else
            let
                constructorsForCustomType : Dict String (Node String)
                constructorsForCustomType =
                    List.foldl
                        (\constructor dict ->
                            let
                                nameNode : Node String
                                nameNode =
                                    (Node.value constructor).name
                            in
                            Dict.insert
                                (Node.value nameNode)
                                nameNode
                                dict
                        )
                        Dict.empty
                        constructors
            in
            ( []
            , { context
                | declaredTypesWithConstructors =
                    Dict.insert
                        (Node.value name)
                        constructorsForCustomType
                        context.declaredTypesWithConstructors
              }
            )

        ( Rule.OnEnter, Declaration.FunctionDeclaration function ) ->
            ( [], markPhantomTypesFromTypeSignatureAsUsed function.signature context )

        _ ->
            ( [], context )



-- EXPRESSION VISITOR


expressionVisitor : Node Expression -> Direction -> ModuleContext -> ( List nothing, ModuleContext )
expressionVisitor node direction moduleContext =
    case ( direction, Node.value node ) of
        ( Rule.OnEnter, Expression.FunctionOrValue moduleName name ) ->
            ( [], registerUsedFunctionOrValue moduleName name moduleContext )

        ( Rule.OnEnter, Expression.LetExpression { declarations } ) ->
            ( []
            , declarations
                |> List.filterMap
                    (\declaration ->
                        case Node.value declaration of
                            Expression.LetFunction function ->
                                Just function.signature

                            Expression.LetDestructuring _ _ ->
                                Nothing
                    )
                |> List.foldl markPhantomTypesFromTypeSignatureAsUsed moduleContext
            )

        _ ->
            ( [], moduleContext )


registerUsedFunctionOrValue : List String -> ConstructorName -> ModuleContext -> ModuleContext
registerUsedFunctionOrValue moduleName name moduleContext =
    if not (isCapitalized name) then
        moduleContext

    else
        let
            realModuleName : ModuleName
            realModuleName =
                Scope.realFunctionOrType moduleName name moduleContext.scope
                    |> Tuple.first

            usedFunctionsOrValues : Dict ModuleNameAsString (Set ConstructorName)
            usedFunctionsOrValues =
                Dict.update
                    -- TODO Use Scope.reaflFunctionOrName
                    (String.join "." realModuleName)
                    (\maybeSet ->
                        case maybeSet of
                            Just set ->
                                Just (Set.insert name set)

                            Nothing ->
                                Just (Set.singleton name)
                    )
                    moduleContext.usedFunctionsOrValues
        in
        { moduleContext | usedFunctionsOrValues = usedFunctionsOrValues }


isCapitalized : String -> Bool
isCapitalized name =
    case String.uncons name of
        Just ( char, _ ) ->
            Char.isUpper char

        Nothing ->
            False



-- FINAL PROJECT EVALUATION


finalProjectEvaluation : ProjectContext -> List Error
finalProjectEvaluation projectContext =
    projectContext.exposedConstructors
        |> Dict.toList
        |> List.concatMap
            (\( moduleName, ExposedConstructors { moduleKey, customTypes } ) ->
                let
                    usedConstructors : Set ConstructorName
                    usedConstructors =
                        Dict.get moduleName projectContext.usedConstructors
                            |> Maybe.withDefault Set.empty
                in
                customTypes
                    |> Dict.toList
                    |> List.concatMap
                        (\( customTypeName, constructors ) ->
                            constructors
                                |> Dict.filter (\constructorName _ -> not <| Set.member constructorName usedConstructors)
                                |> Dict.values
                                |> List.map (errorForModule moduleKey)
                        )
            )



-- ERROR


errorInformation : Node String -> { message : String, details : List String }
errorInformation node =
    { message = "Type constructor `" ++ Node.value node ++ "` is not used."
    , details =
        [ "This type constructor is never used. It might be handled everywhere it might appear, but there is no location where this value actually gets created."
        , "You should either use this value somewhere, or remove it at the location I pointed at."
        , "If you remove it, you may find that other pieces of code are never used, and can themselves be removed too. This could end up simplifying your code a lot."
        ]
    }


errorForModule : Rule.ModuleKey -> Node String -> Error
errorForModule moduleKey node =
    Rule.errorForFile
        moduleKey
        (errorInformation node)
        (Node.range node)



-- TYPE ANNOTATION UTILITY FUNCTIONS


markPhantomTypesFromTypeSignatureAsUsed : Maybe (Node Signature) -> ModuleContext -> ModuleContext
markPhantomTypesFromTypeSignatureAsUsed maybeSignature moduleContext =
    let
        used : List ( ModuleName, CustomTypeName )
        used =
            case maybeSignature of
                Just signature ->
                    signature
                        |> Node.value
                        |> .typeAnnotation
                        |> collectTypesUsedAsPhantomVariables moduleContext.phantomVariables

                Nothing ->
                    []

        usedFunctionsOrValues : Dict ModuleNameAsString (Set ConstructorName)
        usedFunctionsOrValues =
            List.foldl
                insertIntoUsedFunctionsOrValues
                moduleContext.usedFunctionsOrValues
                used
    in
    { moduleContext | usedFunctionsOrValues = usedFunctionsOrValues }


insertIntoUsedFunctionsOrValues : ( ModuleName, ConstructorName ) -> Dict ModuleNameAsString (Set ConstructorName) -> Dict ModuleNameAsString (Set ConstructorName)
insertIntoUsedFunctionsOrValues ( moduleName, constructorName ) dict =
    Dict.update
        -- TODO Use Scope.reaflFunctionOrName
        (String.join "." moduleName)
        (\maybeSet ->
            case maybeSet of
                Just set ->
                    Just (Set.insert constructorName set)

                Nothing ->
                    Just (Set.singleton constructorName)
        )
        dict


collectGenericsFromTypeAnnotation : Node TypeAnnotation -> List String
collectGenericsFromTypeAnnotation node =
    case Node.value node of
        TypeAnnotation.FunctionTypeAnnotation a b ->
            collectGenericsFromTypeAnnotation a ++ collectGenericsFromTypeAnnotation b

        TypeAnnotation.Typed _ params ->
            List.concatMap collectGenericsFromTypeAnnotation params

        TypeAnnotation.Record list ->
            list
                |> List.concatMap (Node.value >> Tuple.second >> collectGenericsFromTypeAnnotation)

        TypeAnnotation.GenericRecord _ list ->
            Node.value list
                |> List.concatMap (Node.value >> Tuple.second >> collectGenericsFromTypeAnnotation)

        TypeAnnotation.Tupled list ->
            List.concatMap collectGenericsFromTypeAnnotation list

        TypeAnnotation.GenericType var ->
            [ var ]

        TypeAnnotation.Unit ->
            []


collectTypesUsedAsPhantomVariables : List ( CustomTypeName, Int ) -> Node TypeAnnotation -> List ( ModuleName, CustomTypeName )
collectTypesUsedAsPhantomVariables phantomVariables node =
    case Node.value node of
        TypeAnnotation.FunctionTypeAnnotation a b ->
            collectTypesUsedAsPhantomVariables phantomVariables a
                ++ collectTypesUsedAsPhantomVariables phantomVariables b

        TypeAnnotation.Typed (Node.Node _ ( [], name )) params ->
            let
                typesUsedInThePhantomVariablePosition : List ( ModuleName, CustomTypeName )
                typesUsedInThePhantomVariablePosition =
                    phantomVariables
                        |> List.filter (\( type_, _ ) -> type_ == name)
                        |> List.filterMap
                            (\( _, index ) ->
                                case listAtIndex index params |> Maybe.map Node.value of
                                    Just (TypeAnnotation.Typed (Node.Node _ ( [], typeName )) []) ->
                                        Just ( [], typeName )

                                    _ ->
                                        Nothing
                            )
            in
            List.concat
                [ typesUsedInThePhantomVariablePosition
                , List.concatMap (collectTypesUsedAsPhantomVariables phantomVariables) params
                ]

        TypeAnnotation.Typed _ params ->
            List.concatMap (collectTypesUsedAsPhantomVariables phantomVariables) params

        TypeAnnotation.Record list ->
            list
                |> List.concatMap (Node.value >> Tuple.second >> collectTypesUsedAsPhantomVariables phantomVariables)

        TypeAnnotation.GenericRecord _ list ->
            Node.value list
                |> List.concatMap (Node.value >> Tuple.second >> collectTypesUsedAsPhantomVariables phantomVariables)

        TypeAnnotation.Tupled list ->
            List.concatMap (collectTypesUsedAsPhantomVariables phantomVariables) list

        TypeAnnotation.GenericType _ ->
            []

        TypeAnnotation.Unit ->
            []


listAtIndex : Int -> List a -> Maybe a
listAtIndex index list =
    case ( index, list ) of
        ( 0, a :: [] ) ->
            Just a

        ( _, [] ) ->
            Nothing

        ( n, _ :: rest ) ->
            listAtIndex (n - 1) rest