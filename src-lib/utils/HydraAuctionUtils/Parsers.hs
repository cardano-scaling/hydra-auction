module HydraAuctionUtils.Parsers (
  parseActor,
  parseAda,
  parseAdaAsNatural,
  parseNetworkMagic,
  parseHost,
  cardanoRunningNodeParser,
  execParserForCliArgs,
  websocketsHost,
  platform,
) where

-- Prelude imports
import HydraAuctionUtils.Prelude

-- Haskell imports

import Control.Applicative ((<**>))
import Data.Char (toLower)
import Data.Map qualified as Map
import Data.Text qualified as Text
import Network.HostAndPort (maybeHostAndPort)
import Options.Applicative (Parser, customExecParser, helper)
import Options.Applicative.Builder (
  ReadM,
  eitherReader,
  fullDesc,
  help,
  info,
  long,
  metavar,
  option,
  prefs,
  short,
  showHelpOnEmpty,
  showHelpOnError,
  strOption,
 )
import Protolude.Exceptions (note)
import Text.Read (readMaybe)

-- Cardano node imports

import Cardano.Api (NetworkId, NetworkMagic (..), fromNetworkMagic)
import CardanoNode (RunningNode (..))
import Hydra.Cardano.Api (File (..), Lovelace (..))

-- Hydra imports
import Hydra.Network (Host (..))

-- HydraAuction imports
import HydraAuctionUtils.Fixture (Actor (..), actorName)
import HydraAuctionUtils.Types.Natural (Natural, intToNatural, naturalToInt)

execParserForCliArgs :: forall x. Parser x -> IO x
execParserForCliArgs parser = do
  customExecParser preferences options
  where
    options =
      info
        (parser <**> helper)
        fullDesc
    preferences = prefs (showHelpOnEmpty <> showHelpOnError)

parseActor :: ReadM Actor
parseActor =
  eitherReader $
    note "failed to parse actor" . parseToMaybe
  where
    parseToMaybe = flip Map.lookup nameToActor . fmap toLower
    nameToActor =
      Map.fromList
        [ (actorName actor, actor)
        | actor <- [minBound .. maxBound]
        ]

-- FIXME: remove
parseAdaAsNatural :: ReadM Natural
parseAdaAsNatural = eitherReader $ \s -> note "failed to parse Ada" $ do
  ada <- readMaybe s
  let lovelace = ada * 1_000_000
  intToNatural lovelace

parseAda :: ReadM Lovelace
parseAda = Lovelace . naturalToInt <$> parseAdaAsNatural

parseNetworkMagic :: ReadM NetworkMagic
parseNetworkMagic = eitherReader $ \s -> note "failed to parse network magic" $ do
  magic <- readMaybe s
  pure $ NetworkMagic magic

parseHost :: Maybe Int -> ReadM Host
parseHost defaultPort =
  -- FIXME: custom error in case of port missing but requied
  eitherReader $ \s -> note "failed to parse host and port" $
    do
      (host, mPortString) <- maybeHostAndPort s
      portString <- mPortString <> (show <$> defaultPort)
      port <- readMaybe portString
      return $ Host (Text.pack host) port

cardanoRunningNodeParser :: Parser RunningNode
cardanoRunningNodeParser =
  RunningNode <$> nodeSocketParser <*> networkIdParser
  where
    nodeSocketParser =
      File
        <$> strOption
          ( long "cardano-node-socket"
              <> metavar "CARDANO_NODE_SOCKET"
              <> help "Absolute path to the cardano node socket"
          )

    networkIdParser :: Parser NetworkId
    networkIdParser =
      fromNetworkMagic
        <$> option
          parseNetworkMagic
          ( long "network-magic"
              <> metavar "NETWORK_MAGIC"
              <> help "Network magic for cardano"
          )

platform :: Parser Host
platform =
  option
    (parseHost Nothing)
    ( short 'p'
        <> long "platform-server"
        <> metavar "PLATFORM"
        <> help "Host and port of platform server"
    )

websocketsHost :: Parser Host
websocketsHost =
  option
    (parseHost Nothing)
    ( long "websockets-host"
        <> metavar "WEBSOCKETS_HOST"
        <> help "Host and port to use for serving Websocket server"
    )
