module EndToEnd.Ledger (testSuite) where

-- Prelude imports
import Hydra.Prelude (MonadIO (liftIO))
import PlutusTx.Prelude

-- Haskell imports
import Data.Maybe (fromJust)

-- Haskell test imports
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, testCase, (@=?))

-- Cardano node imports
import Cardano.Api.UTxO qualified as UTxO

-- Plutus imports
import Plutus.V1.Ledger.Value (assetClassValueOf)

-- Hydra imports

import Hydra.Cardano.Api (mkTxIn, toPlutusValue, txOutValue)
import Hydra.Cluster.Fixture (Actor (..))

-- Hydra auction imports
import HydraAuction.OnChain.TestNFT (testNftAssetClass)
import HydraAuction.Runner (
  Runner,
  initWallet,
 )
import HydraAuction.Tx.Common (actorTipUtxo)
import HydraAuction.Tx.Escrow (
  announceAuction,
  bidderBuys,
  sellerReclaims,
  startBidding,
 )
import HydraAuction.Tx.StandingBid (cleanupTx, newBid)
import HydraAuction.Tx.TermsConfig (
  AuctionTermsConfig (
    AuctionTermsConfig,
    configAuctionFeePerDelegate,
    configDiffBiddingEnd,
    configDiffBiddingStart,
    configDiffCleanup,
    configDiffVoucherExpiry,
    configMinimumBidIncrement,
    configStartingBid
  ),
  configToAuctionTerms,
  constructTermsDynamic,
 )
import HydraAuction.Tx.TestNFT (mintOneTestNFT)
import HydraAuction.Types (AuctionTerms (..), intToNatural)

-- Hydra auction test imports
import EndToEnd.Utils (mkAssertion, waitUntil)

testSuite :: TestTree
testSuite =
  testGroup
    "L1 ledger tests"
    [ testCase "Successful auction bid" successfulBidTest
    , testCase "Seller reclaims lot" sellerReclaimsTest
    ]

assertNFTNumEquals :: Actor -> Integer -> Runner ()
assertNFTNumEquals actor expectedNum = do
  utxo <- actorTipUtxo actor
  liftIO $ do
    let value = mconcat [toPlutusValue $ txOutValue out | (_, out) <- UTxO.pairs utxo]
    assetClassValueOf value testNftAssetClass @=? expectedNum

config :: AuctionTermsConfig
config =
  AuctionTermsConfig
    { configDiffBiddingStart = 2
    , configDiffBiddingEnd = 5
    , configDiffVoucherExpiry = 8
    , configDiffCleanup = 10
    , configAuctionFeePerDelegate = fromJust $ intToNatural 4_000_000
    , configStartingBid = fromJust $ intToNatural 8_000_000
    , configMinimumBidIncrement = fromJust $ intToNatural 8_000_000
    }

successfulBidTest :: Assertion
successfulBidTest = mkAssertion $ do
  let seller = Alice
      buyer1 = Bob
      buyer2 = Carol

  mapM_ (initWallet 100_000_000) [seller, buyer1, buyer2]

  nftTx <- mintOneTestNFT seller
  let utxoRef = mkTxIn nftTx 0

  terms <- liftIO $ do
    dynamicState <- constructTermsDynamic seller utxoRef
    configToAuctionTerms config dynamicState

  assertNFTNumEquals seller 1

  announceAuction seller terms

  waitUntil $ biddingStart terms
  startBidding seller terms

  assertNFTNumEquals seller 0

  newBid buyer1 terms $ startingBid terms
  newBid buyer2 terms $ startingBid terms + minimumBidIncrement terms

  waitUntil $ biddingEnd terms
  bidderBuys buyer2 terms

  assertNFTNumEquals seller 0
  assertNFTNumEquals buyer1 0
  assertNFTNumEquals buyer2 1

  waitUntil $ cleanup terms
  cleanupTx seller terms

sellerReclaimsTest :: Assertion
sellerReclaimsTest = mkAssertion $ do
  let seller = Alice

  initWallet 100_000_000 seller

  nftTx <- mintOneTestNFT seller
  let utxoRef = mkTxIn nftTx 0

  terms <- liftIO $ do
    dynamicState <- constructTermsDynamic seller utxoRef
    configToAuctionTerms config dynamicState

  assertNFTNumEquals seller 1
  announceAuction seller terms

  waitUntil $ biddingStart terms
  startBidding seller terms
  assertNFTNumEquals seller 0

  waitUntil $ voucherExpiry terms
  sellerReclaims seller terms

  assertNFTNumEquals seller 1

  waitUntil $ cleanup terms
  cleanupTx seller terms
