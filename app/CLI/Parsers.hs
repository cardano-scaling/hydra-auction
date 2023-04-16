module CLI.Parsers (
  getCliInput,
  parseCliAction,
  CliInput (..),
  PromptOptions (..),
) where

-- Prelude imports
import Prelude

-- Haskell imports
import Data.Maybe (fromJust)
import Options.Applicative (
  Parser,
  ParserResult (..),
  command,
  customExecParser,
  execParserPure,
  fullDesc,
  help,
  helper,
  hsubparser,
  info,
  long,
  many,
  metavar,
  prefs,
  progDesc,
  renderFailure,
  short,
  showHelpOnEmpty,
  showHelpOnError,
  strOption,
  switch,
  (<**>),
 )

-- Cardano node imports
import Cardano.Api (NetworkId, NetworkMagic (..), fromNetworkMagic)

-- Hydra auction imports
import HydraAuction.OnChain (AuctionScript (..))
import HydraAuction.Types (Natural, intToNatural)
import HydraAuctionUtils.Fixture (Actor (..))

-- Hydra auction CLI imports
import CLI.Actions (CliAction (..), seedAmount)
import CLI.Config (AuctionName (..))
import Cardano.Prelude (asum)

data CliInput
  = Watch !AuctionName
  | InteractivePrompt !PromptOptions

data PromptOptions = MkPromptOptions
  { cliActor :: !Actor
  , cliVerbosity :: !Bool
  , cliNodeSocket :: !String
  , cliNetworkId :: !NetworkId
  }

getCliInput :: IO CliInput
getCliInput = customExecParser preferences options
  where
    options =
      info
        (cliInputParser <**> helper)
        fullDesc
    preferences = prefs (showHelpOnEmpty <> showHelpOnError)

cliInputParser :: Parser CliInput
cliInputParser =
  asum
    [ Watch <$> watchAuction
    , InteractivePrompt
        <$> (MkPromptOptions <$> actor <*> verboseParser <*> socketDir <*> (fromNetworkMagic <$> networkMagic))
    ]

parseCliAction :: [String] -> Either String CliAction
parseCliAction s = case execParserPure preferences options s of
  Success a -> Right a
  Failure failure -> Left $ fst $ renderFailure failure ""
  CompletionInvoked _ -> Left "completion was invoked but is not supported"
  where
    options =
      info
        (cliActionParser <**> helper)
        fullDesc
    preferences = prefs (showHelpOnEmpty <> showHelpOnError)

cliActionParser :: Parser CliAction
cliActionParser =
  hsubparser
    ( command "show-script-utxos" (info (ShowScriptUtxos <$> auctionName <*> script) (progDesc "Show utxos at a given script. Requires the seller and auction lot for the given script"))
        <> command "show-utxos" (info (pure ShowUtxos) (progDesc "Shows utxos for a given actor"))
        <> command
          "show-current-stage"
          ( info
              (ShowCurrentStage <$> auctionName)
              (progDesc "Show current auction stage - which depends on time since auction announcement")
          )
        <> command "show-all-utxos" (info (pure ShowAllUtxos) (progDesc "Shows utxos for all actors"))
        <> command "show-current-winner-bidder" (info (ShowCurrentWinningBidder <$> auctionName) (progDesc "Show current winning bidder for auction"))
        <> command "seed" (info (pure Seed) (progDesc $ "Provides " <> show seedAmount <> " Lovelace for the given actor"))
        <> command "prepare-for-demo" (info (Prepare <$> actor) (progDesc $ "Provides " <> show seedAmount <> " Lovelace for every actor and 1 Test NFT for given actor"))
        <> command "mint-test-nft" (info (pure MintTestNFT) (progDesc "Mints an NFT that can be used as auction lot"))
        <> command "announce-auction" (info (AuctionAnounce <$> auctionName) (progDesc "Create an auction"))
        <> command "start-bidding" (info (StartBidding <$> auctionName <*> many actor) (progDesc "Open an auction for bidding"))
        <> command "move-to-l2" (info (MoveToL2 <$> auctionName) (progDesc "Move Standing bid to L2"))
        <> command "new-bid" (info (NewBid <$> auctionName <*> bidAmount) (progDesc "Actor places new bid after bidding is started"))
        <> command
          "new-bid-on-l2"
          ( info (NewBidOnL2 <$> auctionName <*> bidAmount) (progDesc "Actor places new bid on L2 after Standing Bid was moved on L2")
          )
        <> command "bidder-buys" (info (BidderBuys <$> auctionName) (progDesc "Pay and recieve a lot after auction end"))
        <> command "seller-reclaims" (info (SellerReclaims <$> auctionName) (progDesc "Seller reclaims lot after voucher end time"))
        <> command "cleanup" (info (Cleanup <$> auctionName) (progDesc "Remove standing bid UTxO after cleanup time"))
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
          <> help "Actor running the cli tool"
      )

script :: Parser AuctionScript
script =
  parseScript
    <$> strOption
      ( short 's'
          <> metavar "SCRIPT"
          <> help "Script to check. One of: escrow, standing-bid, fee-escrow"
      )

bidAmount :: Parser Natural
bidAmount =
  parseAda
    <$> strOption
      ( short 'b'
          <> metavar "BID_AMOUNT"
          <> help "Bid amount"
      )

watchAuction :: Parser AuctionName
watchAuction =
  AuctionName
    <$> strOption
      ( short 'w'
          <> long "watch-auction"
          <> metavar "AUCTION"
          <> help "Watch the status of the given auction"
      )

socketDir :: Parser String
socketDir =
  strOption
    ( long "cardano-node-socket"
        <> metavar "CARDANO_NODE_SOCKET"
        <> help "Absolute path to the cardano node socket"
    )

networkMagic :: Parser NetworkMagic
networkMagic =
  parseNetworkMagic
    <$> strOption
      ( long "network-magic"
          <> metavar "NETWORK_MAGIC"
          <> help "Network magic for cardano"
      )

parseActor :: String -> Actor
parseActor "alice" = Alice
parseActor "bob" = Bob
parseActor "carol" = Carol
parseActor "dave" = Dave
parseActor "eve" = Eve
parseActor "frank" = Frank
parseActor "grace" = Grace
parseActor "hans" = Hans
parseActor _ = error "Actor parsing error"

parseScript :: String -> AuctionScript
parseScript "escrow" = Escrow
parseScript "standing-bid" = StandingBid
parseScript "fee-escrow" = FeeEscrow
parseScript _ = error "Escrow parsing error"

parseAda :: String -> Natural
parseAda = fromJust . intToNatural . (* 1_000_000) . read

parseNetworkMagic :: String -> NetworkMagic
parseNetworkMagic s = NetworkMagic $ read s

verboseParser :: Parser Bool
verboseParser = switch (long "verbose" <> short 'v')
