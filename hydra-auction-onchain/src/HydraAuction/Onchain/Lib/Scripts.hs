module HydraAuction.Onchain.Lib.Scripts (
  ValidatorType,
  MintingPolicyType,
  wrapValidator,
  wrapMintingPolicy,
  scriptValidatorHash,
  scriptValidatorHash',
) where

import Prelude

import Cardano.Api (
  PlutusScriptVersion,
  SerialiseAsRawBytes (serialiseToRawBytes),
  hashScript,
  pattern PlutusScript,
 )
import Cardano.Api.Shelley (
  PlutusScript (PlutusScriptSerialised),
  PlutusScriptVersion (PlutusScriptV2),
 )
import PlutusLedgerApi.Common (SerialisedScript)
import PlutusLedgerApi.V2 (ScriptHash (..))
import PlutusTx (BuiltinData, UnsafeFromData (..))
import PlutusTx.Prelude (check, toBuiltin)

-- * Vendored from hydra-plutus-extras (who vendored it from plutus-ledger)

-- | Signature of an untyped validator script.
type ValidatorType = BuiltinData -> BuiltinData -> BuiltinData -> ()

-- | Wrap a typed validator to get the basic `ValidatorType` signature which can
-- be passed to `PlutusTx.compile`.
-- REVIEW: There might be better ways to name this than "wrap"
wrapValidator ::
  (UnsafeFromData datum, UnsafeFromData redeemer, UnsafeFromData context) =>
  (datum -> redeemer -> context -> Bool) ->
  ValidatorType
wrapValidator f d r c =
  check $ f datum redeemer context
  where
    datum = unsafeFromBuiltinData d
    redeemer = unsafeFromBuiltinData r
    context = unsafeFromBuiltinData c
{-# INLINEABLE wrapValidator #-}

-- | Signature of an untyped minting policy script.
type MintingPolicyType = BuiltinData -> BuiltinData -> ()

-- | Wrap a typed minting policy to get the basic `MintingPolicyType` signature
-- which can be passed to `PlutusTx.compile`.
wrapMintingPolicy ::
  (UnsafeFromData redeemer, UnsafeFromData context) =>
  (redeemer -> context -> Bool) ->
  MintingPolicyType
wrapMintingPolicy f r c =
  check $ f redeemer context
  where
    redeemer = unsafeFromBuiltinData r
    context = unsafeFromBuiltinData c
{-# INLINEABLE wrapMintingPolicy #-}

-- * Similar utilities as plutus-ledger

-- | Use PlutusScriptV2 for all scripts.
scriptValidatorHash' ::
  SerialisedScript ->
  ScriptHash
scriptValidatorHash' = scriptValidatorHash PlutusScriptV2

-- | Compute the on-chain 'ScriptHash' for a given serialised plutus script. Use
-- this to refer to another validator script.
scriptValidatorHash ::
  PlutusScriptVersion lang ->
  SerialisedScript ->
  ScriptHash
scriptValidatorHash version =
  ScriptHash
    . toBuiltin
    . serialiseToRawBytes
    . hashScript
    . PlutusScript version
    . PlutusScriptSerialised
