{-# OPTIONS_GHC -Wall -Wno-orphans #-}
{-# LANGUAGE PatternSynonyms #-}

module Clapi.Types.Messages where

import Data.Text (Text)
import Data.Word (Word32)

import Clapi.Types.Base (Attributee, Time, Interpolation)
import Clapi.Types.Definitions (Definition, Liberty)
import Clapi.Types.Path (Seg, Path, TypeName(..), pattern (:</))
import qualified Clapi.Types.Path as Path
import Clapi.Types.Wire (WireValue)

-- FIXME: redefinition
type TpId = Word32

data ErrorIndex a
  = GlobalError
  | PathError Path
  | TimePointError Path TpId
  | TypeNameError a
  deriving (Show, Eq, Ord)

splitErrIdx :: ErrorIndex TypeName -> Maybe (Seg, ErrorIndex Seg)
splitErrIdx ei = case ei of
  GlobalError -> Nothing
  PathError p -> fmap PathError <$> Path.splitHead p
  TimePointError p tpid -> fmap (flip TimePointError tpid) <$> Path.splitHead p
  TypeNameError (TypeName ns s) -> Just (ns, TypeNameError s)

namespaceErrIdx :: Seg -> ErrorIndex Seg -> ErrorIndex TypeName
namespaceErrIdx ns ei = case ei of
  GlobalError -> GlobalError
  PathError p -> PathError $ ns :</ p
  TimePointError p tpid -> TimePointError (ns :</ p) tpid
  TypeNameError s -> TypeNameError $ TypeName ns s

data MsgError a
  = MsgError {errIndex :: ErrorIndex a, errMsgTxt :: Text} deriving (Eq, Show)

data DefMessage a
  = MsgDefine a Definition
  | MsgUndefine a
  deriving (Show, Eq)

data SubMessage
  = MsgSubscribe {subMsgPath :: Path}
  | MsgTypeSubscribe {subMsgTypeName :: TypeName}
  | MsgUnsubscribe {subMsgPath :: Path}
  | MsgTypeUnsubscribe {subMsgTypeName :: TypeName}
  deriving (Eq, Show)

data TypeMessage = MsgAssignType Path TypeName Liberty deriving (Show, Eq)

data DataUpdateMessage
  = MsgInit
      { duMsgPath :: Path
      , duMsgAttributee :: Maybe Attributee
      }
  | MsgDelete
      { duMsgPath :: Path
      , duMsgAttributee :: Maybe Attributee
      }
  | MsgConstSet
      { duMsgPath :: Path
      , duMsgArgs :: [WireValue]
      , duMsgAttributee :: Maybe Attributee
      }
  | MsgSet
      { duMsgPath :: Path
      , duMsgTpId :: TpId
      , duMsgTime :: Time
      , duMsgArgs :: [WireValue]
      , duMsgInterpolation :: Interpolation
      , duMsgAttributee :: Maybe Attributee
      }
  | MsgRemove
      { duMsgPath :: Path
      , duMsgTpId :: Word32
      , duMsgAttributee :: Maybe Attributee
      }
  | MsgReorder
      { duMsgPath :: Path
      , duMsgReorderings :: Seg
      , duMsgReorderReference :: Maybe Seg
      , duMsgAttributee :: Maybe Attributee
      }
   deriving (Eq, Show)

data ToRelayProviderBundle = ToRelayProviderBundle
  { trpbNamespace :: Seg
  , trpbErrors :: [MsgError Seg]
  , trpbDefinitions :: [DefMessage Seg]
  , trpbData :: [DataUpdateMessage]
  } deriving (Show, Eq)

data ToRelayProviderRelinquish
  = ToRelayProviderRelinquish Seg deriving (Show, Eq)

data FromRelayProviderBundle = FromRelayProviderBundle
  { frpbNamespace :: Seg
  , frpbData :: [DataUpdateMessage]
  } deriving (Show, Eq)

data FromRelayProviderErrorBundle = FromRelayProviderErrorBundle
  { frpebNamespace :: Seg
  , frpebErrors :: [MsgError Seg]
  } deriving (Eq, Show)

data ToRelayClientBundle = ToRelayClientBundle
  { trcbSubs :: [SubMessage]
  , trcbData :: [DataUpdateMessage]
  } deriving (Eq, Show)

data FromRelayClientBundle = FromRelayClientBundle
  { frcbErrors :: [MsgError TypeName]
  , frcbDefinitions :: [DefMessage TypeName]
  , frcbTypeAssignments :: [TypeMessage]
  , frcbData :: [DataUpdateMessage]
  } deriving (Show, Eq)

data ToRelayBundle
  = Trpb ToRelayProviderBundle
  | Trpr ToRelayProviderRelinquish
  | Trcb ToRelayClientBundle
  deriving Show

data FromRelayBundle
  = Frpb FromRelayProviderBundle
  | Frpeb FromRelayProviderErrorBundle
  | Frcb FromRelayClientBundle
  deriving Show
