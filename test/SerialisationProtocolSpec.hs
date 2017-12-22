{-# LANGUAGE OverloadedStrings #-}
module SerialisationProtocolSpec where
import Test.Hspec

import qualified Data.ByteString as B
import Control.Concurrent.Chan.Unagi as U
import Control.Concurrent.MVar (newEmptyMVar, takeMVar)

import Clapi.Types (UMsgError(..))
import Clapi.Protocol (runProtocolIO, (<<->), sendRev, sendFwd, waitThen)
import Clapi.SerialisationProtocol (serialiser)
import Clapi.Path (root)

spec :: Spec
spec = it "Packetised round trip" $ do
    (bi, bo) <- U.newChan
    (mi, mo) <- U.newChan
    mv <- newEmptyMVar
    runProtocolIO (U.readChan bo) (U.writeChan mi) (chunkyWrite bi) (takeMVar mv) (serialiser <<-> stopProto)
    U.readChan mo `shouldReturn` msgs
  where
    msgs = UMsgError root "part of test"
    chunkyWrite bi c = do
        let (c0, c1) = B.splitAt (B.length c `div` 2) c
        U.writeChan bi c0
        U.writeChan bi c1
    stopProto = do
        sendRev msgs
        waitThen sendFwd undefined