port module Tests exposing (..)

import Test exposing (describe, Test)
import Test.Runner.Node exposing (run)
import Json.Encode exposing (Value)
import NoConstantConditionTest
import NoDebugTest
import NoDuplicateImportsTest
import NoImportingEverythingTest
import NoUnannotatedFunctionTest
import NoUnusedVariablesTest
import NoUselessPatternMatchingTest
import SimplifyPipingTest


main : Test.Runner.Node.TestProgram
main =
    run emit all


port emit : ( String, Value ) -> Cmd msg


all : Test
all =
    describe "Visitors"
        [ NoConstantConditionTest.all
        , NoDebugTest.all
        , NoDuplicateImportsTest.all
        , NoImportingEverythingTest.all
        , NoUnannotatedFunctionTest.all
        , NoUnusedVariablesTest.all
        , NoUselessPatternMatchingTest.all
        , SimplifyPipingTest.all
        ]