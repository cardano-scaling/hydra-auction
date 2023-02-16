module HydraAuction.Tx.Escrow (
  toForgeStateToken,
  announceAuction,
  startBidding,
  bidderBuys,
  sellerReclaims,
) where

-- Prelude imports
import Hydra.Prelude
import PlutusTx.Prelude (emptyByteString)

-- Plutus imports
import Plutus.V1.Ledger.Address (pubKeyHashAddress)
import Plutus.V1.Ledger.Value (
  CurrencySymbol (..),
  assetClassValue,
  unAssetClass,
 )
import Plutus.V2.Ledger.Api (
  fromData,
  getMintingPolicy,
 )

-- Hydra imports
import Cardano.Api.UTxO qualified as UTxO
import Hydra.Cardano.Api hiding (txOutValue)
import Hydra.Cluster.Fixture (Actor (..))

-- Hydra auction imports
import HydraAuction.Addresses
import HydraAuction.OnChain hiding (escrowAddress, standingBidAddress)
import HydraAuction.OnChain.StateToken
import HydraAuction.Plutus.Extras
import HydraAuction.Runner
import HydraAuction.Tx.Common
import HydraAuction.Types

toForgeStateToken :: AuctionTerms -> VoucherForgingRedeemer -> TxMintValue BuildTx
toForgeStateToken terms redeemer =
  mintedTokens
    (fromPlutusScript $ getMintingPolicy $ policy terms)
    redeemer
    [(tokenToAsset $ stateTokenKindToTokenName Voucher, num)]
  where
    num = case redeemer of
      MintVoucher -> 1
      BurnVoucher -> -1

announceAuction :: Actor -> AuctionTerms -> Runner ()
announceAuction sellerActor terms = do
  logMsg "Doing announce auction"

  escrowAddress <- scriptAddress Escrow terms

  let mp = policy terms
      voucerCS = VoucherCS $ scriptCurrencySymbol mp
      escrowAnnouncedUtxo = AuctionEscrowDatum Announced voucerCS
      announcedEscrowTxOut =
        TxOut
          (ShelleyAddressInEra escrowAddress)
          valueWithLotAndStateToken
          (mkInlineDatum escrowAnnouncedUtxo)
          ReferenceScriptNone
      valueWithLotAndStateToken =
        fromPlutusValue (assetClassValue (auctionLot terms) 1)
          <> fromPlutusValue (assetClassValue (voucherAssetClass terms) 1)
          <> lovelaceToValue minLovelace

  (sellerAddress, _, sellerSk) <-
    addressAndKeysFor sellerActor

  utxoWithLotNFT <-
    queryUTxOByTxInInRunner [fromPlutusTxOutRef $ utxoNonce terms]

  sellerMoneyUtxo <- filterAdaOnlyUtxo <$> actorTipUtxo sellerActor

  case length utxoWithLotNFT of
    0 -> fail "Utxo with Lot was consumed or not created"
    1 -> pure ()
    _ -> fail "Impossible happened: multiple utxoRef Utxos"

  void $
    autoSubmitAndAwaitTx $
      AutoCreateParams
        { authoredUtxos = [(sellerSk, utxoWithLotNFT <> sellerMoneyUtxo)]
        , referenceUtxo = mempty
        , witnessedUtxos = []
        , collateral = Nothing
        , outs = [announcedEscrowTxOut]
        , toMint = toForgeStateToken terms MintVoucher
        , changeAddress = sellerAddress
        , validityBound = (Nothing, Just $ biddingStart terms)
        }

startBidding :: Actor -> AuctionTerms -> Runner ()
startBidding sellerActor terms = do
  logMsg "Doing start bidding"

  let escrowScript = scriptPlutusScript Escrow terms

  standingAddress <- scriptAddress StandingBid terms
  escrowAddress <- scriptAddress Escrow terms

  let mp = policy terms
      voucherCS = VoucherCS $ scriptCurrencySymbol mp
      biddingStartedDatum =
        AuctionEscrowDatum
          (BiddingStarted (ApprovedBiddersHash emptyByteString))
          voucherCS
      txOutEscrow =
        TxOut
          (ShelleyAddressInEra escrowAddress)
          valueOutEscrow
          (mkInlineDatum biddingStartedDatum)
          ReferenceScriptNone
      valueOutEscrow =
        fromPlutusValue (assetClassValue (auctionLot terms) 1)
          <> lovelaceToValue minLovelace
      txOutStandingBid =
        TxOut
          (ShelleyAddressInEra standingAddress)
          valueOutStanding
          (mkInlineDatum standingBidDatum)
          ReferenceScriptNone
      standingBidDatum = StandingBidDatum NoBid voucherCS
      valueOutStanding =
        fromPlutusValue (assetClassValue (voucherAssetClass terms) 1)
          <> lovelaceToValue minLovelace
      escrowWitness = mkInlinedDatumScriptWitness escrowScript StartBidding

  (sellerAddress, _, sellerSk) <-
    addressAndKeysFor sellerActor

  sellerMoneyUtxo <- filterAdaOnlyUtxo <$> actorTipUtxo sellerActor

  let escrowAnnounceSymbols =
        [ fst $
            unAssetClass $
              auctionLot terms
        , scriptCurrencySymbol mp
        , CurrencySymbol emptyByteString
        ]

  escrowAnnounceUtxo <-
    filterUtxoByCurrencySymbols
      escrowAnnounceSymbols
      <$> scriptUtxos Escrow terms

  case length escrowAnnounceUtxo of
    0 -> fail "Utxo with announced escrow was consumed or not created"
    1 -> pure ()
    _ -> fail "Cannot choose between multiple utxos with announced escrow"

  void $
    autoSubmitAndAwaitTx $
      AutoCreateParams
        { authoredUtxos = [(sellerSk, sellerMoneyUtxo)]
        , referenceUtxo = mempty
        , witnessedUtxos = [(escrowWitness, escrowAnnounceUtxo)]
        , collateral = Nothing
        , outs = [txOutStandingBid, txOutEscrow]
        , toMint = TxMintValueNone
        , changeAddress = sellerAddress
        , validityBound = (Just $ biddingStart terms, Just $ biddingEnd terms)
        }

bidderBuys :: Actor -> AuctionTerms -> Runner ()
bidderBuys bidder terms = do
  feeEscrowAddress <- scriptAddress FeeEscrow terms
  sellerAddress <- fromPlutusAddressInRunner $ pubKeyHashAddress $ seller terms

  let txOutSellerGotBid standingBidUtxo =
        TxOut
          sellerAddress
          value
          TxOutDatumNone
          ReferenceScriptNone
        where
          value =
            lovelaceToValue $
              Lovelace $ bidAmount' - calculateTotalFee terms
          bidAmount' = case UTxO.pairs standingBidUtxo of
            [(_, out)] -> case txOutDatum out of
              TxOutDatumInline scriptData ->
                case fromData $ toPlutusData scriptData of
                  Just (StandingBidDatum {standingBidState}) ->
                    case standingBidState of
                      (Bid (BidTerms {bidAmount})) -> naturalToInt bidAmount
                      NoBid -> error "Standing bid UTxO has no bid"
                  Nothing ->
                    error "Impossible happened: Cannot decode standing bid datum"
              _ -> error "Impossible happened: No inline data for standing bid"
            _ -> error "Wrong number of standing bid UTxOs found"

      txOutBidderGotLot bidderAddress =
        TxOut
          (ShelleyAddressInEra bidderAddress)
          valueBidderLot
          TxOutDatumNone
          ReferenceScriptNone
        where
          valueBidderLot =
            fromPlutusValue (assetClassValue (auctionLot terms) 1)
              <> lovelaceToValue minLovelace

      txOutFeeEscrow =
        TxOut (ShelleyAddressInEra feeEscrowAddress) value TxOutDatumNone ReferenceScriptNone
        where
          value = lovelaceToValue $ Lovelace $ calculateTotalFee terms

      escrowWitness = mkInlinedDatumScriptWitness script BidderBuys
        where
          script = scriptPlutusScript Escrow terms

  logMsg "Doing Bidder Buy"

  (bidderAddress, _, bidderSk) <-
    addressAndKeysFor bidder

  bidderMoneyUtxo <- filterAdaOnlyUtxo <$> actorTipUtxo bidder

  let escrowBiddingStartedSymbols =
        [ CurrencySymbol emptyByteString
        , fst $ unAssetClass $ auctionLot terms
        ]

  escrowBiddingStartedUtxo <-
    filterUtxoByCurrencySymbols
      escrowBiddingStartedSymbols
      <$> scriptUtxos Escrow terms

  standingBidUtxo <- scriptUtxos StandingBid terms

  -- FIXME: cover not proper UTxOs

  void $
    autoSubmitAndAwaitTx $
      AutoCreateParams
        { authoredUtxos = [(bidderSk, bidderMoneyUtxo)]
        , referenceUtxo = standingBidUtxo
        , witnessedUtxos =
            [ (escrowWitness, escrowBiddingStartedUtxo)
            ]
        , collateral = Nothing
        , outs =
            [ txOutBidderGotLot bidderAddress
            , txOutSellerGotBid standingBidUtxo
            , txOutFeeEscrow
            ]
        , toMint = TxMintValueNone
        , changeAddress = bidderAddress
        , validityBound = (Just $ biddingEnd terms, Just $ voucherExpiry terms)
        }

sellerReclaims :: Actor -> AuctionTerms -> Runner ()
sellerReclaims seller terms = do
  feeEscrowAddress <- scriptAddress FeeEscrow terms

  let escrowScript = scriptPlutusScript Escrow terms
      txOutSellerGotLot sellerAddress =
        TxOut
          (ShelleyAddressInEra sellerAddress)
          valueSellerLot
          TxOutDatumNone
          ReferenceScriptNone
        where
          valueSellerLot =
            fromPlutusValue (assetClassValue (auctionLot terms) 1)
              <> lovelaceToValue minLovelace

      escrowWitness = mkInlinedDatumScriptWitness escrowScript SellerReclaims

      txOutFeeEscrow =
        TxOut
          (ShelleyAddressInEra feeEscrowAddress)
          value
          TxOutDatumNone
          ReferenceScriptNone
        where
          value = lovelaceToValue $ Lovelace $ calculateTotalFee terms

  logMsg "Doing Seller reclaims"

  (sellerAddress, _, sellerSk) <-
    addressAndKeysFor seller

  sellerMoneyUtxo <- filterAdaOnlyUtxo <$> actorTipUtxo seller

  let escrowBiddingStartedSymbols =
        [ CurrencySymbol emptyByteString
        , fst $ unAssetClass $ auctionLot terms
        ]

  escrowBiddingStartedUtxo <-
    filterUtxoByCurrencySymbols escrowBiddingStartedSymbols
      <$> scriptUtxos Escrow terms

  void $
    autoSubmitAndAwaitTx $
      AutoCreateParams
        { authoredUtxos = [(sellerSk, sellerMoneyUtxo)]
        , referenceUtxo = mempty
        , witnessedUtxos =
            [ (escrowWitness, escrowBiddingStartedUtxo)
            ]
        , collateral = Nothing
        , outs =
            [ txOutSellerGotLot sellerAddress
            , txOutFeeEscrow
            ]
        , toMint = TxMintValueNone
        , changeAddress = sellerAddress
        , validityBound = (Just $ voucherExpiry terms, Nothing)
        }
