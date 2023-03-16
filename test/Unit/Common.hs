module Unit.Common (testSuite) where

-- Prelude imports

import Hydra.Prelude (MonadIO (liftIO))
import PlutusTx.Prelude
import Prelude qualified

-- Haskell imports

import Control.Monad.TimeMachine (travelTo)
import Control.Monad.TimeMachine.Cockpit (later, minutes)
import Data.Maybe (fromJust)

-- Haskell test imports

import Test.QuickCheck (arbitrary)
import Test.QuickCheck.Gen (generate)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, testCase, (@?=))

-- Hydra
import Hydra.Cardano.Api (TxIn)
import Hydra.Ledger.Cardano ()

-- Plutus imports
import Plutus.V1.Ledger.Interval (from, interval, to)

-- Hydra auction imports
import HydraAuction.Fixture (Actor (..))
import HydraAuction.OnChain.Common (secondsLeftInInterval)
import HydraAuction.Tx.Common (currentAuctionStage)
import HydraAuction.Tx.TermsConfig (
  AuctionTermsConfig (..),
  configToAuctionTerms,
  constructTermsDynamic,
 )
import HydraAuction.Types (AuctionStage (..), intToNatural)

testSuite :: TestTree
testSuite =
  testGroup
    "Unit-Common"
    [ testCase "current-auction-stage" testCurrentAuctionStage
    , testCase "seconds-left-interval" testSecondsLeftInterval
    ]

testCurrentAuctionStage :: Assertion
testCurrentAuctionStage = do
  -- Using minutes, cuz TimeMachine does not support seconds
  -- Using actual time, cuz TimeMachine does not support nesting mocks
  -- Could just use absolute time mocks instead

  let config =
        AuctionTermsConfig
          { configDiffBiddingStart = 1 * 60 - 2
          , configDiffBiddingEnd = 2 * 60 - 2
          , configDiffVoucherExpiry = 3 * 60 - 2
          , configDiffCleanup = 4 * 60 - 2
          , configAuctionFeePerDelegate = fromJust $ intToNatural 4_000_000
          , configStartingBid = fromJust $ intToNatural 8_000_000
          , configMinimumBidIncrement = fromJust $ intToNatural 8_000_000
          }

  nonce <- generate arbitrary :: Prelude.IO TxIn

  -- TODO: halt
  terms <- liftIO $ do
    dynamicState <- constructTermsDynamic Alice nonce
    configToAuctionTerms config dynamicState

  assertStageAtTime terms (0 `minutes` later) AnnouncedStage
  assertStageAtTime terms (1 `minutes` later) BiddingStartedStage
  assertStageAtTime terms (2 `minutes` later) BiddingEndedStage
  assertStageAtTime terms (3 `minutes` later) VoucherExpiredStage
  assertStageAtTime terms (4 `minutes` later) CleanupStage
  where
    assertStageAtTime terms timeDiff expectedStage = do
      stage <- travelTo timeDiff $ currentAuctionStage terms
      liftIO $ stage @?= expectedStage

testSecondsLeftInterval :: Assertion
testSecondsLeftInterval = do
  let now = 1000
      interval1 = to 5000
      interval2 = interval 5000 15000
      interval3 = from 15000

  secondsLeftInInterval now interval1 @?= Just 4
  secondsLeftInInterval now interval2 @?= Just 14
  secondsLeftInInterval now interval3 @?= Nothing
