{-# LANGUAGE
    FlexibleInstances
  , MultiParamTypeClasses
#-}

module Clapi.Valuespace.Errors where

import Control.Monad.Fail (MonadFail(..))
import Data.List (intercalate)
import Data.Set (Set)
import Data.Text (Text)
import qualified Data.Text as Text
import Text.Printf (printf)

import Clapi.Internal.Valuespace (EPS)
import Clapi.Types.Base (TpId, InterpolationType)
import Clapi.Types.Name (DataName, DefName, Placeholder, PostDefName)
import Clapi.Valuespace.ErrWrap (Wraps(..))
import Clapi.Valuespace.Xrefs (Referer)


class ErrText e where
  errText :: e -> Text

newtype ErrorString = ErrorString { unErrorString :: String }

instance Wraps String ErrorString where
  wrap = ErrorString

data AccessError
  = NodeNotFound
  | DefNotFound DefName
  | PostDefNotFound PostDefName

instance ErrText AccessError where
  errText = Text.pack . \case
    NodeNotFound -> "Node not found"
    DefNotFound dn -> printf "Definition %s not found" $ show dn
    PostDefNotFound dn ->
      printf "Post definition %s not found" $ show dn

data ValidationError
  -- FIXME: DataValidationError is a wrapper for MonadFail stuff that comes out
  -- of validation. It would be better to have a whole type for validation
  -- errors that can come from the Validation module:
  = DataValidationError String
  | XRefError DefName DefName
  -- FIXME: this really should contain two InterpolationType values, but because
  -- we currently don't distinguish between TS tuples and const tuples at the
  -- type level, the interpolation type we were expecting is technically
  -- optional:
  | BadInterpolationType InterpolationType (Maybe InterpolationType)

instance ErrText ValidationError where
  errText = Text.pack . \case
    DataValidationError s -> "ValidationError: " ++ s
    XRefError expDn actDn -> printf
      "Bad xref target type. Expected %s, got %s" (show expDn) (show actDn)
    BadInterpolationType actual expected -> printf
      "Bad interpolation type %s. Expected <= %s" (show actual) (show expected)


-- | Raised when client's attempts to mutate the data in the tree is
--   inconsistent with the structure of the tree.
data StructuralError
  = TsChangeOnConst | ConstChangeOnTs
  | UnexpectedNodeType
  -- FIXME: Check that this can be raised by both Consumers and Providers:
  | SeqOpsOnNonArray

instance ErrText StructuralError where
  errText = Text.pack . \case
    TsChangeOnConst -> "Time series change on constant data node"
    ConstChangeOnTs -> "Constant data change on time series data node"
    UnexpectedNodeType -> "Unexpected node type"
    SeqOpsOnNonArray -> "Array rearrangement operation on non-array"


data SeqOpError i
  -- FIXME: Check both Consumers and Providers can raise these
  = SeqOpMovedMissingChild i
  | SeqOpTargetMissing i i

instance Show soTarget => ErrText (SeqOpError soTarget) where
  errText = Text.pack . \case
    SeqOpMovedMissingChild kid -> printf
      "Array rearrangment attempted to move missing member %s" (show kid)
    SeqOpTargetMissing seg eps -> printf
      "Array rearrangment attempt to move member %s after non-existent target %s"
      (show seg) (show eps)



-- FIXME: I think there will end up being ProviderErrors that we make when we
-- try to apply an Frpd and then a ConsumerErrors that we make when we try to
-- apply a client update digest.
-- FIXME: There may even be a common subset for things that both the API
-- provider and the consumer can get wrong. For example, referencing missing
-- nodes.
data ProviderError
  = PEAccessError AccessError
  | CircularStructDefinitions [DefName]
  | MissingNodeData
  | PEValidationError ValidationError
  | PEStructuralError StructuralError
  | PESeqOpError (SeqOpError DataName)
  -- FIXME: This is currently only exposed when handling implicit removes from
  -- Provider definition updates, but we could potentially be invalid if a
  -- Consumer drops a member of an array!
  | RemovedWhileReferencedBy (Set (Referer, Maybe TpId))
  -- FIXME: ErrorString is too generic, as it loses where the error came
  -- from. It is _not_ a wrapper for errors that were generated by providers, so
  -- we should be able to be much more specific!
  | PEErrorString String

instance ErrText ProviderError where
  errText = Text.pack . \case
    PEAccessError ae -> Text.unpack $ errText ae
    PEStructuralError se -> Text.unpack $ errText se
    PESeqOpError soe -> Text.unpack $ errText soe
    CircularStructDefinitions dns ->
      "Circular struct definitions: "
      ++ intercalate " -> " (show <$> dns)
    MissingNodeData -> "Missing node data"
    RemovedWhileReferencedBy referers -> printf "Removed path referenced by %s"
      (show referers)
    PEValidationError ve -> Text.unpack $ errText ve
    PEErrorString s -> s

instance Wraps AccessError ProviderError where
  wrap = PEAccessError

instance Wraps ValidationError ProviderError where
  wrap = PEValidationError

instance Wraps StructuralError ProviderError where
  wrap = PEStructuralError

instance Wraps (SeqOpError DataName) ProviderError where
  wrap = PESeqOpError

instance Wraps ErrorString ProviderError where
  wrap = PEErrorString . unErrorString


data ConsumerError
  = CEAccessError AccessError
  | CEStructuralError StructuralError
  | CESeqOpError (SeqOpError EPS)
  | CEValidationError ValidationError
  | ReadOnlyEdit
  | ReadOnlySeqOps  -- FIXME: potentially combine with ReadOnlyEdit
  | CreatesNotSupported
  | MultipleCreatesReferencedTarget (Set Placeholder) (Maybe EPS)
  | CyclicReferencesInCreates [Placeholder]
  | MissingCreatePositionTarget Placeholder EPS
  | CEErrorString String

instance ErrText ConsumerError where
  errText = Text.pack . \case
    CEAccessError ae -> Text.unpack $ errText ae
    CEValidationError ve -> Text.unpack $ errText ve
    CEStructuralError se -> Text.unpack $ errText se
    CESeqOpError soe -> Text.unpack $ errText soe
    ReadOnlyEdit -> "Data change at read-only path"
    ReadOnlySeqOps -> "Tried to alter the children of a read-only path"
    CreatesNotSupported -> "Creates not supported"
    MultipleCreatesReferencedTarget phs targ -> printf
      "Multiple create operations (%s) referernced the same position target (%s)"
      (show phs) (show targ)
    CyclicReferencesInCreates targs ->
      "Several create operations formed a loop with their position targets: "
      ++ intercalate " -> "
      (show <$> targs)
    MissingCreatePositionTarget ph eps -> printf
      "Create for %s references missing position target %s"
      (show ph) (show eps)
    CEErrorString s -> s

instance Wraps AccessError ConsumerError where
  wrap = CEAccessError

instance Wraps ValidationError ConsumerError where
  wrap = CEValidationError

instance Wraps StructuralError ConsumerError where
  wrap = CEStructuralError

instance Wraps (SeqOpError EPS) ConsumerError where
  wrap = CESeqOpError

instance Wraps ErrorString ConsumerError where
  wrap = CEErrorString . unErrorString


instance MonadFail (Either ErrorString) where
  fail = Left . ErrorString

instance MonadFail (Either ValidationError) where
  fail = Left . DataValidationError
