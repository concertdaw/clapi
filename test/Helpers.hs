{-# LANGUAGE FlexibleInstances #-}
module Helpers where

import Control.Monad.Fail (MonadFail, fail)
import Data.List (isInfixOf)
import Data.Either.Combinators (fromLeft)
import Test.HUnit (Assertion, assertBool)


instance MonadFail (Either String) where
    fail = Left

assertFailed :: String -> Either a b -> Assertion
assertFailed s either = assertBool (s ++ " did not fail") (didFail either)
  where
    didFail (Left _) = True
    didFail (Right _) = False


assertFailedSubstr :: String -> String -> Either String b -> Assertion
assertFailedSubstr msg substr e =
  do
    assertFailed (msg ++ "did not fail") e
    assertBool (
        msg ++ "failed with \"" ++ "x" ++ "\",\nnot\"" ++ substr ++
        "\"") $ substr `isInfixOf` actualMsg
  where
    actualMsg = fromLeft "" e
