{-# LANGUAGE LambdaCase #-}

-- |
-- Module:      Data.RTCM3.SBP
-- Copyright:   Copyright (C) 2016 Swift Navigation, Inc.
-- License:     LGPL-3
-- Maintainer:  Mark Fine <dev@swiftnav.com>
-- Stability:   experimental
-- Portability: portable
--
-- RTCMv3 to SBP Conversions.

module Data.RTCM3.SBP
  ( l1CSidCode
  , l2CMSidCode
  , l2PSidCode
  , sbpCMinM
  , q32Width
  , toWn
  , mjdEpoch
  , updateGpsTime
  , convert
  , newStore
  ) where

import           BasicPrelude
import           Control.Lens
import           Control.Monad.Extra
import           Data.Bits
import qualified Data.HashMap.Strict  as M
import           Data.IORef
import           Data.List.Extra      hiding (concat, map)
import           Data.RTCM3
import           Data.RTCM3.SBP.Types
import           Data.Time
import           Data.Word
import           GHC.Stack
import           SwiftNav.SBP


--------------------------------------------------------------------------------
-- SBP, GNSS, RTCM constant definitions


-- | Two centimeters
--
-- SBP pseudoranges are in units of 2cm, and there are 50 of those in a meter.
twoCM :: Double
twoCM = 0.02

sbpCMinM :: Double
sbpCMinM = 50

-- | Speed of light (meters/msec)
lightSpeedMMSEC :: Double
lightSpeedMMSEC = 299792.458

-- | Speed of light (meters/sec)
lightSpeedMS :: Double
lightSpeedMS = 299792458.0

-- | L1 GPS center frequency (Hz)
l1frequency :: Double
l1frequency = 1.57542e9

-- | L2 GPS center frequency (Hz)
l2frequency :: Double
l2frequency = 1.22760e9

-- | We only support PRNS 1 - 32
maxSats :: Word8
maxSats = 32

-- | Q32.8 carrier phase representation width
q32Width :: Double
q32Width = 256

-- | RTCM phase range resolution.
--
-- See DF018, pg. 3-19 of the RTCM3 spec
phaseRangeRes :: Double
phaseRangeRes = 0.0005

-- | SBP L1 GNSS signal value
--
-- See: https://github.com/swift-nav/libswiftnav/blob/master/include/libswiftnav/signal.h#L65
l1CSidCode :: Word8
l1CSidCode = 0

-- | SBP L2CM GNSS signal value
--
-- See: https://github.com/swift-nav/libswiftnav/blob/master/include/libswiftnav/signal.h#L65
l2CMSidCode :: Word8
l2CMSidCode = 1

-- | SBP L1P and L2P GNSS signal values
--
-- Note that libswiftnav currently does not support L1P or L2P observations,
-- just L1C and L2C. This is a stop gap definition so that we can properly
-- serialize out SBP observations with L1P and L2P observations from external
-- receivers.
l1PSidCode :: Word8
l1PSidCode = 5

l2PSidCode :: Word8
l2PSidCode = 6

-- | L2C code indicator value
--
-- See DF016, pg. 3-17 of the RTCM3 spec
codeIndicator_L2C :: Word8
codeIndicator_L2C = 0

-- | L2P code direct indicator value
--
-- See DF016, pg. 3-17 of the RTCM3 spec
codeIndicator_L2P :: Word8
codeIndicator_L2P = 1

-- | L2P code cross-correlated indicator value
--
-- See DF016, pg. 3-17 of the RTCM3 spec
codeIndicator_L2D :: Word8
codeIndicator_L2D = 2

-- | L2P code correlated indicator value
--
-- See DF016, pg. 3-17 of the RTCM3 spec
codeIndicator_L2W :: Word8
codeIndicator_L2W = 3

-- | Map L2 codes to SBP GnssSignal codes
--
l2codeToSBPSignalCode :: HashMap Word8 Word8
l2codeToSBPSignalCode = M.fromList
  [ (codeIndicator_L2C, l2CMSidCode)
  , (codeIndicator_L2P, l2PSidCode)
  , (codeIndicator_L2D, l2PSidCode)
  , (codeIndicator_L2W, l2PSidCode)
  ]

-- | Maximum number of packed observations to allow in a single SBP message.
--
maxObsPerMessage :: Int
maxObsPerMessage = (maxPayloadSize - headerSize) `div` packedObsSize
  where
    maxPayloadSize = 255
    headerSize     = 7
    packedObsSize  = 16


--------------------------------------------------------------------------------
-- General utilities


modifyMap :: (Eq k, Hashable k) => IORef (HashMap k v) -> v -> k -> (v -> v) -> IO v
modifyMap r d k a = do
  m <- readIORef r
  let v = a $ M.lookupDefault d k m
      n = M.insert k v m
  writeIORef r n
  n `seq` return v

maybe' :: Maybe a -> b -> (a -> b) -> b
maybe' m b a = maybe b a m


--------------------------------------------------------------------------------
-- GNSS RTCM observation reconstruction utilities


fromEcefVal :: Int64 -> Double
fromEcefVal x = fromIntegral x / 10000

newGpsTime :: MonadStore e m => Word32 -> m GpsTimeNano
newGpsTime tow = do
  wn <- view storeWn >>= liftIO . readIORef
  return GpsTimeNano
    { _gpsTimeNano_tow = tow
    , _gpsTimeNano_ns  = 0
    , _gpsTimeNano_wn  = wn
    }

-- | If incoming TOW is less than stored TOW, rollover WN.
--
updateGpsTime :: Word32 -> GpsTimeNano -> GpsTimeNano
updateGpsTime tow gpsTime =
  gpsTime & gpsTimeNano_tow .~ tow &
    if tow >= gpsTime ^. gpsTimeNano_tow then id else
      gpsTimeNano_wn %~ (+ 1)

-- | Produce GPS Time from Observation header, handling WN rollover.
--
toGpsTime :: MonadStore e m => GpsObservationHeader -> m GpsTimeNano
toGpsTime hdr = do
  let tow      = hdr ^. gpsObservationHeader_tow
      station  = hdr ^. gpsObservationHeader_station
  gpsTime      <- newGpsTime tow
  gpsTimeMap   <- view storeGpsTimeMap
  liftIO $ modifyMap gpsTimeMap gpsTime station $ updateGpsTime tow

-- | MJD GPS Epoch - First day in GPS week 0. See DF051 of the RTCM3 spec
--
mjdEpoch :: Word16
mjdEpoch = 44244

-- | Convert from MJD to GPS week number
--
-- See DF051 of the RTCM3 spec
toWn :: Word16 -> Word16
toWn mjd = (mjd - mjdEpoch) `div` 7

-- | Determine whether an L1 RTCM observation is invalid.
--
-- See DF011 and DF012 of the RTCM3 spec
invalid_L1 :: GpsL1Observation -> Bool
invalid_L1 l1 =
  l1 ^. gpsL1Observation_pseudorange == 524288 ||
  l1 ^. gpsL1Observation_carrierMinusCode == -524288

-- | Determine whether an L1 + L2 RTCM observation is invalid.
--
-- See DF011, DF012, and DF018 of the RTCM3 spec
invalid_L2 :: GpsL2Observation -> Bool
invalid_L2 l2 =
  l2 ^. gpsL2Observation_pseudorangeDifference == -8192 ||
  l2 ^. gpsL2Observation_carrierMinusCode == -524288

-- | Construct metric pseudorange (meters!) from L1 RTCM observation.
--
-- See DF011, pg. 3-16 of the RTCM3 spec
metricPseudorange :: GpsL1Observation -> GpsL1ExtObservation -> Double
metricPseudorange l1 l1e =
  twoCM * fromIntegral (l1 ^. gpsL1Observation_pseudorange) +
  lightSpeedMMSEC * fromIntegral (l1e ^. gpsL1ExtObservation_ambiguity)

-- | Construct L1 SBP pseudorange for L1 RTCM observation
--
-- See DF011, pg. 3-16 of the RTCM3 spec
toP_L1 :: GpsL1Observation -> GpsL1ExtObservation -> Word32
toP_L1 l1 l1e = round $ sbpCMinM * metricPseudorange l1 l1e

-- | Construct L2 SBP pseudorange from L1/L2 RTCM observations
--
-- See DF017, pg. 3-18 of the RTCM3 spec
toP_L2 :: GpsL1Observation -> GpsL1ExtObservation -> GpsL2Observation -> Word32
toP_L2 l1 l1e l2 = round $ p * sbpCMinM where
  p = metricPseudorange l1 l1e +
      twoCM * fromIntegral (l2 ^. gpsL2Observation_pseudorangeDifference)

-- | Construct SBP L1 GPS carrier phase from L1 RTCM observation
--
-- See DF012, pg. 3-16 of the RTCM3 spec
toL_L1 :: GpsL1Observation -> GpsL1ExtObservation -> CarrierPhase
toL_L1 l1 l1e = CarrierPhase
  { _carrierPhase_i = fromIntegral li
  , _carrierPhase_f = fromIntegral lf
  } where
    p = metricPseudorange l1 l1e
    -- Convert to SBP carrier phase representation per
    -- https://github.com/swift-nav/libsbp/blob/master/spec/yaml/swiftnav/sbp/observation.yaml#L39
    lm :: Double
    lm = p + phaseRangeRes * fromIntegral (l1 ^. gpsL1Observation_carrierMinusCode)
    l = lm / (lightSpeedMS / l1frequency)
    li :: Int32
    li = floor l
    lf :: Word8
    lf = truncate ((l - fromIntegral li) * q32Width)

-- | Construct SBP L2 GPS carrier phase from L2 RTCM observation
--
-- See DF018, pg. 3-18 of the RTCM3 spec
toL_L2 :: GpsL1Observation
       -> GpsL1ExtObservation
       -> GpsL2Observation
       -> GpsL2ExtObservation
       -> CarrierPhase
toL_L2 l1 l1e l2 _l2e = CarrierPhase
  { _carrierPhase_i = fromIntegral li
  , _carrierPhase_f = fromIntegral lf
  } where
    p = metricPseudorange l1 l1e
    -- Convert to SBP carrier phase representation per
    -- https://github.com/swift-nav/libsbp/blob/master/spec/yaml/swiftnav/sbp/observation.yaml#L39
    lm :: Double
    lm = p + phaseRangeRes * fromIntegral (l2 ^. gpsL2Observation_carrierMinusCode)
    l = lm / (lightSpeedMS / l2frequency)
    li :: Int32
    li = floor l
    lf :: Word8
    lf = truncate ((l - fromIntegral li) * q32Width)

toCn0_L1 :: GpsL1ExtObservation -> Word8
toCn0_L1 = (^. gpsL1ExtObservation_cnr)

toCn0_L2 :: GpsL2ExtObservation -> Word8
toCn0_L2 = (^. gpsL2ExtObservation_cnr)

-- | Construct sequenced SBP observation header
--
fromGpsObservationHeader :: MonadStore e m
                         => Word8                -- ^ Total messages
                         -> Word8                -- ^ Message in sequence
                         -> GpsObservationHeader -- ^ RTCM observation header
                         -> m ObservationHeader
fromGpsObservationHeader totalMsgs n hdr = do
  t <- toGpsTime hdr
  return ObservationHeader
    { _observationHeader_t     = t
    -- First nibble is the size of the sequence (n), second nibble is the
    -- zero-indexed counter (ith packet of n). See observation header packing
    -- https://github.com/swift-nav/libsbp/blob/master/spec/yaml/swiftnav/sbp/observation.yaml#L63
    , _observationHeader_n_obs = totalMsgs `shiftL` 4 .|. n
    }

-- | Construct an L1 GnssSignal
--
toL1GnssSignal :: Word8 -> GpsL1Observation -> GnssSignal16
toL1GnssSignal sat l1 =
  GnssSignal16
    { _gnssSignal16_sat  = sat
    , _gnssSignal16_code = if l1 ^. gpsL1Observation_code then l1PSidCode else l1CSidCode
    }

-- | Construct an L1 SBP PackedObsContent an RTCM satellite vehicle observation
--
fromL1SatelliteObservation :: MonadStore e m
                           => Word8               -- ^ Satellite PRN
                           -> GpsL1Observation
                           -> GpsL1ExtObservation
                           -> m PackedObsContent
fromL1SatelliteObservation sat l1 l1e = do
  -- Checks GPS L1 code indicator for RTCM message 1002.
  -- See DF010, pg. 3-17 of the RTCM3 spec.
  let sid = toL1GnssSignal sat l1
  return PackedObsContent
    { _packedObsContent_P     = toP_L1 l1 l1e
    , _packedObsContent_L     = toL_L1 l1 l1e
    , _packedObsContent_D     = errorWithStackTrace "D"
    , _packedObsContent_cn0   = toCn0_L1 l1e
    , _packedObsContent_lock  = l1 ^. gpsL1Observation_lockTime
    , _packedObsContent_sid   = sid
    , _packedObsContent_flags = errorWithStackTrace "flags"
    }

-- | Construct an L2 GnssSignal
--
toL2GnssSignal :: Word8 -> GpsL2Observation -> Maybe GnssSignal16
toL2GnssSignal sat l2 = do
  code <- M.lookup (l2 ^. gpsL2Observation_code) l2codeToSBPSignalCode
  return GnssSignal16
    { _gnssSignal16_sat  = fromIntegral sat
    , _gnssSignal16_code = code
    }

-- | Construct an L2 SBP PackedObsContent an RTCM satellite vehicle observation
--
fromL2SatelliteObservation :: MonadStore e m
                           => Word8                  -- ^ Satellite PRN
                           -> GpsL1Observation
                           -> GpsL1ExtObservation
                           -> GpsL2Observation
                           -> GpsL2ExtObservation
                           -> m (Maybe PackedObsContent)
fromL2SatelliteObservation sat l1 l1e l2 l2e =
  -- Checks GPS L2 code indicator.
  -- See DF016, pg. 3-17 of the RTCM3 spec.
  maybe' (toL2GnssSignal sat l2) (return Nothing) $ \sid -> do
    return $ Just PackedObsContent
      { _packedObsContent_P     = toP_L2 l1 l1e l2
      , _packedObsContent_L     = toL_L2 l1 l1e l2 l2e
      , _packedObsContent_D     = errorWithStackTrace "D"
      , _packedObsContent_cn0   = toCn0_L2 l2e
      , _packedObsContent_lock  = l2 ^. gpsL2Observation_lockTime
      , _packedObsContent_sid   = sid
      , _packedObsContent_flags = errorWithStackTrace "flags"  
    }

-- | Construct SBP GPS observation message (possibly chunked).
--
chunkToMsgObs :: MonadStore e m
              => GpsObservationHeader -- ^ RTCM observation header
              -> Word8                -- ^ Total messages
              -> Word8                -- ^ Message in sequence
              -> [PackedObsContent]
              -> m MsgObs
chunkToMsgObs hdr totalMsgs n packed = do
  header <- fromGpsObservationHeader totalMsgs n hdr
  return MsgObs
    { _msgObs_header = header
    , _msgObs_obs    = packed
    }

-- | 16 bit SBP Sender Id is 12 bit RTCM Station Id with high nibble or'd in
--
toSender :: Word16 -> Word16
toSender = (.|. 0xf000)


--------------------------------------------------------------------------------
-- RTCM to SBP conversion utilities: RTCM Msgs. 1002 (L1 RTK), 1004 (L1+L2 RTK),
-- 1005 (antenna position), 1006 (antenna position).


-- | Construct an L1 SBP PackedObsContent from an RTCM Msg 1002.
--
fromObservation1002 :: MonadStore e m => Observation1002 -> m [PackedObsContent]
fromObservation1002 obs = do
  obs1 <- fromL1SatelliteObservation sat l1 l1e
  return $
    -- Only lower set of PRN numbers (1-32) are supported
    if sat > maxSats then mempty else
      if invalid_L1 l1 then mempty else
        [obs1]
  where
    sat = obs ^. observation1002_sat
    l1  = obs ^. observation1002_l1
    l1e = obs ^. observation1002_l1e


-- | Convert an RTCM L1 1002 observation into an SBP MsgObs.
--
-- This chunking takes places because the number of observations in a given 1002
-- may very well exceed the maximum SBP supported payload size of 255 bytes.
fromMsg1002 :: MonadStore e m => Msg1002 -> m [MsgObs]
fromMsg1002 m = do
  let hdr = m ^. msg1002_header
  obs <- concatMapM fromObservation1002 $ m ^. msg1002_observations
  let chunks    = zip [0..] $ chunksOf maxObsPerMessage obs
      totalMsgs = fromIntegral $ length chunks
  forM chunks $ uncurry $ chunkToMsgObs hdr totalMsgs

-- | Construct an L1/L2 SBP PackedObsContent from an RTCM Msg 1004.
--
fromObservation1004 :: MonadStore e m => Observation1004 -> m [PackedObsContent]
fromObservation1004 obs = do
  obs1 <- fromL1SatelliteObservation sat l1 l1e
  obs2 <- fromL2SatelliteObservation sat l1 l1e l2 l2e
  return $
    -- Only lower set of PRN numbers (1-32) are supported
    if sat > maxSats then mempty else
      if invalid_L1 l1 && invalid_L2 l2 then mempty else
        if invalid_L1 l1 then maybeToList obs2 else
          if invalid_L2 l2 then [obs1] else
            obs1 : maybeToList obs2
  where
    sat = obs ^. observation1004_sat
    l1  = obs ^. observation1004_l1
    l1e = obs ^. observation1004_l1e
    l2  = obs ^. observation1004_l2
    l2e = obs ^. observation1004_l2e


-- | Convert an RTCM L1+L2 1004 observation into multiple SBP MsgObs.
--
-- This chunking takes places because the number of observations in a given 1004
-- may very well exceed the maximum SBP supported payload size of 255 bytes.
fromMsg1004 :: MonadStore e m => Msg1004 -> m [MsgObs]
fromMsg1004 m = do
  let hdr = m ^. msg1004_header
  obs <- concatMapM fromObservation1004 $ m ^. msg1004_observations
  let chunks    = zip [0..] $ chunksOf maxObsPerMessage obs
      totalMsgs = fromIntegral $ length chunks
  forM chunks $ uncurry $ chunkToMsgObs hdr totalMsgs

-- | Convert an RTCM 1005 antenna reference position message into an SBP
-- MsgBasePosEcef.
fromMsg1005 :: MonadStore e m => Msg1005 -> m MsgBasePosEcef
fromMsg1005 m =
  return MsgBasePosEcef
    { _msgBasePosEcef_x = fromEcefVal $ m ^. msg1005_reference ^. antennaReference_ecef_x
    , _msgBasePosEcef_y = fromEcefVal $ m ^. msg1005_reference ^. antennaReference_ecef_y
    , _msgBasePosEcef_z = fromEcefVal $ m ^. msg1005_reference ^. antennaReference_ecef_z
    }

-- | Convert an RTCM 1006 antenna reference position message into an SBP
-- MsgBasePosEcef.
fromMsg1006 :: MonadStore e m => Msg1006 -> m MsgBasePosEcef
fromMsg1006 m =
  return MsgBasePosEcef
    { _msgBasePosEcef_x = fromEcefVal $ m ^. msg1006_reference ^. antennaReference_ecef_x
    , _msgBasePosEcef_y = fromEcefVal $ m ^. msg1006_reference ^. antennaReference_ecef_y
    , _msgBasePosEcef_z = fromEcefVal $ m ^. msg1006_reference ^. antennaReference_ecef_z
    }

-- | Convert an RTCM message into possibly multiple SBP messages.
--
convert :: MonadStore e m => RTCM3Msg -> m [SBPMsg]
convert = \case
  (RTCM3Msg1002 m _rtcm3) -> do
    let sender = m ^. msg1002_header ^. gpsObservationHeader_station
    m' <- fromMsg1002 m
    return $ flip fmap m' $ \x -> SBPMsgObs x $ toSBP x $ toSender sender
  (RTCM3Msg1004 m _rtcm3) -> do
    let sender = m ^. msg1004_header ^. gpsObservationHeader_station
    m' <- fromMsg1004 m
    return $ flip fmap m' $ \x -> SBPMsgObs x $ toSBP x $ toSender sender
  (RTCM3Msg1005 m _rtcm3) -> do
    let sender =  m ^. msg1005_reference ^. antennaReference_station
    m' <- fromMsg1005 m
    return [SBPMsgBasePosEcef m' $ toSBP m' $ toSender sender]
  (RTCM3Msg1006 m _rtcm3) -> do
    let sender = m ^. msg1006_reference ^. antennaReference_station
    m' <- fromMsg1006 m
    return [SBPMsgBasePosEcef m' $ toSBP m' $ toSender sender]
  (RTCM3Msg1013 m _rtcm3) -> do
    wn <- view storeWn
    liftIO $ writeIORef wn $ toWn $ m ^. msg1013_header ^. messageHeader_mjd
    return mempty
  _rtcm3Msg -> return mempty

newStore :: IO Store
newStore = do
  day <- utctDay <$> getCurrentTime
  let wn = fromIntegral $ div (diffDays day (fromGregorian 1980 1 6)) 7
  Store <$> newIORef wn <*> newIORef mempty
