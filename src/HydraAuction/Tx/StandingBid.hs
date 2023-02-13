{-# LANGUAGE RecordWildCards #-}

module HydraAuction.Tx.StandingBid (newBid, cleanupTx) where

import Hydra.Prelude hiding (Natural)

import CardanoNode (RunningNode (..))
import Hydra.Cardano.Api hiding (txOutValue)
import Hydra.Cluster.Fixture (Actor)
import HydraAuction.Addresses
import HydraAuction.OnChain
import HydraAuction.PlutusExtras
import HydraAuction.Runner
import HydraAuction.Tx.Common
import HydraAuction.Tx.Escrow (toForgeStateToken)
import HydraAuction.Types
import Plutus.V1.Ledger.Value (assetClassValue)
import Plutus.V2.Ledger.Api (getValidator)

newBid :: Actor -> AuctionTerms -> Natural -> Runner ()
newBid bidder terms bidAmount = do
  putStrLn "Doing new bid"
  MkExecutionContext {..} <- ask
  let networkId' = networkId node

      txOutStandingBid bidderVk =
        TxOut
          standingBidAddress'
          valueStandingBid
          (mkInlineDatum datum)
          ReferenceScriptNone
        where
          mp = policy terms
          voucherCS = VoucherCS $ scriptCurrencySymbol mp
          datum =
            StandingBidDatum
              ( Bid $
                  BidTerms
                    (toPlutusKeyHash $ verificationKeyHash bidderVk)
                    bidAmount
              )
              voucherCS
          standingBidAddress' =
            mkScriptAddress @PlutusScriptV2
              networkId'
              $ fromPlutusScript @PlutusScriptV2 $
                getValidator $ standingBidValidator terms
          valueStandingBid =
            fromPlutusValue (assetClassValue (voucherAssetClass terms) 1)
              <> lovelaceToValue minLovelace
      standingBidWitness = mkInlinedDatumScriptWitness script NewBid
        where
          script =
            fromPlutusScript @PlutusScriptV2 $
              getValidator $ standingBidValidator terms

  logMsg "Doing New bid"

  (bidderAddress, bidderVk, bidderSk) <-
    addressAndKeysFor bidder

  bidderMoneyUtxo <- filterAdaOnlyUtxo <$> actorTipUtxo bidder
  standingBidUtxo <- scriptUtxos StandingBid terms

  -- FIXME: cover not proper UTxOs
  void $
    autoSubmitAndAwaitTx $
      AutoCreateParams
        { authoredUtxos =
            [ (bidderSk, bidderMoneyUtxo)
            ]
        , referenceUtxo = mempty
        , witnessedUtxos =
            [ (standingBidWitness, standingBidUtxo)
            ]
        , collateral = Nothing
        , outs = [txOutStandingBid bidderVk]
        , toMint = TxMintValueNone
        , changeAddress = bidderAddress
        , validityBound = (Just $ biddingStart terms, Just $ biddingEnd terms)
        }

cleanupTx :: Actor -> AuctionTerms -> Runner ()
cleanupTx actor terms = do
  logMsg "Doing standing bid cleanup"

  (actorAddress, _, actorSk) <- addressAndKeysFor actor

  standingBidUtxo <- scriptUtxos StandingBid terms
  actorMoneyUtxo <- filterAdaOnlyUtxo <$> actorTipUtxo actor

  -- FIXME: cover not proper UTxOs
  void $
    autoSubmitAndAwaitTx $
      AutoCreateParams
        { authoredUtxos = [(actorSk, actorMoneyUtxo)]
        , referenceUtxo = mempty
        , witnessedUtxos =
            [ (standingBidWitness, standingBidUtxo)
            ]
        , collateral = Nothing
        , outs = []
        , toMint = toForgeStateToken terms BurnVoucher
        , changeAddress = actorAddress
        , validityBound = (Just $ cleanup terms, Nothing)
        }
  where
    standingBidWitness = mkInlinedDatumScriptWitness script Cleanup
      where
        script =
          fromPlutusScript @PlutusScriptV2 $
            getValidator $ standingBidValidator terms
