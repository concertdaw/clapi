module Clapi.Types.SequenceOps
  ( reorderUniqList
  ) where

import Prelude hiding (fail)
import Control.Monad.Fail (MonadFail(..))
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.List as List
import Data.Foldable (foldlM)

import Clapi.Types.UniqList (UniqList, unUniqList, mkUniqList)

getChainStarts ::
    Ord i => Map i (Maybe i) -> ([(i, Maybe i)], Map i (Maybe i))
getChainStarts m =
    let
        hasUnresolvedDep = maybe False (flip Map.member m)
        (remainder, starts) = Map.partition hasUnresolvedDep m
    in (Map.toList starts, remainder)

reorderUniqList
    :: (MonadFail m, Ord i, Show i)
    => Map i (Maybe i) -> UniqList i -> m (UniqList i)
reorderUniqList m ul =
    resolveDigest m >>= applyMoves (unUniqList ul) >>= mkUniqList
  where
    resolveDigest m' = if null m' then return []
        else case getChainStarts m' of
            ([], _) -> fail "Unresolvable order dependencies"
            (starts, remainder) -> (starts ++) <$> resolveDigest remainder
    applyMoves l starts = foldlM applyMove l starts

applyMove :: (MonadFail m, Ord i, Show i) => [i] -> (i, Maybe i) -> m [i]
applyMove l (i, mi) =
    removeElem "Element was not present to move" i l
    >>= insertAfter "Preceeding element not found for move" i mi
  where
    insertAfter msg v mAfter ol = case mAfter of
        Nothing -> return $ v : ol
        Just after ->
          let
            (bl, al) = span (/= after) ol
          in case al of
            (a:rl) -> return $ bl ++ [a, v] ++ rl
            [] -> fail $ msg ++ ": " ++ show after
    removeElem msg v ol =
      let
        (ds, ol') = List.partition (== v) ol
      in case ds of
        [_] -> return ol'
        _ -> fail $ msg ++ ": " ++ show v
