{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Interface to the block validation and chain extension logic in the Shelley
-- API.
module Cardano.Ledger.Shelley.API.Validation
  ( ShelleyState,
    TickTransitionError,
    BlockTransitionError,
    applyTickTransition,
    applyBlockTransition,
  )
where

import BaseTypes (Globals)
import BlockChain
import qualified Cardano.Crypto.DSIGN as DSIGN
import Cardano.Ledger.Shelley.Crypto
import Cardano.Prelude (NoUnexpectedThunks (..))
import Control.Arrow (left, right)
import Control.Monad.Except
import Control.Monad.Trans.Reader (runReader)
import Control.State.Transition.Extended (TRC (..), applySTS)
import Data.Either (fromRight)
import GHC.Generics (Generic)
import Ledger.Core (Relation (..))
import qualified LedgerState
import qualified STS.Bbody as STS
import qualified STS.Tick as STS
import Slot (SlotNo)
import qualified TxData as Tx

-- | Type alias for the state updated by TICK and BBODY rules
type ShelleyState = LedgerState.NewEpochState

{-------------------------------------------------------------------------------
  Applying blocks
-------------------------------------------------------------------------------}

mkTickEnv ::
  ShelleyState crypto ->
  STS.TickEnv crypto
mkTickEnv = STS.TickEnv . LedgerState.getGKeys

mkBbodyEnv ::
  ShelleyState crypto ->
  STS.BbodyEnv
mkBbodyEnv
  LedgerState.NewEpochState
    { LedgerState.nesOsched,
      LedgerState.nesEs
    } = STS.BbodyEnv
    { STS.bbodySlots = dom nesOsched,
      STS.bbodyPp = LedgerState.esPp nesEs,
      STS.bbodyReserves =
        LedgerState._reserves
          . LedgerState.esAccountState
          $ nesEs
    }

newtype TickTransitionError crypto
  = TickTransitionError [STS.PredicateFailure (STS.TICK crypto)]
  deriving (Eq, Show, Generic)

instance NoUnexpectedThunks (TickTransitionError crypto)

-- | Apply the header level ledger transition.
--
-- This handles checks and updates that happen on a slot tick, as well as a few
-- header level checks, such as size constraints.
applyTickTransition ::
  forall crypto.
  (Crypto crypto) =>
  Globals ->
  ShelleyState crypto ->
  SlotNo ->
  ShelleyState crypto
applyTickTransition globals state hdr =
  fromRight err . flip runReader globals
    . applySTS @(STS.TICK crypto)
    $ TRC (mkTickEnv state, state, hdr)
  where
    err = error "Panic! applyHeaderTransition failed."

newtype BlockTransitionError crypto
  = BlockTransitionError [STS.PredicateFailure (STS.BBODY crypto)]
  deriving (Eq, Generic, Show)

instance NoUnexpectedThunks (BlockTransitionError crypto)

-- | Apply the block level ledger transition.
applyBlockTransition ::
  forall crypto m.
  ( Crypto crypto,
    MonadError (BlockTransitionError crypto) m,
    DSIGN.Signable (DSIGN crypto) (Tx.TxBody crypto)
  ) =>
  Globals ->
  ShelleyState crypto ->
  Block crypto ->
  m (ShelleyState crypto)
applyBlockTransition globals state blk =
  liftEither
    . right (updateShelleyState state)
    . left (BlockTransitionError . join)
    $ res
  where
    res =
      flip runReader globals . applySTS @(STS.BBODY crypto) $
        TRC (mkBbodyEnv state, bbs, blk)
    updateShelleyState ::
      ShelleyState crypto ->
      STS.BbodyState crypto ->
      ShelleyState crypto
    updateShelleyState ss (STS.BbodyState ls bcur) =
      LedgerState.updateNES ss bcur ls
    bbs =
      STS.BbodyState
        (LedgerState.esLState $ LedgerState.nesEs state)
        (LedgerState.nesBcur state)