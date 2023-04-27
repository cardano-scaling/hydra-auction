module EndToEnd.Ledger.L2Steps (
  delegateStepOnExpectedHydraEvent,
  emulateDelegatesStart,
  emulateClosing,
  emulateCommiting,
  placeNewBidOnL2AndCheck,
) where

-- Prelude imports
import Prelude

-- Haskell imports

import Control.Monad (replicateM_)
import Control.Monad.State (StateT)
import Control.Monad.Trans (MonadIO (..), MonadTrans (..))
import GHC.Stack (HasCallStack)

-- Haskell test imports
import Test.Tasty.HUnit (assertEqual)

-- Hydra imports
import Hydra.Chain (HeadId)

-- HydraAuction imports

import HydraAuction.Delegate (ClientResponseScope (..), DelegateEvent (..), delegateEventStep, delegateFrontendRequestStep)
import HydraAuction.Delegate.CompositeRunner (CompositeRunner, runHydraInComposite, runL1RunnerInComposite)
import HydraAuction.Delegate.Interface (
  DelegateResponse (..),
  DelegateState (..),
  FrontendRequest (..),
  InitializedState (..),
  ResponseReason (..),
 )
import HydraAuction.Hydra.Interface (HydraEvent (..), HydraEventKind (..))
import HydraAuction.Hydra.Monad (AwaitedHydraEvent (..), waitForHydraEvent)
import HydraAuction.OnChain (AuctionScript (..))
import HydraAuction.Tx.Common (scriptSingleUtxo)
import HydraAuction.Tx.StandingBid (createStandingBidDatum, queryStandingBidDatum)
import HydraAuction.Types (AuctionStage (..), AuctionTerms, Natural, standingBid, standingBidState)
import HydraAuctionUtils.Fixture (Actor, keysFor)
import HydraAuctionUtils.Monads.Actors (MonadHasActor (..))

-- HydraAuction test imports
import EndToEnd.HydraUtils (DelegatesClusterEmulator, EmulatorDelegate (..), runCompositeForAllDelegates, runCompositeForDelegate)

delegateStepOnExpectedHydraEvent ::
  HasCallStack =>
  AwaitedHydraEvent ->
  [DelegateResponse] ->
  StateT DelegateState CompositeRunner ()
delegateStepOnExpectedHydraEvent eventSpec expectedResponses = do
  Just event <-
    lift $
      runHydraInComposite $
        waitForHydraEvent eventSpec
  delegate <- askActor
  responses <- delegateEventStep $ HydraEvent event
  let message =
        "HydraEvent delegate "
          <> show delegate
          <> " reaction on "
          <> show eventSpec
  liftIO $ assertEqual message expectedResponses responses

emulateDelegatesStart :: HasCallStack => DelegatesClusterEmulator HeadId
emulateDelegatesStart = do
  runCompositeForDelegate Main $ do
    [] <- delegateEventStep Start
    return ()

  headId : _ <- runCompositeForAllDelegates $ do
    Just event@(HeadIsInitializing headId) <- waitForHydraEvent Any
    responses <- delegateEventStep $ HydraEvent event
    liftIO $
      assertEqual
        "Initializing reaction"
        [CurrentDelegateState Updated $ Initialized headId NotYetOpen]
        responses
    return headId
  return headId

emulateCommiting :: HasCallStack => HeadId -> AuctionTerms -> DelegatesClusterEmulator ()
emulateCommiting headId terms = do
  -- Main delegate commits Standing Bid
  existingStandingBid <- runCompositeForDelegate Main $
    lift $
      runL1RunnerInComposite $ do
        Just datum <- queryStandingBidDatum terms
        return $ standingBid $ standingBidState datum

  runCompositeForDelegate Main $ do
    Just (standingBidTxIn, _) <-
      lift $
        runL1RunnerInComposite $
          scriptSingleUtxo StandingBid terms
    responses <-
      delegateFrontendRequestStep
        ( 1
        , CommitStandingBid
            { auctionTerms = terms
            , utxoToCommit = standingBidTxIn
            }
        )
    liftIO $
      assertEqual "Commit Main" [(Broadcast, AuctionSet terms)] responses

  -- Secondary delegates should commit money on L2 in reaction
  -- (we do not check that)
  -- They states should reflect existence of first commit now

  _ <-
    runCompositeForAllDelegates $ do
      delegateStepOnExpectedHydraEvent
        (SpecificKind CommittedKind)
        [CurrentDelegateState Updated (Initialized headId HasCommit)]

  -- Secondary commits creates Commited evens, which Delegates should ignore

  replicateM_ 2 $
    runCompositeForAllDelegates $
      delegateStepOnExpectedHydraEvent
        (SpecificKind CommittedKind)
        []

  -- After all Hydra got open and states of every Delegate reflect that

  _ <-
    runCompositeForAllDelegates $
      delegateStepOnExpectedHydraEvent
        (SpecificKind HeadIsOpenKind)
        [ CurrentDelegateState
            Updated
            (Initialized headId $ Open existingStandingBid)
        ]

  return ()

emulateClosing :: HasCallStack => HeadId -> DelegatesClusterEmulator ()
emulateClosing headId = do
  [] <-
    runCompositeForDelegate Main $
      delegateEventStep $
        AuctionStageStarted BiddingEndedStage
  _ <-
    runCompositeForAllDelegates $
      delegateStepOnExpectedHydraEvent
        (SpecificKind HeadIsClosedKind)
        [CurrentDelegateState Updated (Initialized headId Closed)]
  _ <-
    runCompositeForAllDelegates $
      delegateStepOnExpectedHydraEvent
        (SpecificKind ReadyToFanoutKind)
        []
  _ <-
    runCompositeForAllDelegates $
      delegateStepOnExpectedHydraEvent
        (SpecificKind HeadIsFinalizedKind)
        [CurrentDelegateState Updated (Initialized headId Finalized)]
  return ()

placeNewBidOnL2AndCheck ::
  HeadId ->
  AuctionTerms ->
  Actor ->
  Natural ->
  StateT DelegateState CompositeRunner ()
placeNewBidOnL2AndCheck headId terms bidder amount = do
  delegate <- askActor
  let fakeClientId = fromEnum delegate
  liftIO $
    putStrLn $
      "Placing bid by bidder: "
        <> show bidder
        <> " on delegate "
        <> show delegate
        <> " for "
        <> show amount
  (bidderPublicKey, _) <- liftIO $ keysFor bidder
  let bidDatum = createStandingBidDatum terms amount bidderPublicKey
  submitNewBidToDelegate fakeClientId bidDatum
  checkStandingBidWasUpdated bidDatum
  where
    submitNewBidToDelegate fakeClientId bidDatum = do
      responses <-
        delegateFrontendRequestStep
          (fakeClientId, NewBid {auctionTerms = terms, datum = bidDatum})
      liftIO $
        assertEqual
          "New bid"
          [(PerClient fakeClientId, ClosingTxTemplate)]
          responses
    checkStandingBidWasUpdated bidDatum = do
      let expectedBidTerms = standingBid $ standingBidState bidDatum
      delegateStepOnExpectedHydraEvent
        (SpecificKind SnapshotConfirmedKind)
        [ CurrentDelegateState
            Updated
            (Initialized headId $ Open expectedBidTerms)
        ]
