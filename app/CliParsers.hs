module CliParsers (
  getCliAction,
) where

import Prelude

import Hydra.Cluster.Fixture (Actor (..))
import Options.Applicative

import HydraAuction.OnChain

import Cardano.Api (TxIn)

import CliActions (CliAction (..), seedAmount)
import CliConfig (AuctionName (..))
import ParseTxIn (parseTxIn)

getCliAction :: IO CliAction
getCliAction =
  execParser $
    info
      cliAction
      ( fullDesc
          <> progDesc "FIXME: add help message"
          <> header "FIXME: add help message"
      )

cliAction :: Parser CliAction
cliAction =
  subparser
    ( command "run-cardano-node" (info (pure RunCardanoNode) (progDesc "Starts a cardano node instance in the background"))
        <> command "show-script-utxos" (info (ShowScriptUtxos <$> auctionName <*> script) (progDesc "Show utxos at a given script. Requires the seller and auction lot for the given script"))
        <> command "show-utxos" (info (ShowUtxos <$> actor) (progDesc "Shows utxos for a given actor"))
        <> command "seed" (info (Seed <$> actor) (progDesc $ "Provides " <> show seedAmount <> " Lovelace for the given actor"))
        <> command "mint-test-nft" (info (MintTestNFT <$> actor) (progDesc "Mints an NFT that can be used as auction lot"))
        <> command "announce-auction" (info (AuctionAnounce <$> auctionName <*> actor <*> utxo) (progDesc "Create an auction. Requires TxIn which identifies the auction lot"))
        <> command "start-bidding" (info (StartBidding <$> auctionName) (progDesc "Open an auction for bidding"))
        <> command "bidder-buys" (info (BidderBuys <$> auctionName <*> actor) (progDesc "Pay and recieve a lot after auction end"))
    )

auctionName :: Parser AuctionName
auctionName =
  AuctionName
    <$> strOption
      ( short 'n'
          <> metavar "AUCTION_NAME"
          <> help "Name for saving config and dynamic params of auction"
      )

actor :: Parser Actor
actor =
  parseActor
    <$> strOption
      ( short 'a'
          <> metavar "ACTOR"
          <> help "Actor to use for tx and AuctionTerms construction"
      )

script :: Parser AuctionScript
script =
  parseScript
    <$> strOption
      ( short 's'
          <> metavar "SCRIPT"
          <> help "Script to check. One of: escrow, standing-bid, fee-escrow"
      )

utxo :: Parser TxIn
utxo =
  option
    parseTxIn
    ( short 'u'
        <> metavar "UTXO"
        <> help "Utxo with test NFT for AuctionTerms"
    )

parseActor :: String -> Actor
parseActor "alice" = Alice
parseActor "bob" = Bob
parseActor "carol" = Carol
parseActor "faucet" = error "Unsupported actor"
parseActor _ = error "Actor parsing error"

parseScript :: String -> AuctionScript
parseScript "escrow" = Escrow
parseScript "standing-bid" = StandingBid
parseScript "fee-escrow" = FeeEscrow
parseScript _ = error "Escrow parsing error"