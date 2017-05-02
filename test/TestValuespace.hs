{-# LANGUAGE OverloadedStrings #-}
module TestValuespace where

import Test.HUnit (assertEqual, assertBool)
import Test.Framework.Providers.HUnit (testCase)
import Test.Framework.Providers.QuickCheck2 (testProperty)
import Test.QuickCheck (
    Arbitrary(..), Gen, Property, arbitrary, oneof, elements, listOf, listOf1,
    arbitraryBoundedEnum, vector, vectorOf)

import Data.Coerce (coerce)
import Data.Either (either)
import qualified Data.Text as T
import Data.Word (Word16)
import qualified Data.Map.Strict as Map
import Control.Lens (view)
import Control.Monad (replicateM)

import Helpers (assertFailed)

import Path (Path)
import Types (InterpolationType, Interpolation(..), ClapiValue(..))
import Validator (validate)
import Valuespace (
    Definition(..), Liberty(..), tupleDef, structDef, arrayDef, validators,
    metaType, defToValues, valuesToDef, vsValidate, baseValuespace,
    vsAssignType, vsSet, anon, tconst, globalSite)

tests = [
    testCase "tupleDef" testTupleDef,
    testCase "test base valuespace" testBaseValuespace,
    testCase "test child type validation" testChildTypeValidation,
    testProperty "Definition <-> ClapiValue round trip" propDefRoundTrip
    ]

testTupleDef =
  do
    assertFailed "duplicate names" $
        tupleDef Cannot "docs" ["hi", "hi"] ["bool", "int32"] mempty
    assertFailed "mismatched names/types" $
        tupleDef Cannot "docs" ["a", "b"] ["bool"] mempty
    def <- tupleDef Cannot "docs" ["a"] ["bool"] mempty
    assertEqual "tuple validation" (Right ()) $
        validate undefined (view validators def) [CBool True]


testBaseValuespace = assertEqual "correct base valuespace" mempty $
    fst $ vsValidate $ coerce baseValuespace

testChildTypeValidation =
  do
    -- Set /api/self/version to have the wrong type, but perfectly valid
    -- data for that wront type:
    badVs <- vsSet anon IConstant [CString "banana"] ["api", "self", "version"]
          globalSite tconst baseValuespace >>=
        return . vsAssignType ["api", "self", "version"]
          ["api", "types", "self", "build"]
    assertBool "did not find errors" $ not . null . fst $ vsValidate badVs


arbitraryPath :: Gen Path
arbitraryPath = listOf $ listOf1 $ elements ['a'..'z']

instance Arbitrary Liberty where
    arbitrary = arbitraryBoundedEnum

instance Arbitrary InterpolationType where
    arbitrary = arbitraryBoundedEnum

instance Arbitrary T.Text where
    arbitrary = T.pack <$> arbitrary

-- http://stackoverflow.com/questions/9542313/
infiniteStrings :: Int -> [String]
infiniteStrings minLen = [minLen..] >>= (`replicateM` ['a'..'z'])

instance Arbitrary Definition where
    arbitrary =
      do
        n <- arbitrary
        fDef <- oneof [
            tupleDef <$> arbitrary <*> arbitrary <*>
                (pure $ take n $ infiniteStrings 4) <*>
                pure (replicate n "bool") <*> arbitrary,
            structDef <$> arbitrary <*> arbitrary <*> vector n <*>
                vectorOf n arbitraryPath <*> vector n,
            arrayDef <$> arbitrary <*> arbitrary <*> arbitraryPath <*>
                arbitrary]
        either error return fDef


propDefRoundTrip :: Definition -> Bool
propDefRoundTrip d = (valuesToDef (metaType d) . defToValues) d == Just d
