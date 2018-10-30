{-# LANGUAGE
    LambdaCase
  , FlexibleInstances
  , GADTs
  , MultiParamTypeClasses
  , Rank2Types
#-}

module Clapi.Validator where

import Prelude hiding (fail)
import Control.Monad.Fail (MonadFail(..))
import Control.Monad (void)
import Data.Bifunctor (first)
import Data.Word (Word32)
import Data.Monoid ((<>))
import Data.Proxy
import Data.Tagged (Tagged(..))
import Data.Text (Text)
import qualified Data.Text as Text
import Text.Regex.PCRE ((=~~))
import Text.Printf (printf, PrintfArg)

import Clapi.Util (ensureUnique, safeToEnum)
import Clapi.Types
  ( WireValue, Time, Wireable, cast', castWireValue, Definition
  , NewWireValue(..), SomeNewWireValue(..),  unwrapNwv
  , EnumWord32(..), SomeTreeType(..)
  )
import Clapi.Types.Path (Seg, Path)
import qualified Clapi.Types.Path as Path
import Clapi.Types.Tree
  ( Bounds, boundsMin, boundsMax, TreeType(..), NewTreeType(..))
import Clapi.Types.TreeTypeProxy (withTtProxy)

inBounds :: (Ord a, MonadFail m, PrintfArg a) => Bounds a -> a -> m a
inBounds b n = go (boundsMin b) (boundsMax b)
  where
    success = return n
    gte lo | n >= lo = success
           | otherwise = fail $ printf "%v is not >= %v" n lo
    lte hi | n <= hi = success
           | otherwise = fail $ printf "%v is not <= %v" n hi
    go Nothing Nothing = success
    go (Just lo) Nothing = gte lo
    go Nothing (Just hi) = lte hi
    go (Just lo) (Just hi) = gte lo >> lte hi

extractTypeAssertions
  :: MonadFail m
  => TreeType -> WireValue -> m [(Tagged Definition Seg, Path)]
extractTypeAssertions tt = fmap (fmap $ first Tagged) .
  withWireable (extractTypeAssertions' tt) tt

extractTypeAssertions'
  :: forall a m . (Wireable a, MonadFail m)
  => TreeType -> a -> m [(Seg, Path)]
extractTypeAssertions' tt a = case tt of
  TtRef ts -> cast' a >>= Path.fromText Path.segP >>= return . pure . (ts,)
  -- FIXME: this need some factoring!
  TtList tt' ->
    let
      g :: forall b. Wireable b => Proxy b -> m [(Seg, Path)]
      g _ = cast' @[b] a >>=
        mapM (extractTypeAssertions' tt') >>= return . foldMap id
    in
      withTtProxy tt' g
  TtSet tt' ->
    let
      g :: forall b. Wireable b => Proxy b -> m [(Seg, Path)]
      g _ = cast' @[b] a >>=
        mapM (extractTypeAssertions' tt') >>= return . foldMap id
    in
      withTtProxy tt' g
  TtOrdSet tt' ->
    let
      g :: forall b. Wireable b => Proxy b -> m [(Seg, Path)]
      g _ = cast' @[b] a >>=
        mapM (extractTypeAssertions' tt') >>= return . foldMap id
    in
      withTtProxy tt' g
  TtMaybe tt' ->
    let
      g :: forall b. Wireable b => Proxy b -> m [(Seg, Path)]
      g _ = cast' @(Maybe b) a >>=
        mapM (extractTypeAssertions' tt') >>= return . foldMap id
    in
      withTtProxy tt' g
  TtPair tt1 tt2 ->
    let
      g :: forall b c. (Wireable b, Wireable c)
        => Proxy b -> Proxy c -> m [(Seg, Path)]
      g _ _ = cast' @(b, c) a >>=
        bimapM (extractTypeAssertions' tt1) (extractTypeAssertions' tt2) >>=
        \(r1, r2) -> return (r1 <> r2)
    in
      withTtProxy tt1 $ \p1 -> withTtProxy tt2 $ \p2 -> g p1 p2
  _ -> return []

validate' :: (Wireable a, MonadFail m) => TreeType -> a -> m ()
validate' tt a = case tt of
    TtTime -> checkWith @Time pure
    TtEnum ns -> checkWith $ checkEnum ns
    TtWord32 b -> checkWith $ inBounds b
    TtWord64 b -> checkWith $ inBounds b
    TtInt32 b -> checkWith $ inBounds b
    TtInt64 b -> checkWith $ inBounds b
    TtFloat b -> checkWith $ inBounds b
    TtDouble b -> checkWith $ inBounds b
    TtString r -> checkWith $ checkString r
    TtRef _ -> checkWith $ Path.fromText Path.segP
    TtList tt1 -> withTtProxy tt1 $ checkListWith @[] tt1 pure
    TtSet tt1 -> withTtProxy tt1 $
      checkListWith @[] tt1 $ ensureUnique "items"
    TtOrdSet tt1 -> withTtProxy tt1 $
      checkListWith @[] tt1 $ ensureUnique "items"
    TtMaybe tt1 -> withTtProxy tt1 $ checkListWith @Maybe tt1 pure
    TtPair tt1 tt2 ->
      let
        f :: forall b c m. (Wireable b, Wireable c, MonadFail m)
          => Proxy b -> Proxy c -> m ()
        f _ _ = cast' @(b, c) a >>= bimapM_ (validate' tt1) (validate' tt2)
      in
        withTtProxy tt1 (\p1 -> withTtProxy tt2 (\p2 -> f p1 p2))
  where
    checkWith :: (Wireable b, MonadFail m) => (b -> m c) -> m ()
    checkWith f = void $ cast' a >>= f

    checkListWith
      :: forall f b c m. (Foldable f, Wireable b, Wireable (f b), MonadFail m)
      => TreeType -> (f b -> m c) -> Proxy b -> m ()
    checkListWith tt' f _ = checkWith @(f b) $
      \l -> mapM_ (validate' tt') l >> void (f l)

validate :: MonadFail m => TreeType -> WireValue -> m ()
validate tt = withWireable (validate' tt) tt

withWireable
  :: forall m r. MonadFail m
  => (forall a. Wireable a => a -> m r)
  -> TreeType -> WireValue -> m r
withWireable f tt wv = withTtProxy tt go
  where
    go :: forall a. Wireable a => Proxy a -> m r
    go _ = castWireValue @a wv >>= f

bimapM :: Applicative m => (a -> m a') -> (b -> m b') -> (a, b) -> m (a', b')
bimapM fa fb (a, b) = (,) <$> fa a <*> fb b

bimapM_ :: Applicative m => (a -> m ()) -> (b -> m ()) -> (a, b) -> m ()
bimapM_ fa fb = void . bimapM fa fb

checkString :: MonadFail m => Text -> Text -> m Text
checkString r t = maybe
  (fail $ printf "did not match '%s'" r)
  (const $ return t)
  (Text.unpack t =~~ Text.unpack r :: Maybe ())

checkEnum :: MonadFail m => [Seg] -> Word32 -> m Word32
checkEnum ns w = let theMax = fromIntegral $ length ns in
  if w >= theMax
    then fail $ printf "Enum value %v out of range" w
    else return w

class ClassyValidate a1 a2 where
  classyValidate :: MonadFail m => NewTreeType a1 b -> NewWireValue a2 -> m ()

instance ClassyValidate a a where
  classyValidate tt = void . nwvValidate tt

instance ClassyValidate a1 a2 where
  classyValidate _ _ = fail "Parp"

awesomeValidate :: MonadFail m => SomeTreeType -> SomeNewWireValue -> m ()
awesomeValidate (SomeTreeType tt) (SomeNewWireValue wv) = classyValidate tt wv


nwvValidate :: MonadFail m => NewTreeType a b -> NewWireValue a -> m b
nwvValidate tt = myValidate tt . unwrapNwv

myValidate :: forall a b m. MonadFail m => NewTreeType a b -> a -> m b
myValidate = \case
    NttTime -> return
    NttEnum -> safeToEnum . fromIntegral
    NttWord32 b -> inBounds b
    NttString pat -> checkString pat
    NttRef _ -> Path.fromText Path.segP
    NttList tt -> mapM $ myValidate tt
    NttPair tt1 tt2 -> \(x, y) -> (,) <$> myValidate tt1 x <*> myValidate tt2 y

newExtractTypeAssertions :: NewTreeType a b -> b -> [(Seg, Path)]
newExtractTypeAssertions = \case
  NttRef s -> \path -> [(s, path)]
  NttList tt -> foldMap (newExtractTypeAssertions tt)
  NttPair tt1 tt2 -> \(x, y) ->
    newExtractTypeAssertions tt1 x <>
    newExtractTypeAssertions tt2 y
  _ -> const []
