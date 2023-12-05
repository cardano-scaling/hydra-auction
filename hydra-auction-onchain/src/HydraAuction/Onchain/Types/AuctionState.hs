module HydraAuction.Onchain.Types.AuctionState (
  AuctionEscrowState (..),
  StandingBidState (..),
  validateNewBid,
  validateBuyer,
  sellerPayout,
) where

import PlutusTx.Prelude

import PlutusLedgerApi.V1 (CurrencySymbol, PubKeyHash)
import PlutusTx qualified

import HydraAuction.Onchain.Lib.Error (eCode, err)

import HydraAuction.Error.Types.AuctionState (
  Buyer'Error (..),
  NewBid'Error (..),
 )
import HydraAuction.Onchain.Types.AuctionTerms (
  AuctionTerms (..),
  totalAuctionFees,
 )
import HydraAuction.Onchain.Types.BidTerms (
  BidTerms (..),
  validateBidTerms,
 )
import HydraAuction.Onchain.Types.BidderInfo (BidderInfo (..))

data AuctionEscrowState
  = AuctionAnnounced
  | BiddingStarted
  | AuctionConcluded

newtype StandingBidState = StandingBidState
  { standingBidState :: Maybe BidTerms
  }

-- -------------------------------------------------------------------------
-- New bid validation
-- -------------------------------------------------------------------------

validateNewBid ::
  AuctionTerms ->
  CurrencySymbol ->
  StandingBidState ->
  StandingBidState ->
  Bool
validateNewBid auTerms auctionId oldBidState StandingBidState {..}
  | Just newTerms <- standingBidState =
      validateNewBidTerms auTerms auctionId newTerms
        && validateCompareBids auTerms oldBidState newTerms
  | otherwise =
      --
      -- (NewBid01)
      -- The new bid state should not be empty.
      False
        `err` $(eCode NewBid'Error'EmptyNewBid)

validateNewBidTerms ::
  AuctionTerms ->
  CurrencySymbol ->
  BidTerms ->
  Bool
validateNewBidTerms =
  --
  -- (NewBid02)
  -- The new bid terms are valid.
  validateBidTerms

validateCompareBids ::
  AuctionTerms ->
  StandingBidState ->
  BidTerms ->
  Bool
validateCompareBids auTerms StandingBidState {..} newTerms
  | Just oldTerms <- standingBidState =
      validateBidIncrement auTerms oldTerms newTerms
  | otherwise =
      validateStartingBid auTerms newTerms

validateBidIncrement ::
  AuctionTerms ->
  BidTerms ->
  BidTerms ->
  Bool
validateBidIncrement AuctionTerms {..} oldTerms newTerms =
  --
  -- (NewBid03)
  -- The difference between the old and new bid price is
  -- no smaller than the auction's minimum bid increment.
  (bt'BidPrice oldTerms + at'MinBidIncrement <= bt'BidPrice newTerms)
    `err` $(eCode NewBid'Error'InvalidBidIncrement)

validateStartingBid ::
  AuctionTerms ->
  BidTerms ->
  Bool
validateStartingBid AuctionTerms {..} BidTerms {..} =
  --
  -- (NewBid04)
  -- The first bid's price is
  -- no smaller than the auction's starting price.
  (at'StartingBid <= bt'BidPrice)
    `err` $(eCode NewBid'Error'InvalidStartingBid)

-- -------------------------------------------------------------------------
-- Buyer validation
-- -------------------------------------------------------------------------

validateBuyer ::
  AuctionTerms ->
  CurrencySymbol ->
  StandingBidState ->
  PubKeyHash ->
  Bool
validateBuyer auTerms auctionId StandingBidState {..} buyer
  | Just bidTerms@BidTerms {..} <- standingBidState
  , BidderInfo {..} <- bt'Bidder =
      --
      -- (Buyer01)
      -- The buyer's hashed payment verification key corresponds
      -- to the bidder's payment verification key.
      (buyer == bi'BidderPkh)
        `err` $(eCode Buyer'Error'BuyerVkPkhMismatch)
        --
        -- (Buyer02)
        -- The bid terms are valid.
        && validateBidTerms auTerms auctionId bidTerms
  | otherwise =
      False `err` $(eCode Buyer'Error'EmptyStandingBid)

-- -------------------------------------------------------------------------
-- Seller payout
-- -------------------------------------------------------------------------

sellerPayout :: AuctionTerms -> StandingBidState -> Integer
sellerPayout auTerms StandingBidState {..}
  | Just BidTerms {..} <- standingBidState =
      bt'BidPrice - totalAuctionFees auTerms
  | otherwise = 0

-- -------------------------------------------------------------------------
-- Plutus instances
-- -------------------------------------------------------------------------
PlutusTx.unstableMakeIsData ''AuctionEscrowState
PlutusTx.unstableMakeIsData ''StandingBidState

instance Eq AuctionEscrowState where
  AuctionAnnounced == AuctionAnnounced = True
  AuctionAnnounced == BiddingStarted = False
  AuctionAnnounced == AuctionConcluded = False
  --
  BiddingStarted == AuctionAnnounced = False
  BiddingStarted == BiddingStarted = True
  BiddingStarted == AuctionConcluded = False
  --
  AuctionConcluded == AuctionAnnounced = False
  AuctionConcluded == BiddingStarted = False
  AuctionConcluded == AuctionConcluded = True

instance Eq StandingBidState where
  (StandingBidState x1)
    == (StandingBidState y1) =
      x1 == y1
