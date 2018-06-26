
module Clapi.RelayApi (relayApiProto, PathSegable(..)) where

import Control.Monad.Trans (lift)
import Data.Bifunctor (bimap)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Tagged (Tagged(..))
import Data.Text (Text)
import qualified Data.Text as Text

import Clapi.PerClientProto (ClientEvent(..), ServerEvent(..))
import Clapi.Types
  ( TrDigest(..), TrpDigest(..), FrDigest(..), FrpDigest(..), WireValue(..)
  , TimeStamped(..), Liberty(..))
import Clapi.Types.AssocList (alSingleton, alFromMap, alFmapWithKey, alFromList)
import Clapi.Types.Base (InterpolationLimit(ILUninterpolated))
import Clapi.Types.Definitions (tupleDef, structDef, arrayDef)
import Clapi.Types.Digests
  (DefOp(OpDefine), DataChange(..), FrcDigest(..), DataDigest, ContainerOps)
import Clapi.Types.SequenceOps (SequenceOp(..))
import Clapi.Types.Path
  ( Seg, TypeName(..), tTypeName, pattern Root, pattern (:/), pattern (:</)
  , Namespace(..))
import qualified Clapi.Types.Path as Path
import Clapi.Types.Tree (TreeType(..), unbounded)
import Clapi.Types.Wire (castWireValue)
import Clapi.Protocol (Protocol, waitThen, sendFwd, sendRev)
import Clapi.TH (pathq, segq)
import Clapi.TimeDelta (tdZero, getDelta, TimeDelta(..))
import Clapi.Valuespace (apiNs, dnSeg)

class PathSegable a where
    pathNameFor :: a -> Seg

relayApiProto ::
    forall i. (Ord i, PathSegable i) =>
    i ->
    Protocol
        (ClientEvent i (TimeStamped TrDigest))
        (ClientEvent i TrDigest)
        (ServerEvent i FrDigest)
        (Either (Map Namespace i) (ServerEvent i FrDigest))
        IO ()
relayApiProto selfAddr =
    publishRelayApi >> steadyState mempty mempty
  where
    publishRelayApi = sendFwd $ ClientData selfAddr $ Trpd $ TrpDigest
      rns
      mempty
      (Map.fromList $ bimap Tagged OpDefine <$>
        [ ([segq|build|], tupleDef "builddoc"
             (alSingleton [segq|commit_hash|] $ TtString "banana")
             ILUninterpolated)
        , (clock_diff, tupleDef
             "The difference between two clocks, in seconds"
             (alSingleton [segq|seconds|] $ TtFloat unbounded)
             ILUninterpolated)
        , ([segq|client_info|], structDef
             "Info about a single connected client" $ staticAl
             [ (dnSeg, (tTypeName apiNs dnSeg, May))
             , (clock_diff, (tTypeName rns clock_diff, Cannot))
             ])
        , ([segq|clients|], arrayDef "Info about the connected clients"
             (tTypeName rns [segq|client_info|]) Cannot)
        , ([segq|owner_info|], tupleDef "owner info"
             (alSingleton [segq|owner|]
               -- FIXME: want to make Ref's TypeName tagged...
               $ TtRef $ TypeName rns [segq|client_info|])
             ILUninterpolated)
        , ([segq|owners|], arrayDef "ownersdoc"
             (tTypeName rns [segq|owner_info|]) Cannot)
        , ([segq|self|], tupleDef "Which client you are"
             (alSingleton [segq|info|]
               $ TtRef $ TypeName rns [segq|client_info|])
             ILUninterpolated)
        , ([segq|relay|], structDef "topdoc" $ staticAl
          [ ([segq|build|], (tTypeName rns [segq|build|], Cannot))
          , ([segq|clients|], (tTypeName rns [segq|clients|], Cannot))
          , ([segq|owners|], (tTypeName rns [segq|owners|], Cannot))
          , ([segq|self|], (tTypeName rns [segq|self|], Cannot))])
        ])
      (alFromList
        [ ([pathq|/build|], ConstChange Nothing [WireValue @Text "banana"])
        , ([pathq|/self|], ConstChange Nothing [
             WireValue $ Path.toText Path.unSeg $ selfSeg :</ selfClientPath])
        , ( selfClientPath :/ clock_diff
          , ConstChange Nothing [WireValue @Float 0.0])
        , ( selfClientPath :/ dnSeg
          , ConstChange Nothing [WireValue @Text "Relay"])
        ])
      mempty
      mempty
    rns = Namespace [segq|relay|]
    clock_diff = [segq|clock_diff|]
    selfSeg = pathNameFor selfAddr
    selfClientPath = Root :/ [segq|clients|] :/ selfSeg
    staticAl = alFromMap . Map.fromList
    steadyState
      :: Map Seg TimeDelta -> Map Namespace Seg -> Protocol
            (ClientEvent i (TimeStamped TrDigest))
            (ClientEvent i TrDigest)
            (ServerEvent i FrDigest)
            (Either (Map Namespace i) (ServerEvent i FrDigest))
            IO ()
    steadyState timingMap ownerMap = waitThen fwd rev
      where
        fwd ce = case ce of
          ClientConnect displayName cAddr ->
            let
              cSeg = pathNameFor cAddr
              timingMap' = Map.insert cSeg tdZero timingMap
            in do
              sendFwd (ClientConnect displayName cAddr)
              pubUpdate (alFromList
                [ ( [pathq|/clients|] :/ cSeg :/ clock_diff
                  , ConstChange Nothing [WireValue $ unTimeDelta tdZero])
                , ( [pathq|/clients|] :/ cSeg :/ dnSeg
                  , ConstChange Nothing [WireValue $ Text.pack displayName])
                ])
                mempty
              steadyState timingMap' ownerMap
          ClientData cAddr (TimeStamped (theirTime, d)) -> do
            let cSeg = pathNameFor cAddr
            -- FIXME: this delta thing should probably be in the per client
            -- pipeline, it'd be less jittery and tidy this up
            delta <- lift $ getDelta theirTime
            let timingMap' = Map.insert cSeg delta timingMap
            pubUpdate (alSingleton ([pathq|/clients|] :/ cSeg :/ clock_diff)
              $ ConstChange Nothing [WireValue $ unTimeDelta delta])
              mempty
            sendFwd $ ClientData cAddr d
            steadyState timingMap' ownerMap
          ClientDisconnect cAddr ->
            sendFwd (ClientDisconnect cAddr) >> removeClient cAddr
        removeClient cAddr =
          let
            cSeg = pathNameFor cAddr
            timingMap' = Map.delete cSeg timingMap
            -- FIXME: This feels a bit like reimplementing some of the NST
            ownerMap' = Map.filter (/= cSeg) ownerMap
            (dd, cops) = ownerChangeInfo ownerMap'
          in do
            pubUpdate dd $ Map.insert [pathq|/clients|]
              (Map.singleton cSeg (Nothing, SoAbsent)) cops
            steadyState timingMap' ownerMap'
        pubUpdate dd co = sendFwd $ ClientData selfAddr $ Trpd $ TrpDigest
          rns mempty mempty dd co mempty
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
            ServerData cAddr d ->
              case d of
                Frcd frcd ->
                  sendRev $ ServerData cAddr $ Frcd
                  $ frcd {frcdData = viewAs cAddr $ frcdData frcd}
                Frpd frpd -> if frpdNamespace frpd == rns
                  then handleApiRequest frpd
                  else sendRev se
                _ -> sendRev se
            _ -> sendRev se
          steadyState timingMap ownerMap
        ownerChangeInfo :: Map Namespace Seg -> (DataDigest, ContainerOps args)
        ownerChangeInfo ownerMap' =
            ( alFromMap $ Map.mapKeys toOwnerPath $ toSetRefOp <$> ownerMap'
            , Map.singleton [pathq|/owners|] $
                (const (Nothing, SoAbsent)) <$>
                  Map.mapKeys unNamespace (ownerMap `Map.difference` ownerMap'))
        toOwnerPath :: Namespace -> Path.Path
        toOwnerPath s = [pathq|/owners|] :/ unNamespace s
        toSetRefOp ns = ConstChange Nothing [
          WireValue $ Path.toText Path.unSeg $
          Root :/ selfSeg :/ [segq|clients|] :/ ns]
        viewAs i dd =
          let
            theirSeg = pathNameFor i
            theirTime = unTimeDelta $ Map.findWithDefault
              (error "Can't rewrite message for unconnected client") theirSeg
              timingMap
            alterTime (ConstChange att [wv]) = ConstChange att $ pure
              $ WireValue $ subtract theirTime $ either error id
              $ castWireValue wv
            alterTime _ = error "Weird data back out of VS"
            fiddleDataChanges p dc
              | p `Path.isChildOf` [pathq|/relay/clients|] = alterTime dc
              | p == [pathq|/relay/self|] = toSetRefOp theirSeg
              | otherwise = dc
          in
            alFmapWithKey fiddleDataChanges dd
        -- This function trusts that the valuespace has completely validated the
        -- actions the client can perform (i.e. can only change the name of a
        -- client)
        handleApiRequest (FrpDigest ns dd cops) =
          let
            cops' = (fmap . fmap . fmap . fmap) (const ()) cops
          in
            sendFwd $ ClientData selfAddr $ Trpd $
            TrpDigest ns mempty mempty dd cops' mempty
