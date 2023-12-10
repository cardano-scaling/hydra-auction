module HydraAuction.Onchain.Validators.BidderDeposit (
  validator,
) where

import PlutusTx.Prelude

import PlutusLedgerApi.V1.Interval (contains)
import PlutusLedgerApi.V2 (
  ScriptContext (..),
  TxInInfo (..),
  TxInfo (..),
  TxOut (..),
 )
import PlutusLedgerApi.V2.Contexts (
  findOwnInput,
 )

import HydraAuction.Error.Onchain.Validators.BidderDeposit (
  BidderDeposit'Error (..),
 )
import HydraAuction.Onchain.Lib.Error (eCode, err, errMaybe, errMaybeFlip)
import HydraAuction.Onchain.Lib.PlutusTx (
  getSpentInputRedeemer,
  lovelaceValueOf,
  onlyOneInputFromAddress,
  parseInlineDatum,
  parseRedemeer,
  partyConsentsAda,
 )
import HydraAuction.Onchain.Types.AuctionState (
  AuctionEscrowState (..),
  StandingBidState (..),
  bidderLost,
  bidderWon,
 )
import HydraAuction.Onchain.Types.AuctionTerms (
  AuctionTerms (..),
  cleanupPeriod,
  postBiddingPeriod,
 )
import HydraAuction.Onchain.Types.BidderInfo (
  BidderInfo (..),
 )
import HydraAuction.Onchain.Types.Scripts (
  AuctionEscrow'Redeemer (..),
  AuctionEscrow'ScriptHash,
  AuctionID (..),
  BidderDeposit'Redeemer (..),
  StandingBid'ScriptHash (..),
  findAuctionEscrowInputAtSh,
  findStandingBidInputAtSh,
  getBuyer,
 )

-- -------------------------------------------------------------------------
-- Validator
-- -------------------------------------------------------------------------
validator ::
  AuctionEscrow'ScriptHash ->
  StandingBid'ScriptHash ->
  AuctionID ->
  AuctionTerms ->
  BidderInfo ->
  BidderDeposit'Redeemer ->
  ScriptContext ->
  Bool
validator aesh sbsh auctionID aTerms bInfo redeemer context =
  ownInputIsOnlyInputFromOwnScript
    && noTokensAreMintedOrBurned
    && redeemerChecksPassed
  where
    TxInfo {..} = scriptContextTxInfo context
    --
    -- There should only be one bidder deposit input.
    ownInputIsOnlyInputFromOwnScript =
      onlyOneInputFromAddress ownAddress txInfoInputs
        `err` $(eCode BidderDeposit'Error'TooManyOwnScriptInputs)
    --
    -- No tokens are minted or burned.
    noTokensAreMintedOrBurned =
      (txInfoMint == mempty)
        `err` $(eCode BidderDeposit'Error'UnexpectedMintOrBurn)
    --
    -- The validator's own input should exist.
    ownInput =
      txInInfoResolved $
        findOwnInput context
          `errMaybe` $(eCode BidderDeposit'Error'MissingOwnInput)
    ownAddress = txOutAddress ownInput
    --
    -- Branching checks based on the redeemer used.
    redeemerChecksPassed =
      case redeemer of
        DepositUsedByWinner ->
          checkBW aesh auctionID bInfo context
        DepositClaimedBySeller ->
          checkBS aesh sbsh auctionID aTerms bInfo context ownInput
        DepositReclaimedByLoser ->
          checkBL sbsh auctionID aTerms bInfo context ownInput
        DepositReclaimedAuctionConcluded ->
          checkAC aesh auctionID aTerms bInfo context ownInput
        DepositCleanup ->
          checkDC aTerms bInfo context ownInput
--
{-# INLINEABLE validator #-}

-- -------------------------------------------------------------------------
-- Deposit used by winner
-- -------------------------------------------------------------------------

-- Deposit is used by the bidder who won the auction to buy the auction lot.
checkBW ::
  AuctionEscrow'ScriptHash ->
  AuctionID ->
  BidderInfo ->
  ScriptContext ->
  Bool
checkBW aesh auctionID bInfo context =
  bidderIsBuyingAuctionLot
  where
    txInfo@TxInfo {..} = scriptContextTxInfo context
    BidderInfo {..} = bInfo
    --
    -- The bidder is buying the auction lot from the auction escrow.
    bidderIsBuyingAuctionLot =
      (bi'BidderPkh == buyer)
        `err` $(eCode BidderDeposit'BW'Error'BidderIsNotBuyer)
    --
    -- The auction escrow input is being spent with
    -- a BidderBuys redeemer.
    buyer =
      getBuyer aRedeemer
        `errMaybe` $(eCode BidderDeposit'BW'Error'RedeemerNotBidderBuys)
    --
    -- The auction input's redeemer can be decoded
    -- as an auction escrow redeemer.
    aRedeemer :: AuctionEscrow'Redeemer
    aRedeemer =
      errMaybeFlip
        $(eCode BidderDeposit'BW'Error'UndecodedAuctionRedeemer)
        $ parseRedemeer =<< getSpentInputRedeemer txInfo auctionEscrowInput
    --
    -- There is an auction escrow input that contains
    -- the auction token.
    auctionEscrowInput =
      findAuctionEscrowInputAtSh auctionID aesh txInfoInputs
        `errMaybe` $(eCode BidderDeposit'BW'Error'MissingAuctionEscrowInput)
--
{-# INLINEABLE checkBW #-}

-- -------------------------------------------------------------------------
-- Deposit claimed by seller
-- -------------------------------------------------------------------------

-- The winning bidder's deposit is claimed by the seller because
-- the winner did not purchase the auction lot within the purchase period.
checkBS ::
  AuctionEscrow'ScriptHash ->
  StandingBid'ScriptHash ->
  AuctionID ->
  AuctionTerms ->
  BidderInfo ->
  ScriptContext ->
  TxOut ->
  Bool
checkBS aesh sbsh auctionID aTerms bInfo context ownInput =
  sellerIsReclaimingAuctionLot
    && bidderWonTheAuction
    && sellerConsents
  where
    txInfo@TxInfo {..} = scriptContextTxInfo context
    AuctionTerms {..} = aTerms
    lovelaceOwnInput = lovelaceValueOf $ txOutValue ownInput
    --
    -- The seller is reclaiming the auction lot from the auction escrow.
    sellerIsReclaimingAuctionLot =
      (aRedeemer == SellerReclaims)
        `err` $(eCode BidderDeposit'BS'Error'MismatchAuctionRedeemer)
    --
    -- The bidder deposit's bidder won the auction.
    bidderWonTheAuction =
      bidderWon bidState bInfo
        `err` $(eCode BidderDeposit'BS'Error'BidderNotWinner)
    --
    -- The seller consents to the transaction either
    -- explicitly by signing it or
    -- implicitly by receiving the bid deposit ADA.
    sellerConsents =
      partyConsentsAda txInfo at'SellerPkh lovelaceOwnInput
        `err` $(eCode BidderDeposit'BS'Error'NoSellerConsent)
    --
    -- The auction input's redeemer can be decoded
    -- as an auction escrow redeemer.
    aRedeemer :: AuctionEscrow'Redeemer
    aRedeemer =
      errMaybeFlip
        $(eCode BidderDeposit'BS'Error'UndecodedAuctionRedeemer)
        $ parseRedemeer =<< getSpentInputRedeemer txInfo auctionEscrowInput
    --
    -- There is an auction escrow input that contains
    -- the auction token.
    auctionEscrowInput =
      findAuctionEscrowInputAtSh auctionID aesh txInfoInputs
        `errMaybe` $(eCode BidderDeposit'BS'Error'MissingAuctionEscrowInput)
    --
    -- The standing bid input contains a datum that can be decoded
    -- as a standing bid state.
    bidState =
      parseInlineDatum standingBidInput
        `errMaybe` $(eCode BidderDeposit'BS'Error'UndecodedBidState)
    --
    -- There is a standing bid input that contains
    -- the standing bid token.
    standingBidInput =
      txInInfoResolved $
        findStandingBidInputAtSh auctionID sbsh txInfoInputs
          `errMaybe` $(eCode BidderDeposit'BS'Error'MissingStandingBidInput)
--
{-# INLINEABLE checkBS #-}

-- -------------------------------------------------------------------------
-- Deposit reclaimed by losing bidder
-- -------------------------------------------------------------------------

-- The bidder deposit is reclaimed by a bidder that did not win the auction.
checkBL ::
  StandingBid'ScriptHash ->
  AuctionID ->
  AuctionTerms ->
  BidderInfo ->
  ScriptContext ->
  TxOut ->
  Bool
checkBL sbsh auctionID aTerms bInfo context ownInput =
  bidderLostTheAuction
    && validityIntervalIsCorrect
    && bidderConsents
  where
    txInfo@TxInfo {..} = scriptContextTxInfo context
    BidderInfo {..} = bInfo
    lovelaceOwnInput = lovelaceValueOf $ txOutValue ownInput
    --
    -- The bidder deposit's bidder lost the auction.
    bidderLostTheAuction =
      bidderLost bidState bInfo
        `err` $(eCode BidderDeposit'BL'Error'BidderNotLoser)
    --
    -- This redeemer can only be used after the bidding period.
    validityIntervalIsCorrect =
      (postBiddingPeriod aTerms `contains` txInfoValidRange)
        `err` $(eCode BidderDeposit'BL'Error'ValidityIntervalIncorrect)
    --
    -- The bidder deposit's bidder consents to the transcation either
    -- explictly by signing the transaction or
    -- implicitly by receiving the bid deposit ADA.
    bidderConsents =
      partyConsentsAda txInfo bi'BidderPkh lovelaceOwnInput
        `err` $(eCode BidderDeposit'BL'Error'NoBidderConsent)
    --
    -- The standing bid input contains a datum that can be decoded
    -- as a standing bid state.
    bidState :: StandingBidState
    bidState =
      parseInlineDatum standingBidInput
        `errMaybe` $(eCode BidderDeposit'BL'Error'UndecodedBidState)
    --
    -- There is a standing bid input that contains
    -- the standing bid token.
    standingBidInput =
      txInInfoResolved $
        findStandingBidInputAtSh auctionID sbsh txInfoInputs
          `errMaybe` $(eCode BidderDeposit'BL'Error'MissingStandingBidInput)
--
{-# INLINEABLE checkBL #-}

-- -------------------------------------------------------------------------
-- Deposit reclaimed by losing bidder
-- -------------------------------------------------------------------------

-- The bidder deposit is reclaimed by a bidder after the auction conclusion.
-- If the auction has concluded then the seller and the winning bidder
-- have already had an opportunity to claim
-- whichever deposits they are entitled to.
checkAC ::
  AuctionEscrow'ScriptHash ->
  AuctionID ->
  AuctionTerms ->
  BidderInfo ->
  ScriptContext ->
  TxOut ->
  Bool
checkAC aesh auctionID aTerms bInfo context ownInput =
  auctionIsConcluded
    && validityIntervalIsCorrect
    && bidderConsents
  where
    txInfo@TxInfo {..} = scriptContextTxInfo context
    BidderInfo {..} = bInfo
    lovelaceOwnInput = lovelaceValueOf $ txOutValue ownInput
    --
    -- The auction is concluded.
    auctionIsConcluded =
      (aState == AuctionConcluded)
        `err` $(eCode BidderDeposit'AC'Error'AuctionNotConcluded)
    --
    -- This redeemer can only be used after the bidding period.
    validityIntervalIsCorrect =
      (postBiddingPeriod aTerms `contains` txInfoValidRange)
        `err` $(eCode BidderDeposit'AC'Error'ValidityIntervalIncorrect)
    --
    -- The bidder deposit's bidder consents to the transcation either
    -- explictly by signing the transaction or
    -- implicitly by receiving the bid deposit ADA.
    bidderConsents =
      partyConsentsAda txInfo bi'BidderPkh lovelaceOwnInput
        `err` $(eCode BidderDeposit'AC'Error'NoBidderConsent)
    --
    -- The auction escrow output contains a datum that can be
    -- decoded as an auction escrow state.
    aState :: AuctionEscrowState
    aState =
      parseInlineDatum auctionEscrowReferenceInput
        `errMaybe` $(eCode BidderDeposit'AC'Error'UndecodedAuctionState)
    --
    -- There is an auction escrow reference input that contains
    -- the auction token.
    auctionEscrowReferenceInput =
      txInInfoResolved $
        findAuctionEscrowInputAtSh auctionID aesh txInfoReferenceInputs
          `errMaybe` $(eCode BidderDeposit'AC'Error'MissingAuctionRefInput)
--
{-# INLINEABLE checkAC #-}

-- -------------------------------------------------------------------------
-- Deposit cleanup
-- -------------------------------------------------------------------------

-- If, for whatever reason, there are bidder deposits left during the
-- cleanup period, then whoever placed a deposit can freely reclaim it.
checkDC ::
  AuctionTerms ->
  BidderInfo ->
  ScriptContext ->
  TxOut ->
  Bool
checkDC aTerms bInfo context ownInput =
  validityIntervalIsCorrect
    && bidderConsents
  where
    txInfo@TxInfo {..} = scriptContextTxInfo context
    BidderInfo {..} = bInfo
    lovelaceOwnInput = lovelaceValueOf $ txOutValue ownInput
    --
    -- This redeemer can only be used during the cleanup period.
    validityIntervalIsCorrect =
      (cleanupPeriod aTerms `contains` txInfoValidRange)
        `err` $(eCode BidderDeposit'DC'Error'ValidityIntervalIncorrect)
    --
    -- The bidder deposit's bidder consents to the transcation either
    -- explictly by signing the transaction or
    -- implicitly by receiving the bid deposit ADA.
    bidderConsents =
      partyConsentsAda txInfo bi'BidderPkh lovelaceOwnInput
        `err` $(eCode BidderDeposit'DC'Error'NoBidderConsent)
--
{-# INLINEABLE checkDC #-}
