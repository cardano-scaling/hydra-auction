-- Things that should be merged in Hydra repo later
-- Copy-pasting `commitTx` and modifying it
-- to support script witnessed commited Utxos
module HydraAuction.HydraHacks (submitAndAwaitCommitTx) where

-- Prelude imports
import Prelude

-- Haskell imports
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Reader (MonadReader (ask))
import Data.Function ((&))

-- Caradno imports
import Cardano.Api.UTxO qualified as UTxO
import CardanoClient (buildScriptAddress)
import CardanoNode (RunningNode (..))

-- Hydra imports
import Hydra.Cardano.Api (
  AssetId (AssetId),
  AssetName (AssetName),
  BuildTx,
  BuildTxWith (BuildTxWith),
  CtxUTxO,
  Hash,
  IsScriptWitnessInCtx (scriptWitnessCtx),
  Key (verificationKeyHash),
  NetworkId,
  PaymentKey,
  PlutusScriptV2,
  SerialiseAsRawBytes (serialiseToRawBytes),
  TxBodyContent,
  TxIn,
  TxOut,
  UTxO,
  Value,
  WitCtxTxIn,
  Witness,
  fromPlutusScript,
  mkScriptAddress,
  mkScriptDatum,
  mkScriptReference,
  mkTxOutDatum,
  toPlutusTxOutRef,
  toScriptData,
  txInsCollateral,
  txOutValue,
  txProtocolParams,
  valueToList,
  pattern PlutusScript,
  pattern ReferenceScriptNone,
  pattern ScriptWitness,
  pattern TxInsCollateral,
  pattern TxOut,
 )
import Hydra.Chain (HeadId (..))
import Hydra.Chain.Direct.ScriptRegistry (ScriptRegistry (..))
import Hydra.Chain.Direct.Tx (
  headIdToCurrencySymbol,
  mkCommitDatum,
 )
import Hydra.Contract.Commit qualified as Commit
import Hydra.Contract.Initial qualified as Initial
import Hydra.Ledger.Cardano (addReferenceInputs)
import Hydra.Ledger.Cardano.Builder (
  addExtraRequiredSigners,
  addInputs,
  addOutputs,
  addVkInputs,
  emptyTxBody,
 )
import Hydra.Party (Party)

-- HydraAuction imports
import HydraAuction.Runner (ExecutionContext (..), Runner)
import HydraAuction.Tx.Common (actorTipUtxo, addressAndKeys)
import HydraAuctionUtils.Fixture (partyFor)
import HydraAuctionUtils.Monads (
  BlockchainParams (..),
  MonadBlockchainParams (..),
  MonadQueryUtxo (queryUtxo),
  UtxoQuery (..),
  submitAndAwaitTx,
 )
import HydraAuctionUtils.Tx.AutoCreateTx (callBodyAutoBalance, makeSignedTransactionWithKeys)
import HydraAuctionUtils.Tx.Utxo (filterAdaOnlyUtxo)

-- | Craft a commit transaction which includes the "committed" utxo as a datum.
commitTxBody ::
  NetworkId ->
  -- | Published Hydra scripts to reference.
  ScriptRegistry ->
  HeadId ->
  Party ->
  -- | The initial output (sent to each party) which should contain the PT
  -- and is locked by initial script
  (TxIn, TxOut CtxUTxO) ->
  -- | Script utxo to be commited
  (TxIn, TxOut CtxUTxO, BuildTxWith BuildTx (Witness WitCtxTxIn)) ->
  -- | Input to cover fees from Hydra node key owner
  TxIn ->
  -- Required signer - Hydra node key owner
  Hash PaymentKey ->
  TxBodyContent BuildTx
commitTxBody
  networkId
  scriptRegistry
  headId
  party
  (initialInput, out)
  (scriptInput, scriptOutput, scriptWitness)
  moneyInput
  vkh =
    ( emptyTxBody
        & addInputs
          [(initialInput, initialWitness), (scriptInput, scriptWitness)]
        & addReferenceInputs [initialScriptRef]
        & addVkInputs [moneyInput]
        & addExtraRequiredSigners [vkh]
        & addOutputs [commitOutput]
    )
      { txInsCollateral = TxInsCollateral [moneyInput]
      }
    where
      initialWitness =
        BuildTxWith $
          ScriptWitness scriptWitnessCtx $
            mkScriptReference initialScriptRef initialScript initialDatum initialRedeemer
      initialScript =
        fromPlutusScript @PlutusScriptV2 Initial.validatorScript
      initialScriptRef =
        fst (initialReference scriptRegistry)
      initialDatum =
        mkScriptDatum $ Initial.datum (headIdToCurrencySymbol headId)
      initialRedeemer =
        toScriptData . Initial.redeemer $
          Initial.ViaCommit (Just $ toPlutusTxOutRef scriptInput)
      commitOutput =
        TxOut commitAddress commitValue commitDatum ReferenceScriptNone
      commitScript =
        fromPlutusScript Commit.validatorScript
      commitAddress =
        mkScriptAddress @PlutusScriptV2 networkId commitScript
      commitValue =
        txOutValue out
          <> txOutValue scriptOutput
      commitDatum =
        mkTxOutDatum $
          mkCommitDatum party (Just (scriptInput, scriptOutput)) (headIdToCurrencySymbol headId)

-- | Find initial Utxo with Participation Token matchin our current actor
findInitialUtxo :: Runner (TxIn, TxOut CtxUTxO)
findInitialUtxo = do
  (_, commitingNodeVk, _) <- addressAndKeys
  let vkh = verificationKeyHash commitingNodeVk

  headAddress <- formInitialAddress
  commiterUtxo <- queryUtxo (ByAddress headAddress)
  let initialUtxo =
        filter
          (hasMatchingPT vkh . txOutValue . snd)
          (UTxO.pairs commiterUtxo)

  -- Node should be only in one
  [(initialTxIn, initialTxOut)] <- return initialUtxo
  return (initialTxIn, initialTxOut)
  where
    formInitialAddress = do
      MkExecutionContext {node} <- ask
      let RunningNode {networkId} = node
      return $
        buildScriptAddress
          (PlutusScript $ fromPlutusScript Initial.validatorScript)
          networkId
    hasMatchingPT :: Hash PaymentKey -> Value -> Bool
    hasMatchingPT vkh val =
      any hasAssetNameMatchingPT $ valueToList val
      where
        hasAssetNameMatchingPT (x, _) = case x of
          (AssetId _ (AssetName bs)) -> bs == serialiseToRawBytes vkh
          _ -> False

findInitialScriptRefUtxo :: MonadQueryUtxo m => ScriptRegistry -> m UTxO
findInitialScriptRefUtxo scriptRegistry = do
  queryUtxo (ByTxIns [initialScriptRef])
  where
    initialScriptRef = fst (initialReference scriptRegistry)

submitAndAwaitCommitTx ::
  ScriptRegistry ->
  HeadId ->
  ( TxIn
  , TxOut CtxUTxO
  , BuildTxWith BuildTx (Witness WitCtxTxIn)
  ) ->
  Runner ()

-- | Runner Actor should represent one which runs Hydra Node
submitAndAwaitCommitTx
  scriptRegistry
  headId
  (scriptTxIn, scriptTxOut, scriptTxWitness) =
    do
      -- FIXME: not properly tested on non-zero fees case, though should work
      MkExecutionContext {actor, node} <- ask
      let RunningNode {networkId} = node

      -- FIXME: DRY
      (commitingNodeAddress, commitingNodeVk, commitingNodeSk) <-
        addressAndKeys
      let commiterVkh = verificationKeyHash commitingNodeVk

      party <- liftIO $ partyFor actor

      initialScriptRefUtxo <- findInitialScriptRefUtxo scriptRegistry
      (initialTxIn, initialTxOut) <- findInitialUtxo

      commiterAdaUtxo <- filterAdaOnlyUtxo <$> actorTipUtxo
      (commiterAdaTxIn, commiterAdaTxOut) : _ <-
        return $ UTxO.pairs commiterAdaUtxo

      let preTxBody =
            commitTxBody
              networkId
              scriptRegistry
              headId
              party
              (initialTxIn, initialTxOut)
              (scriptTxIn, scriptTxOut, scriptTxWitness)
              commiterAdaTxIn
              commiterVkh

      -- Patching pparams to match one on Hydra ledger
      MkBlockchainParams {protocolParameters} <- queryBlockchainParams
      let patchedPreTxBody =
            preTxBody
              { txProtocolParams = BuildTxWith $ Just protocolParameters
              }

      let utxos =
            UTxO.fromPairs
              [ (initialTxIn, initialTxOut)
              , (scriptTxIn, scriptTxOut)
              , (commiterAdaTxIn, commiterAdaTxOut)
              ]
              <> initialScriptRefUtxo

      eTxBody <- callBodyAutoBalance utxos patchedPreTxBody commitingNodeAddress
      tx <- case eTxBody of
        Left balancingError -> fail $ show balancingError
        Right txBody ->
          return $
            makeSignedTransactionWithKeys [commitingNodeSk] txBody

      submitAndAwaitTx tx
