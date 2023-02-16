module HydraAuction.Tx.TestNFT (mintOneTestNFT) where

-- Prelude imports
import Hydra.Prelude

-- Plutus imports
import Plutus.V1.Ledger.Value (assetClassValue)
import Plutus.V2.Ledger.Api (getMintingPolicy)

-- Hydra imports
import Hydra.Cardano.Api hiding (txOutValue)

-- Hydra auction imports
import HydraAuction.OnChain.TestNFT
import HydraAuction.Runner
import HydraAuction.Tx.Common

mintOneTestNFT :: Runner Tx
mintOneTestNFT = do
  (actorAddress, _, actorSk) <- addressAndKeys

  actorMoneyUtxo <- filterAdaOnlyUtxo <$> actorTipUtxo

  let valueOut =
        fromPlutusValue (assetClassValue testNftAssetClass 1)
          <> lovelaceToValue minLovelace

      txOut =
        TxOut
          (ShelleyAddressInEra actorAddress)
          valueOut
          TxOutDatumNone
          ReferenceScriptNone

      toMint =
        mintedTokens
          (fromPlutusScript $ getMintingPolicy testNftPolicy)
          ()
          [(tokenToAsset testNftTokenName, 1)]

  autoSubmitAndAwaitTx $
    AutoCreateParams
      { authoredUtxos = [(actorSk, actorMoneyUtxo)]
      , referenceUtxo = mempty
      , witnessedUtxos = []
      , collateral = Nothing
      , outs = [txOut]
      , toMint = toMint
      , changeAddress = actorAddress
      , validityBound = (Nothing, Nothing)
      }
