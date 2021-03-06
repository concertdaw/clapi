{-# LANGUAGE
    DataKinds
  , GADTs
  , OverloadedStrings
#-}

module Clapi.RelayApi (relayApiProto, PathNameable(..)) where

import Control.Monad (void)
import Control.Monad.Trans (lift)
import Data.Bifunctor (second)
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Text as Text

import Clapi.PerClientProto (ClientEvent(..), ServerEvent(..))
import Clapi.Types (WireValue(..), TimeStamped(..), Editability(..))
import qualified Clapi.Types.AssocList as AL
import Clapi.Types.Definitions (tupleDef, structDef, arrayDef)
import Clapi.Types.Digests
  ( TrDigest(..), FrDigest(..), SomeTrDigest(..), SomeFrDigest(..)
  , trpdEmpty, OriginatorRole(..), DigestAction(..)
  , DefOp(OpDefine), DataChange(..), DataDigest, ContOps)
import Clapi.Types.SequenceOps (SequenceOp(..))
import Clapi.Types.Name (Name, DataName, Namespace, castName, unName)
import Clapi.Types.Path (pattern Root, pattern (:/), pattern (:</))
import qualified Clapi.Types.Path as Path
import Clapi.Types.Tree (unbounded, ttString, ttFloat, ttRef)
import Clapi.Types.Wire (WireType(..), SomeWireValue(..), someWireable, someWv)
import Clapi.Protocol (Protocol, waitThen, sendFwd, sendRev)
import Clapi.TH (pathq, n)
import Clapi.TimeDelta (tdZero, getDelta, TimeDelta(..))


type RelayApiProtocol i
  = Protocol
      (ClientEvent i (TimeStamped SomeTrDigest))
      (ClientEvent i SomeTrDigest)
      (ServerEvent i SomeFrDigest)
      (Either (Map Namespace i) (ServerEvent i SomeFrDigest))
      IO ()

type OwnerName = DataName

class PathNameable a where
    pathNameFor :: a -> DataName

dn :: Name nr
dn = [n|display_name|]

relayApiProto :: forall i. (Ord i, PathNameable i) => i -> RelayApiProtocol i
relayApiProto selfAddr =
    publishRelayApi >> steadyState mempty mempty
  where
    publishRelayApi = sendFwd $ ClientData selfAddr $ SomeTrDigest $ Trpd
      rns
      mempty
      (Map.fromList $ second OpDefine <$>
        [ ([n|build|], tupleDef "builddoc"
             (AL.singleton [n|commit_hash|] $ ttString "banana")
             Nothing)
        , (clock_diff, tupleDef
             "The difference between two clocks, in seconds"
             (AL.singleton [n|seconds|] $ ttFloat unbounded)
             Nothing)
        , (dn, tupleDef
             "A human-readable name for a struct or array element"
             (AL.singleton [n|name|] $ ttString "")
             Nothing)
        , ([n|client_info|], structDef
             "Info about a single connected client" $ staticAl
             [ (dn, (dn, Editable))
             , (clock_diff, (clock_diff, ReadOnly))
             ])
        , ([n|clients|], arrayDef "Info about the connected clients"
             Nothing [n|client_info|] ReadOnly)
        , ([n|owner_info|], tupleDef "owner info"
             (AL.singleton [n|owner|] $ ttRef [n|client_info|])
             Nothing)
        , ([n|owners|], arrayDef "ownersdoc"
             Nothing [n|owner_info|] ReadOnly)
        , ([n|self|], tupleDef "Which client you are"
             (AL.singleton [n|info|] $ ttRef [n|client_info|])
             Nothing)
        , ([n|relay|], structDef "topdoc" $ staticAl
          [ ([n|build|], ([n|build|], ReadOnly))
          , ([n|clients|], ([n|clients|], ReadOnly))
          , ([n|owners|], ([n|owners|], ReadOnly))
          , ([n|self|], ([n|self|], ReadOnly))])
        ])
      (AL.fromList
        [ ([pathq|/build|], ConstChange Nothing [someWv WtString "banana"])
        , ([pathq|/self|], ConstChange Nothing [
             someWireable $ Path.toText unName selfClientPath])
        , ( selfClientPath :/ clock_diff
          , ConstChange Nothing [someWv WtFloat 0.0])
        , ( selfClientPath :/ dn
          , ConstChange Nothing [someWv WtString "Relay"])
        ])
      mempty
      mempty
    rns = [n|relay|] :: Namespace
    clock_diff :: Name nr
    clock_diff = [n|clock_diff|]
    selfName = pathNameFor selfAddr
    selfClientPath = Root :/ [n|clients|] :/ selfName
    staticAl = AL.fromMap . Map.fromList
    steadyState
      :: Map i TimeDelta -> Map Namespace OwnerName -> RelayApiProtocol i
    steadyState timingMap ownerMap = waitThen fwd rev
      where
        fwd ce = case ce of
          ClientConnect displayName cAddr ->
            let
              cName = pathNameFor cAddr
              timingMap' = Map.insert cAddr tdZero timingMap
            in do
              sendFwd (ClientConnect displayName cAddr)
              pubUpdate (AL.fromList
                [ ( [pathq|/clients|] :/ cName :/ clock_diff
                  , ConstChange Nothing [someWireable $ unTimeDelta tdZero])
                , ( [pathq|/clients|] :/ cName :/ dn
                  , ConstChange Nothing [someWireable $ Text.pack displayName])
                ])
                mempty
              steadyState timingMap' ownerMap
          ClientData cAddr (TimeStamped (theirTime, d)) -> do
            let cName = pathNameFor cAddr
            -- FIXME: this delta thing should probably be in the per client
            -- pipeline, it'd be less jittery and tidy this up
            delta <- lift $ getDelta theirTime
            let timingMap' = Map.insert cAddr delta timingMap
            pubUpdate (AL.singleton ([pathq|/clients|] :/ cName :/ clock_diff)
              $ ConstChange Nothing [someWireable $ unTimeDelta delta])
              mempty
            sendFwd $ ClientData cAddr d
            steadyState timingMap' ownerMap
          ClientDisconnect cAddr ->
            sendFwd (ClientDisconnect cAddr) >> removeClient cAddr
        removeClient cAddr =
          let
            cName = pathNameFor cAddr
            timingMap' = Map.delete cAddr timingMap
            -- FIXME: This feels a bit like reimplementing some of the NST
            ownerMap' = Map.filter (/= cName) ownerMap
            (dd, cops) = ownerChangeInfo ownerMap'
          in do
            pubUpdate dd $ Map.insert [pathq|/clients|]
              (Map.singleton cName (Nothing, SoAbsent)) cops
            steadyState timingMap' ownerMap'
        pubUpdate dd co = sendFwd $ ClientData selfAddr $ SomeTrDigest $ Trpd
          rns mempty mempty dd co mempty

        rev
          :: Either (Map Namespace i) (ServerEvent i SomeFrDigest)
          -> RelayApiProtocol i
        rev (Left ownerAddrs) = do
          let ownerMap' = pathNameFor <$> ownerAddrs
          if elem selfAddr $ Map.elems ownerAddrs
            then do
              uncurry pubUpdate $ ownerChangeInfo ownerMap'
              steadyState timingMap ownerMap'
            else
              -- The relay API did something invalid and got kicked out
              return ()
        rev (Right se) = do
          case se of
            ServerData cAddr sd@(SomeFrDigest d) ->
              case d of
                Frcud {} ->
                  sendRev $ ServerData cAddr $ SomeFrDigest
                  $ d {frcudData = if frcudNs d == rns
                    then viewAs cAddr $ frcudData d
                    else frcudData d}
                Frcrd {} -> void $ sequence $ Map.mapWithKey
                  (\addr _ -> sendRev $ ServerData addr sd) timingMap
                Frpd {} -> if frpdNs d == rns
                  then handleApiRequest d
                  else sendRev se
                _ -> sendRev se
            _ -> sendRev se
          steadyState timingMap ownerMap

        ownerChangeInfo
          :: Map Namespace OwnerName -> (DataDigest, ContOps OwnerName)
        ownerChangeInfo ownerMap' =
            ( AL.fromMap $ Map.mapKeys toOwnerPath $ toSetRefOp <$> ownerMap'
            , Map.singleton [pathq|/owners|] $
                (const (Nothing, SoAbsent)) <$>
                  Map.mapKeysMonotonic castName (ownerMap `Map.difference` ownerMap'))
        toOwnerPath :: Namespace -> Path.Path
        toOwnerPath name = [pathq|/owners|] :/ castName name
        toSetRefOp ns = ConstChange Nothing [
          someWireable $ Path.toText unName $
          Root :/ [n|clients|] :/ ns]
        viewAs :: i -> DataDigest -> DataDigest
        viewAs i dd =
          let
            theirName = pathNameFor i
            theirTime = unTimeDelta $ Map.findWithDefault
              (error "Can't rewrite message for unconnected client") i
              timingMap
            alterTime (ConstChange att [SomeWireValue (WireValue WtFloat t)]) =
              ConstChange att $ pure $ someWireable $ subtract theirTime t
            alterTime _ = error "Weird data back out of VS"
            fiddleDataChanges path dc = case path of
              Root :/ [n|self|] -> toSetRefOp theirName
              [n|clients|] :</ _p -> alterTime dc
              _ -> dc
          in
            AL.fmapWithKey fiddleDataChanges dd
        -- This function trusts that the valuespace has completely validated the
        -- actions the client can perform (i.e. can only change the display name
        -- of a client)
        handleApiRequest
          :: Monad m
          => FrDigest 'Provider 'Update
          -> Protocol a (ClientEvent i SomeTrDigest) b' b m ()
        handleApiRequest frpd =
            sendFwd $ ClientData selfAddr $ SomeTrDigest $
            (trpdEmpty $ frpdNs frpd) {trpdData = frpdData frpd}
