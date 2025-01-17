{-# OPTIONS_GHC -Wno-incomplete-patterns #-}

module Service.MarketDataStream
  ( candlesRequest
  , close
  , infoRequest
  , lastPriceRequest
  , marketDataStream
  , subscribeCandles
  , subscribeInfo
  , subscribeLastPrice
  , subscribeOrderBook
  , subscribeTrades
  , unsubscribeCandles
  , unsubscribeInfo
  , unsubscribeLastPrice
  , unsubscribeOrderBook
  , unsubscribeTrades
  , wait
  ) where

import           Client.Helpers                    (ChanFlow (Next), GrpcClient)

import           Control.Concurrent                (forkIO, newChan, newEmptyMVar, putMVar,
                                                    readChan, takeMVar, writeChan)
import           Control.Concurrent.Async          (async, link)
import           Control.Exception                 ()
import           Control.Lens                      ((&), (.~))
import           Control.Monad
import           Control.Monad.Trans               (MonadIO (..))

import           Data.Int                          (Int32)
import           Data.ProtoLens.Message            (defMessage)
import           Data.ProtoLens.Service.Types      ()
import           Data.Text                         as T (pack)

import           Network.GRPC.Client               (CompressMode (Compressed),
                                                    IncomingEvent (Headers, Invalid, RecvMessage, Trailers),
                                                    OutgoingEvent (Finalize, SendMessage))
import           Network.GRPC.Client.Helpers       (rawGeneralStream)
import           Network.GRPC.HTTP2.ProtoLens      (RPC (..))
import           Network.HTTP2.Client              (runClientIO)

import           Proto.Marketdata
import qualified Proto.Marketdata_Fields           as MD

import           Service.Internal.MarketDataStream (MDStream, MDStreamMonad, STRequest (..),
                                                    STResponse (..), producedBy, (<@), (@>))

printIO ∷ (MonadIO m, Show a) => a -> m ()
printIO = liftIO . print

runAsync ∷ IO a -> IO ()
runAsync f = async f >>= link

marketDataStream ∷ GrpcClient -> MDStreamMonad
marketDataStream gc = liftIO $ do
  closed <- newEmptyMVar
  let myClose = liftIO . putMVar closed $ ()
      genLoopInput chan = \case
          Headers hdrs    -> printIO hdrs >> pure chan
          Trailers _      -> (liftIO . writeChan chan $ StreamStopped) >> myClose >> pure chan
          Invalid err     -> (liftIO . writeChan chan $ StreamError err) >> myClose >> pure chan
          RecvMessage msg -> (liftIO . runAsync . writeChan chan $ Message msg) >> pure chan
      genLoopOutput chan = (liftIO . readChan $ chan) >>= \case
          PostRequest msg -> pure (chan, SendMessage Compressed msg)
          Shutdown        -> pure (chan, Finalize)

  inputChannel <- newChan
  outputChannel <- newChan

  void . forkIO . void . runClientIO $
    rawGeneralStream (RPC :: RPC MarketDataStreamService "marketDataStream") gc inputChannel genLoopInput outputChannel genLoopOutput
  return (closed, outputChannel, inputChannel)

close ∷ MDStream -> IO ()
close stream = stream <@ Shutdown

wait ∷ MDStream -> IO ()
wait (closed, _, _) = takeMVar closed

subscribeMarketData ∷ MDStream -> MarketDataRequest -> (MarketDataResponse -> IO ChanFlow) -> IO ()
subscribeMarketData stream request callback = do
  void $ stream @> \response -> if response `producedBy` request
    then callback response
    else pure Next
  stream <@ PostRequest request

-- OrderBook --
subscribeOrderBook ∷ MDStream -> String -> Int32 -> (MarketDataResponse -> IO ChanFlow) -> IO ()
subscribeOrderBook stream figi depth =
  subscribeMarketData stream (orderBookRequest [(figi, depth)] SUBSCRIPTION_ACTION_SUBSCRIBE)

unsubscribeOrderBook ∷ MDStream -> String -> Int32 -> IO ()
unsubscribeOrderBook stream figi depth =
  void $ stream <@ PostRequest (orderBookRequest [(figi, depth)] SUBSCRIPTION_ACTION_UNSUBSCRIBE)

orderBookRequest ∷ [(String, Int32)] -> SubscriptionAction -> MarketDataRequest
orderBookRequest insts action = defMessage &
  MD.subscribeOrderBookRequest .~ (defMessage &
    MD.subscriptionAction .~ action &
    MD.instruments .~ map (\(figi, depth) -> defMessage & MD.figi .~ T.pack figi & MD.depth .~ depth) insts
  )

-- Candles --
subscribeCandles ∷ MDStream -> String -> SubscriptionInterval -> (MarketDataResponse -> IO ChanFlow) -> IO ()
subscribeCandles stream figi interval =
  subscribeMarketData stream (candlesRequest [(figi, interval)] SUBSCRIPTION_ACTION_SUBSCRIBE)

unsubscribeCandles ∷ MDStream -> String -> SubscriptionInterval -> IO ()
unsubscribeCandles stream figi interval =
  stream <@ PostRequest (candlesRequest [(figi, interval)] SUBSCRIPTION_ACTION_UNSUBSCRIBE)

candlesRequest ∷ [(String, SubscriptionInterval)] -> SubscriptionAction -> MarketDataRequest
candlesRequest insts action = defMessage &
  MD.subscribeCandlesRequest .~ (defMessage &
    MD.subscriptionAction .~ action &
    MD.instruments .~ map (\(figi, interval) -> defMessage & MD.figi .~ T.pack figi & MD.interval .~ interval) insts
  )

-- Trades --
subscribeTrades ∷ MDStream -> String -> (MarketDataResponse -> IO ChanFlow) -> IO ()
subscribeTrades stream figi =
  subscribeMarketData stream (tradesRequest [figi] SUBSCRIPTION_ACTION_SUBSCRIBE)

unsubscribeTrades ∷ MDStream -> String -> IO ()
unsubscribeTrades stream figi = stream <@ PostRequest (tradesRequest [figi] SUBSCRIPTION_ACTION_UNSUBSCRIBE)

tradesRequest ∷ [String] -> SubscriptionAction -> MarketDataRequest
tradesRequest figis action = defMessage &
  MD.subscribeTradesRequest .~ (defMessage &
    MD.subscriptionAction .~ action &
    MD.instruments .~ map (\figi -> defMessage & MD.figi .~ T.pack figi) figis
  )

-- Info --
subscribeInfo ∷ MDStream -> String -> (MarketDataResponse -> IO ChanFlow) -> IO ()
subscribeInfo stream figi = subscribeMarketData stream (infoRequest [figi] SUBSCRIPTION_ACTION_SUBSCRIBE)

unsubscribeInfo ∷ MDStream -> String -> IO ()
unsubscribeInfo stream figi = stream <@ PostRequest (infoRequest [figi] SUBSCRIPTION_ACTION_UNSUBSCRIBE)

infoRequest ∷ [String] -> SubscriptionAction -> MarketDataRequest
infoRequest figis action = defMessage &
  MD.subscribeInfoRequest .~ (defMessage &
    MD.subscriptionAction .~ action &
    MD.instruments .~ map (\figi -> defMessage & MD.figi .~ T.pack figi) figis
  )

-- Last Price --
subscribeLastPrice ∷ MDStream -> String -> (MarketDataResponse -> IO ChanFlow) -> IO ()
subscribeLastPrice stream figi = subscribeMarketData stream (lastPriceRequest [figi] SUBSCRIPTION_ACTION_SUBSCRIBE)

unsubscribeLastPrice ∷ MDStream -> String -> IO ()
unsubscribeLastPrice stream figi = stream <@ PostRequest (lastPriceRequest [figi] SUBSCRIPTION_ACTION_UNSUBSCRIBE)

lastPriceRequest ∷ [String] -> SubscriptionAction -> MarketDataRequest
lastPriceRequest figis action = defMessage &
  MD.subscribeLastPriceRequest .~ (defMessage &
    MD.subscriptionAction .~ action &
    MD.instruments .~ map (\figi -> defMessage & MD.figi .~ T.pack figi) figis
  )
