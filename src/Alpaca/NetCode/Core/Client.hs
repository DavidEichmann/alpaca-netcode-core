{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

-- | Rollback and replay based game networking
module Alpaca.NetCode.Core.Client
  ( runClient
  , ClientConfig (..)
  , defaultClientConfig
  , Client
  , clientPlayerId
  , clientSample
  , clientSample'
  , clientSetInput
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM as STM
import Control.Monad
import qualified Data.IORef as IORef
import Data.Int (Int64)
import Data.IntMap (IntMap)
import qualified Data.IntMap as IM
import qualified Data.Map as M
import Data.Maybe (catMaybes, fromMaybe, isJust, isNothing)
import qualified Data.Set as S
import qualified Data.Text as T
import Flat
import qualified System.Environment as Env
import qualified System.Metrics.Gauge as Gauge
import qualified System.Metrics.Label as Label
import qualified System.Remote.Monitoring as Ekg
import Text.Read

import Alpaca.NetCode.Core.ClockSync
import Alpaca.NetCode.Core.Common

-- | A Client. You'll generally obtain this via @Alpaca.NetCode.runClient@.
data Client world input = Client
  { -- | The client's @PlayerId@
    clientPlayerId :: PlayerId
  , -- | Sample the world state. This will roll back and replay inputs as
    -- necessary. This returns:
    --
    -- * New authoritative world states in chronological order since the last
    --   sample time. These world states are the True world states at each
    --   tick. This list will be empty if no new authoritative world states have
    --   been derived since that last call to this sample function. Though it's
    --   often simpler to just use the predicted world state, you can use these
    --   authoritative world states to render output when you're not willing to
    --   miss-predict but are willing to have greater latency.
    -- * The predicted world state for the current time. This extrapolates past
    --   the latest know authoritative world state by assuming no user inputs
    --   have changed (unless otherwise known e.g. our own player's inputs are
    --   known).
    --
    clientSample' :: IO ([world], world)
  , -- | Set the current input. This will be used on the next tick. In
    -- godot, you'll likely collect inputs by impelemnting _input or similar
    -- and calling this function.
    clientSetInput :: input -> IO ()
  }

-- | Sample the current predicted world state of a client. This will roll back
-- and replay inputs as necessary.
clientSample :: Client world input -> IO world
clientSample client = snd <$> clientSample' client

-- | Configuration options specific to clients.
data ClientConfig = ClientConfig
  {
  -- | Tick rate (ticks per second). Must be the same across all clients and the
  -- server. Packet rate and hence network bandwidth will scale linearly with
  -- this the tick rate.
    ccTickRate :: Int
  -- | Add this constant amount of latency (in seconds) to this client's inputs.
  -- A good value is 0.03 or something between 0 and 0.1. May differ between
  -- clients.
  --
  -- Too high of a value and the player will get annoyed at the extra input
  -- latency. On the other hand, a higher value means less miss-predictions for
  -- other clients. In the extreme case, if this is set to something higher than
  -- ping, there will be no miss predictions: all clients will receive inputs
  -- before rendering the corresponding tick.
  , ccFixedInputLatency :: Float
  -- | Maximum number of ticks to predict. If the client is this many ticks
  -- behind the target tick, it will simply stop at an earlier tick. You may
  -- want to scale this value along with the tick rate. May differ between
  -- clients.
  , ccMaxPredictionTicks :: Int
  -- | If the client's latest auth world is this many ticks behind the target
  -- tick, no prediction will be done at all. We want to safe CPU cycles for
  -- catching up with the server. You may want to scale this value along with
  -- the tick rate. May differ between clients.
  , ccResyncThresholdTicks :: Int
  }

-- | Sensible defaults for @ClientConfig@ based on the tick rate.
defaultClientConfig ::
  -- | Tick rate (ticks per second). Must be the same across all clients and the
  -- server. Packet rate and hence network bandwidth will scale linearly with
  -- this the tick rate.
  Int ->
  ClientConfig
defaultClientConfig tickRate = ClientConfig
  { ccTickRate = tickRate
  , ccFixedInputLatency = 0.03
  , ccMaxPredictionTicks = tickRate `div` 2
  , ccResyncThresholdTicks = tickRate * 3
  }

-- | Start a networked client. This blocks until the initial handshake with the
-- server is finished.
runClient ::
  forall world input.
  Flat input =>
  -- | Function to send messages to the server. The underlying communication
  -- protocol need only guarantee data integrity but is otherwise free to drop
  -- and reorder packets. Typically this is backed by a UDP socket.
  (NetMsg input -> IO ()) ->
  -- | Chan to receive messages from the server. Has the same requirements as
  -- the send TChan.
  (IO (NetMsg input)) ->
  -- | Optional simulation of network conditions. In production this should be
  -- `Nothing`. May differ between clients.
  Maybe SimNetConditions ->
  -- | The @defaultClientConfig@ works well for most cases.
  ClientConfig ->
  -- | Initial input for new players. Must be the same across all clients and
  -- the server.
  input ->
  -- | Initial world state. Must be the same across all clients.
  world ->
  -- | A deterministic stepping function (for a single tick). Must be the same
  -- across all clients and the server. Takes:
  --
  -- * a map from PlayerId to (previous, current) input.
  -- * current game tick.
  -- * previous tick's world state
  --
  -- It is important that this is deterministic else clients' states will
  -- diverge. Beware of floating point non-determinism!
  ( M.Map PlayerId (input, input) ->
    Tick ->
    world ->
    world
  ) ->
  IO (Client world input)
runClient sendToServer' rcvFromServer' simNetConditionsMay clientConfig input0 world0 stepOneTick = playCommon (ccTickRate clientConfig) $ \tickTime getTime _resetTime -> do
  (sendToServer, rcvFromServer) <- simulateNetConditions
    sendToServer'
    rcvFromServer'
    simNetConditionsMay

  -- Authoritative Map from tick and PlayerId to inputs. The inner map is
  -- always complete (e.g. if we have the IntMap for tick i, then it contains
  -- the inputs for *all* known players)
  authInputsTVar :: TVar (IntMap (M.Map PlayerId input)) <- newTVarIO (IM.singleton 0 M.empty)

  -- Tick to authoritative world state.
  authWorldsTVar :: TVar (IntMap world) <- newTVarIO (IM.singleton 0 world0)

  -- Max known auth inputs tick without any prior missing ticks.
  maxAuthTickTVar :: TVar Tick <- newTVarIO 0

  -- This client/host's PlayerId. Initially nothing, then set to Just the
  -- player ID on connection to the server. This is a constant thereafter.
  myPlayerIdTVar <- newTVarIO (Nothing :: Maybe PlayerId)

  -- Non-authoritative Map from tick and PlayerId to inputs. The inner map
  -- is NOT always complete (e.g. if we have the IntMap for tick i, then
  -- it may or may not yet contain all the inputs for *all* known players).
  hintInputsTVar :: TVar (IntMap (M.Map PlayerId input)) <- newTVarIO (IM.singleton 0 M.empty)

  -- Clock Sync
  (estimateServerTickPlusLatencyPlusBufferPlus, recordClockSyncSample, clockAnalytics) <- initializeClockSync tickTime getTime
  let estimateServerTickPlusLatencyPlusBuffer = estimateServerTickPlusLatencyPlusBufferPlus 0

  -- Analytics output
  packetRecvCounterIORef <- IORef.newIORef 0
  packetRecvCounterIORef_Msg_Connect <- IORef.newIORef 0
  packetRecvCounterIORef_Msg_Connected <- IORef.newIORef 0
  packetRecvCounterIORef_Msg_Heartbeat <- IORef.newIORef 0
  packetRecvCounterIORef_Msg_Ack <- IORef.newIORef 0
  packetRecvCounterIORef_Msg_HeartbeatResponse <- IORef.newIORef 0
  packetRecvCounterIORef_Msg_AuthInput <- IORef.newIORef 0
  packetRecvCounterIORef_Msg_HintInput <- IORef.newIORef 0
  packetRecvCounterIORef_Msg_SubmitInput <- IORef.newIORef 0
  packetRecvCounterIORef_Msg_RequestAuthInput <- IORef.newIORef 0
  _ <-
    forkIO $
      Env.lookupEnv "NET_EKG" >>= \case
        Nothing -> return ()
        Just portStr -> case readMaybe portStr of
          Nothing -> return ()
          Just port -> do
            -- Server
            putStrLn $ "Starting EKG server: http://localhost:" ++ show port ++ "/"
            -- store <- Metrics.newStore
            server <- Ekg.forkServer "localhost" port

            -- Metrics
            metricPlayerLable <- Ekg.getLabel "rogue.player" server
            metricPacketsPerSecDown <- Ekg.getGauge "rogue.packets_per_second_download" server
            metricPacketsPerSecDown_Msg_Connect <- Ekg.getGauge "rogue.packets_down.msg_connect" server
            metricPacketsPerSecDown_Msg_Connected <- Ekg.getGauge "rogue.packets_down.msg_connected" server
            metricPacketsPerSecDown_Msg_Heartbeat <- Ekg.getGauge "rogue.packets_down.msg_heartbeat" server
            metricPacketsPerSecDown_Msg_Ack <- Ekg.getGauge "rogue.packets_down.msg_ack" server
            metricPacketsPerSecDown_Msg_HeartbeatResponse <- Ekg.getGauge "rogue.packets_down.msg_heartbeatresponse" server
            metricPacketsPerSecDown_Msg_AuthInput <- Ekg.getGauge "rogue.packets_down.msg_authinput" server
            metricPacketsPerSecDown_Msg_HintInput <- Ekg.getGauge "rogue.packets_down.msg_hintinput" server
            metricPacketsPerSecDown_Msg_SubmitInput <- Ekg.getGauge "rogue.packets_down.msg_submitinput" server
            metricPacketsPerSecDown_Msg_RequestAuthInput <- Ekg.getGauge "rogue.packets_down.msg_requestauthinput" server
            metricPacketsPerSecUp <- Ekg.getGauge "rogue.packets_per_second_upload" server
            metricBytesPerSecDown <- Ekg.getGauge "rogue.download_bytes_per_s" server
            metricBytesPerSecUp <- Ekg.getGauge "rogue.upload_bytes_per_s" server
            metricPingMs <- Ekg.getGauge "rogue.ping_ms" server
            metricClockErrorMs <- Ekg.getGauge "rogue.clock_error_ms" server
            metricMissingAuthInputTicks <- Ekg.getGauge "rogue.missing_auth_input_ticks" server
            metricMaxAuthWorldTick <- Ekg.getGauge "rogue.max_auth_world_tick" server

            -- Collect metrics
            forever $ do
              threadDelay 1000000 -- 1 s
              Tick targetTick <- estimateServerTickPlusLatencyPlusBuffer
              analyticsMay <- clockAnalytics
              case analyticsMay of
                Nothing -> return ()
                Just (pingSec, clockErrorSec) -> do
                  let toMs s = (round (1000 * s))
                  Gauge.set metricPingMs (toMs pingSec)
                  Gauge.set metricClockErrorMs (toMs clockErrorSec)

                  let doCount ref g = Gauge.set g =<< IORef.atomicModifyIORef' ref (\x -> (0, x))
                  doCount packetRecvCounterIORef metricPacketsPerSecDown
                  doCount packetRecvCounterIORef_Msg_Connect metricPacketsPerSecDown_Msg_Connect
                  doCount packetRecvCounterIORef_Msg_Connected metricPacketsPerSecDown_Msg_Connected
                  doCount packetRecvCounterIORef_Msg_Heartbeat metricPacketsPerSecDown_Msg_Heartbeat
                  doCount packetRecvCounterIORef_Msg_Ack metricPacketsPerSecDown_Msg_Ack
                  doCount packetRecvCounterIORef_Msg_HeartbeatResponse metricPacketsPerSecDown_Msg_HeartbeatResponse
                  doCount packetRecvCounterIORef_Msg_AuthInput metricPacketsPerSecDown_Msg_AuthInput
                  doCount packetRecvCounterIORef_Msg_HintInput metricPacketsPerSecDown_Msg_HintInput
                  doCount packetRecvCounterIORef_Msg_SubmitInput metricPacketsPerSecDown_Msg_SubmitInput
                  doCount packetRecvCounterIORef_Msg_RequestAuthInput metricPacketsPerSecDown_Msg_RequestAuthInput

                  join $
                    atomically $ do
                      playerIdMay <- readTVar myPlayerIdTVar
                      authInputs <- readTVar authInputsTVar
                      let maxAuthTickBroken = fst $ IM.findMax authInputs
                      Tick maxAuthTick <- readTVar maxAuthTickTVar
                      let missingAuthInputTicks = length $ filter (`IM.member` authInputs) [fromIntegral maxAuthTick .. maxAuthTickBroken]
                      authWorlds <- readTVar authWorldsTVar
                      let maxAuthWorldTick = fst $ IM.findMax authWorlds
                      return $ do
                        -- putStrLn $ ""
                        -- putStrLn $ "Max (unbroken) Input tick:      " ++ show' maxAuthTick ++ "   (" ++ showLowIsBetter 13 40 (maxAuthTickBroken - maxAuthTick) ++ " from max)"
                        -- putStrLn $ "Max            Input tick:      " ++ show' maxAuthTickBroken
                        -- putStrLn $ "Missing auth input ticks:       " ++ showLowIsBetter 4 7 missingAuthInputTicks
                        -- putStrLn $ ""
                        -- putStrLn $ "Max auth world tick:            " ++ show' maxAuthWorldTick ++ "   (" ++ showLowIsBetter 13 20 (targetTick - maxAuthWorldTick) ++ " from target)"
                        -- putStrLn $ "Target tick:                    " ++ show' targetTick
                        Label.set metricPlayerLable (maybe "" (T.pack . show . unPlayerId) playerIdMay)
                        Gauge.set metricMissingAuthInputTicks (fromIntegral missingAuthInputTicks)
                        Gauge.set metricMaxAuthWorldTick (fromIntegral maxAuthWorldTick)

  -- Keep trying to connect to the server.
  _ <- forkIO $
    forever $ do
      clientSendTime <- getTime
      isConnected <- isJust <$> atomically (readTVar myPlayerIdTVar)
      sendToServer ((if isConnected then Msg_Heartbeat else Msg_Connect) clientSendTime)
      isClockReady <- isJust <$> clockAnalytics
      threadDelay $
        if isClockReady
          then 500000 -- 0.5 seconds
          else 50000 -- 0.05 seconds

  -- Main message processing loop
  _ <- forkIO $
    forever $ do
      msg <- rcvFromServer
      IORef.atomicModifyIORef' packetRecvCounterIORef (\x -> (x + 1, ()))
      case msg of
        Msg_Connect{} ->
          IORef.atomicModifyIORef' packetRecvCounterIORef_Msg_Connect (\x -> (x + 1, ()))
        Msg_Connected{} ->
          IORef.atomicModifyIORef' packetRecvCounterIORef_Msg_Connected (\x -> (x + 1, ()))
        Msg_SubmitInput{} ->
          IORef.atomicModifyIORef' packetRecvCounterIORef_Msg_SubmitInput (\x -> (x + 1, ()))
        Msg_Ack{} ->
          IORef.atomicModifyIORef' packetRecvCounterIORef_Msg_Ack (\x -> (x + 1, ()))
        Msg_RequestAuthInput{} ->
          IORef.atomicModifyIORef' packetRecvCounterIORef_Msg_RequestAuthInput (\x -> (x + 1, ()))
        Msg_Heartbeat{} ->
          IORef.atomicModifyIORef' packetRecvCounterIORef_Msg_Heartbeat (\x -> (x + 1, ()))
        Msg_HeartbeatResponse{} ->
          IORef.atomicModifyIORef' packetRecvCounterIORef_Msg_HeartbeatResponse (\x -> (x + 1, ()))
        Msg_AuthInput{} ->
          IORef.atomicModifyIORef' packetRecvCounterIORef_Msg_AuthInput (\x -> (x + 1, ()))
        Msg_HintInput{} ->
          IORef.atomicModifyIORef' packetRecvCounterIORef_Msg_HintInput (\x -> (x + 1, ()))

      case msg of
        Msg_Connect{} -> putStrLn "Client received unexpected Msg_Connect from the server. Ignoring."
        Msg_Connected playerId -> do
          join $
            atomically $ do
              playerIdMay <- readTVar myPlayerIdTVar
              case playerIdMay of
                Nothing -> do
                  writeTVar myPlayerIdTVar (Just playerId)
                  return (putStrLn $ "Connected! " ++ show playerId)
                Just playerId' -> return $ putStrLn $ "Got Msg_Connected " ++ show playerId' ++ "but already connected (with " ++ show playerId
        Msg_SubmitInput{} -> putStrLn "Client received unexpected Msg_SubmitInput from the server. Ignoring."
        Msg_Ack{} ->
          putStrLn "Client received unexpected Msg_Ack from the server. Ignoring."
        Msg_RequestAuthInput{} ->
          putStrLn "Client received unexpected Msg_RequestAuthInput from the server. Ignoring."
        Msg_Heartbeat{} ->
          putStrLn "Client received unexpected Msg_Heartbeat from the server. Ignoring."
        Msg_HeartbeatResponse clientSendTime serverReceiveTime -> do
          -- Record times for ping/clock sync.
          clientReceiveTime <- getTime
          recordClockSyncSample clientSendTime serverReceiveTime clientReceiveTime
        Msg_AuthInput headTick authInputssCompact hintInputssCompact -> do
          let authInputss = fromCompactMaps authInputssCompact
          let hintInputss = fromCompactMaps hintInputssCompact
          resMsgs <- do
            -- Update maxAuthTickTVar if needed and send heartbeat
            ackMsg <- atomically $ do
              maxAuthTick <- readTVar maxAuthTickTVar
              let newestTick = headTick + fromIntegral (length authInputss) - 1
                  maxAuthTick' =
                    if headTick <= maxAuthTick + 1 && maxAuthTick < newestTick
                      then newestTick
                      else maxAuthTick
              writeTVar maxAuthTickTVar maxAuthTick'
              return (Msg_Ack maxAuthTick')
            sendToServer ackMsg

            -- Save new auth inputs
            let newAuthTickHi = headTick + Tick (fromIntegral $ length authInputss)
            resMsg <- forM (zip [headTick ..] authInputss) $ \(tick, inputs) -> do
              atomically $ do
                authInputs <- readTVar authInputsTVar
                -- when (tickInt `mod` 100 == 0) (putStrLn $ "Received auth tick: " ++ show tickInt)
                case authInputs IM.!? fromIntegral tick of
                  Just _ -> return $ Just $ "Received a duplicate Msg_AuthInput for " ++ show tick ++ ". Ignoring."
                  Nothing -> do
                    -- New auth inputs
                    writeTVar authInputsTVar (IM.insert (fromIntegral tick) inputs authInputs)
                    return (Just $ "Got auth-inputs for " ++ show tick)

            -- Save new hint inputs, Excluding my own!
            forM_ (zip [succ newAuthTickHi ..] hintInputss) $ \(tick, newHintinputs) ->
              atomically $ do
                myPlayerIdMay <- readTVar myPlayerIdTVar
                modifyTVar hintInputsTVar $
                  IM.alter
                    ( \case
                        Just oldHintinputs
                          | Just myPlayerId <- myPlayerIdMay ->
                            Just (M.restrictKeys oldHintinputs (S.singleton myPlayerId) <> newHintinputs <> oldHintinputs)
                        _ -> Just newHintinputs
                    )
                    (fromIntegral tick)

            -- Request any missing inputs
            authInputs <- atomically $ readTVar authInputsTVar
            authWorlds <- atomically $ readTVar authWorldsTVar
            let (loTickInt, _) = fromMaybe (error "Impossible! must have at least initial world") (IM.lookupMax authWorlds)
                (hiTickInt, _) = fromMaybe (error "Impossible! must have at least initial inputs") (IM.lookupMax authInputs)
                missingTicks = Tick . fromIntegral <$> take (fromIntegral maxRequestAuthInputs) (filter (flip IM.notMember authInputs) [loTickInt + 1 .. hiTickInt - 1])
            when (not (null missingTicks)) $ sendToServer (Msg_RequestAuthInput missingTicks)
            return resMsg
          mapM_ debugStrLn (catMaybes resMsgs)
        Msg_HintInput tick playerId inputs -> do
          res <- atomically $ do
            hintInputs <- readTVar hintInputsTVar
            let hintInputsAtTick = fromMaybe M.empty (hintInputs IM.!? fromIntegral tick)
            writeTVar hintInputsTVar (IM.insert (fromIntegral tick) (M.insert playerId inputs hintInputsAtTick) hintInputs)
            return (Just $ "Got hint-inputs for " ++ show tick)
          mapM_ debugStrLn res

  -- Wait to be connected.
  atomically $ do
    myPlayerIdMay <- readTVar myPlayerIdTVar
    when (isNothing myPlayerIdMay) retry
    return ()

  -- Now we're connected, start the game loop
  serverTickPlusLatency0 <- estimateServerTickPlusLatencyPlusBuffer
  currentInputTVar <- newTVarIO input0
  --   ([], serverTickPlusLatency0, input0)
  --   -- Collected events (reversed) last submitted inputs tick,
  lastSampledAuthWorldTickTVar :: TVar Tick <- newTVarIO 0 -- last returned auth world tick (inclusive) from the returned sampling funciton
  lastTickTVar <- newTVarIO serverTickPlusLatency0 -- last submitted input's tick
  --   -- last tick's input
  myPlayerId <- atomically $ do
    pidMay <- readTVar myPlayerIdTVar
    maybe retry return pidMay
  return $ Client
    { clientPlayerId = myPlayerId
    , clientSample' = do
        -- TODO We can send (non-auth) inputs p2p!

        -- TODO we're just resimulating from the last snapshot every
        -- time. We may be able to reuse past simulation data if
        -- snapshot / inputs haven't changed.

        -- Since we are sending inputs for tick
        -- estimateServerTickPlusLatencyPlusBuffer and we want to minimize
        -- perceived input latency, we should target that same tick
        targetTick <- estimateServerTickPlusLatencyPlusBuffer
        (inputs, hintInputs, startTickInt, startWorld) <- atomically $ do
          (startTickInt, startWorld) <-
            fromMaybe (error $ "No authoritative world found <= " ++ show targetTick) -- We have at least the initial world
              . IM.lookupLE (fromIntegral targetTick)
              <$> readTVar authWorldsTVar
          inputs <- readTVar authInputsTVar
          hintInputs <- readTVar hintInputsTVar
          return (inputs, hintInputs, startTickInt, startWorld)
        let startInputs =
              fromMaybe
                (error $ "Have auth world but no authoritative inputs at " ++ show startTick) -- We assume that we always have auth inputs on ticks where we have auth worlds.
                (IM.lookup startTickInt inputs)
            startTick = Tick (fromIntegral startTickInt)

            predict ::
              Int64 -> -- How many ticks of prediction to allow
              Tick -> -- Some tick i
              M.Map PlayerId input -> -- inputs at tick i
              world -> -- world at tick i if simulated
              Bool -> -- Is the world authoritative?
              IO world -- world at targetTick (or latest tick if predictionAllowance ran out)
            predict predictionAllowance tick tickInputs world isWAuth = case compare tick targetTick of
              LT -> do
                let tickNext = tick + 1

                    inputsNextAuthMay = inputs IM.!? (fromIntegral tickNext) -- auth input
                    isInputsNextAuth = isJust inputsNextAuthMay
                    isWNextAuth = isWAuth && isInputsNextAuth
                if isWNextAuth || predictionAllowance > 0
                  then do
                    let inputsNextHintPart = fromMaybe M.empty (hintInputs IM.!? (fromIntegral tickNext)) -- partial hint inputs
                        inputsNextHintFilled = inputsNextHintPart `M.union` tickInputs -- hint input (filled with previous input)
                        inputsNext = fromMaybe inputsNextHintFilled inputsNextAuthMay

                        zippedInputs =
                          M.mapWithKey
                            ( \playerId newInput ->
                                let oldInput = fromMaybe input0 (tickInputs M.!? playerId)
                                 in (oldInput, newInput)
                            )
                            inputsNext

                    let wNext = stepOneTick zippedInputs tickNext world
                    when isWNextAuth $
                      atomically $ modifyTVar authWorldsTVar (IM.insert (fromIntegral tickNext) wNext)

                    let predictionAllowance' = if isWNextAuth then predictionAllowance else predictionAllowance - 1
                    predict predictionAllowance' tickNext inputsNext wNext isWNextAuth
                  else do
                    -- putStrLn $ "Prediction allowance ran out. Stopping " ++ show (targetTick - tick) ++ " ticks early."
                    return world
              EQ -> return world
              GT -> error "Impossible! simulated past target tick!"

        -- let Tick tickDuration = targetTick - startTick
        -- when (tickDuration > 20) $ do
        --   putStrLn $ "WARNING: simulating a lot of ticks: " ++ show tickDuration
        --   putStrLn $ "    latest auth world: " ++ show startTick

        -- If very behind the server, we want to do 0 prediction
        maxAuthTick <- atomically $ readTVar maxAuthTickTVar
        let predictionAllowance =
              if targetTick - maxAuthTick > Tick (fromIntegral $ ccResyncThresholdTicks clientConfig)
                then 0
                else fromIntegral (ccMaxPredictionTicks clientConfig)

        predictedTargetW <- predict predictionAllowance startTick startInputs startWorld True
        -- let predictedTargetPic = draw predictedTargetW

        -- putStrLn $ "Drawing " ++ show targetTick ++ " based on snapshot from " ++ show startTick
        -- let
        --   Tick inputCount = targetTick - startTick
        --   Tick simCount = targetTick - startTick
        --   in putStrLn $ "Replay tick count (input, simulating) = ("
        --               ++ show inputCount ++ ", " ++ show simCount ++ ")"

        newAuthWorlds :: [world] <- atomically $ do
          lastSampledAuthWorldTick <- readTVar lastSampledAuthWorldTickTVar
          authWorlds <- readTVar authWorldsTVar
          let latestAuthWorldTick = Tick $ fromIntegral $ fst $ IM.findMax authWorlds
          writeTVar lastSampledAuthWorldTickTVar latestAuthWorldTick
          return ((authWorlds IM.!) . fromIntegral <$> [lastSampledAuthWorldTick + 1 .. latestAuthWorldTick])

        return (newAuthWorlds, predictedTargetW)
    , clientSetInput =
      \newInput -> do
        -- We submit events as soon as we expect the server to be on a future
        -- tick. Else we just store the new input.
        targetTick <- estimateServerTickPlusLatencyPlusBufferPlus (ccFixedInputLatency clientConfig)
        join $ atomically $ do
          -- event (esRev, lastTick, lastInput) -> do
          lastTick <- readTVar lastTickTVar
          writeTVar currentInputTVar newInput
          if targetTick > lastTick
            then do
              -- If we've jumped a few ticks forward than we keep the old input
              -- constant as other clients would have predicte that by now.
              -- forM_ [lastTick+1..targetTick-1] (commitInput lastInput)
              writeTVar lastTickTVar targetTick

              -- Store our own inputs as a hint so we get 0 latency. This is
              -- only a hint and not authoritative as it's still possible that
              -- submitted inputs are dropped or rejected by the server.
              modifyTVar hintInputsTVar
                $ IM.alter
                    (Just . M.insert myPlayerId newInput . fromMaybe M.empty)
                    (fromIntegral targetTick)

              -- TODO we need to duplicate send to protect from dropped packets)
              return (sendToServer (Msg_SubmitInput targetTick newInput))
            else pure (return ())
    }
