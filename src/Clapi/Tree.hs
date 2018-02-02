{-# OPTIONS_GHC -Wall -Wno-orphans #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE TupleSections #-}

module Clapi.Tree where

import Prelude hiding (fail)
import Control.Monad.Fail (MonadFail(..))
import Control.Monad.State (State, get, put, modify, runState)
import Data.Functor.Const (Const(..))
import Data.Functor.Identity (Identity(..))
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Monoid
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word

import Clapi.Types
  (Time, Interpolation(..), Attributee, WireValue)
import Clapi.Types.AssocList
  ( AssocList, unAssocList, alEmpty, alFmapWithKey, alSingleton, alAlterF
  , alKeys, alToMap, alPickFromMap)
import Clapi.Types.Dkmap (Dkmap)
import qualified Clapi.Types.Dkmap as Dkmap
import Clapi.Types.Path (
    Seg, Path, pattern Root, pattern (:/), pattern (:</),
    NodePath)
import Clapi.Types.Digests
  ( DataDigest, Reorderings, DataChange(..), TimeSeriesDataOp(..))
import Clapi.Types.SequenceOps (reorderFromDeps)
import Clapi.Types.UniqList (UniqList)

type TpId = Word32

type TimePoint a = (Interpolation, a)
type Attributed a = (Maybe Attributee, a)
type TimeSeries a = Dkmap TpId Time (Attributed (TimePoint a))

data RoseTree a
  = RtEmpty
  | RtContainer (AssocList Seg (Maybe Attributee, RoseTree a))
  | RtConstData (Maybe Attributee) a
  | RtDataSeries (TimeSeries a)
  deriving (Show, Eq, Functor, Foldable)

treeMissing :: RoseTree a -> [Path]
treeMissing = inner Root
  where
    inner p RtEmpty = [p]
    inner p (RtContainer al) =
      mconcat $ (\(s, (_, rt)) -> inner (p :/ s) rt) <$> unAssocList al
    inner _ _ = []

treePaths :: Path -> RoseTree a -> [Path]
treePaths p t = case t of
  RtEmpty -> [p]
  RtConstData _ _ -> [p]
  RtDataSeries _ -> [p]
  RtContainer al ->
    p : (mconcat $ (\(s, (_, t')) -> treePaths (p :/ s) t') <$> unAssocList al)

treeApplyReorderings
  :: MonadFail m => Map Seg (Maybe Attributee, Maybe Seg) -> RoseTree a
  -> m (RoseTree a)
treeApplyReorderings rom (RtContainer children) =
  let
    attMap = fst <$> rom
    reattribute s (oldMa, rt) = (Map.findWithDefault oldMa s attMap, rt)
  in
    RtContainer . alFmapWithKey reattribute . alPickFromMap (alToMap children)
    <$> (reorderFromDeps (snd <$> rom) $ alKeys children)
treeApplyReorderings _ _ = fail "Not a container"

treeConstSet :: Maybe Attributee -> a -> RoseTree a -> RoseTree a
treeConstSet att a _ = RtConstData att a

treeSet
  :: MonadFail m => TpId -> Time -> a -> Interpolation -> Maybe Attributee
  -> RoseTree a -> m (RoseTree a)
treeSet tpId t a i att rt =
  let
    ts' = case rt of
      RtDataSeries ts -> ts
      _ -> Dkmap.empty
  in
    RtDataSeries <$> Dkmap.set tpId t (att, (i, a)) ts'


treeRemove :: MonadFail m => TpId -> RoseTree a -> m (RoseTree a)
treeRemove tpId rt = case rt of
  RtDataSeries ts -> RtDataSeries <$> Dkmap.deleteK0' tpId ts
  _ -> fail "Not a time series"


treeLookup :: Path -> RoseTree a -> Maybe (RoseTree a)
treeLookup p = getConst . treeAlterF Nothing Const p

treeInsert :: Maybe Attributee -> Path -> RoseTree a -> RoseTree a -> RoseTree a
treeInsert att p t = treeAlter att (const $ Just t) p

treeDelete :: Path -> RoseTree a -> RoseTree a
treeDelete p = treeAlter Nothing (const Nothing) p

treeAdjust
  :: Maybe Attributee -> (RoseTree a -> RoseTree a) -> Path -> RoseTree a
  -> RoseTree a
treeAdjust att f p = runIdentity . treeAdjustF att (Identity . f) p

treeAdjustF
  :: Functor f => Maybe Attributee -> (RoseTree a -> f (RoseTree a)) -> Path
  -> RoseTree a -> f (RoseTree a)
treeAdjustF att f = treeAlterF att (fmap Just . f . maybe RtEmpty id)

treeAlter
  :: Maybe Attributee -> (Maybe (RoseTree a) -> Maybe (RoseTree a)) -> Path
  -> RoseTree a -> RoseTree a
treeAlter att f path = runIdentity . treeAlterF att (Identity . f) path

treeAlterF
  :: forall f a. Functor f
  => Maybe Attributee -> (Maybe (RoseTree a) -> f (Maybe (RoseTree a))) -> Path
  -> RoseTree a -> f (RoseTree a)
treeAlterF att f path tree = maybe RtEmpty snd <$> inner path (Just (att, tree))
  where
    inner
      :: Path -> Maybe (Maybe Attributee, RoseTree a)
      -> f (Maybe (Maybe Attributee, RoseTree a))
    inner Root mat = fmap (att,) <$> f (snd <$> mat)
    inner (s :</ p) (Just (att', t)) = case t of
      RtContainer al -> Just . (att',) . RtContainer <$> alAlterF (inner p) s al
      _ -> buildChildTree s p
    inner (s :</ p) Nothing = buildChildTree s p
    buildChildTree s p =
      fmap ((att,) . RtContainer . alSingleton s) <$> inner p Nothing


updateTreeWithDigest
  :: Reorderings -> DataDigest -> RoseTree [WireValue]
  -> (Map Path [Text], RoseTree [WireValue])
updateTreeWithDigest reords dd = runState $ do
    errs <- sequence $ Map.mapWithKey applyReord reords
    errs' <- alToMap <$> (sequence $ alFmapWithKey applyDd dd)
    return $ Map.filter (not . null) $ Map.unionWith (<>) errs errs'
  where
    applyReord
      :: NodePath -> Map Seg (Maybe Attributee, Maybe Seg)
      -> State (RoseTree [WireValue]) [Text]
    applyReord np m = do
      eRt <- treeAdjustF Nothing (treeApplyReorderings m) np <$> get
      either (return . pure . Text.pack) (\rt -> put rt >> return []) eRt
    applyDd
      :: NodePath -> DataChange
      -> State (RoseTree [WireValue]) [Text]
    applyDd np dc = case dc of
      InitChange att -> do
        modify $ (treeInsert att np $ RtContainer alEmpty)
        return []
      DeleteChange _ -> do
        modify $ treeDelete np
        return []
      ConstChange att wv -> do
        modify $ treeAdjust Nothing (treeConstSet att wv) np
        return []
      TimeChange m -> mconcat <$> (mapM (applyTc np) $ Map.toList m)
    applyTc
      :: NodePath
      -> (TpId, (Maybe Attributee, TimeSeriesDataOp))
      -> State (RoseTree [WireValue]) [Text]
    applyTc np (tpId, (att, op)) = case op of
      OpSet t wv i -> get >>=
        either (return . pure . Text.pack) (\vs -> put vs >> return [])
        . treeAdjustF Nothing (treeSet tpId t wv i att) np
      OpRemove -> get >>=
        either (return . pure . Text.pack) (\vs -> put vs >> return [])
        . treeAdjustF Nothing (treeRemove tpId) np

data RoseTreeNode a
  = RtnEmpty
  | RtnChildren (Maybe Attributee) (UniqList Seg)
  | RtnConstData (Maybe Attributee) a
  | RtnDataSeries (TimeSeries a)
  deriving (Show, Eq)

roseTreeNode :: RoseTree a -> RoseTreeNode a
roseTreeNode t = case t of
  RtEmpty -> RtnEmpty
  RtContainer al -> RtnChildren Nothing $ alKeys al
  RtConstData att a -> RtnConstData att a
  RtDataSeries m -> RtnDataSeries m

treeLookupNode :: Path -> RoseTree a -> Maybe (RoseTreeNode a)
treeLookupNode p = fmap roseTreeNode . treeLookup p
