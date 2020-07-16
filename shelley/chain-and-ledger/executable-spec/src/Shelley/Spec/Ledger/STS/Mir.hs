{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE EmptyDataDeriving #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Shelley.Spec.Ledger.STS.Mir
  ( MIR,
    PredicateFailure,
  )
where

import Cardano.Prelude (NoUnexpectedThunks (..))
import Control.Iterate.SetAlgebra (dom, eval, (∪+), (◁))
import Control.State.Transition
  ( InitialRule,
    STS (..),
    TRC (..),
    TransitionRule,
    judgmentContext,
  )
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import Shelley.Spec.Ledger.BaseTypes (ShelleyBase)
import Shelley.Spec.Ledger.Delegation.Certificates (StakeCreds (..))
import Shelley.Spec.Ledger.EpochBoundary (emptySnapShots)
import Shelley.Spec.Ledger.LedgerState
  ( AccountState (..),
    EpochState,
    InstantaneousRewards (..),
    RewardAccounts,
    _delegationState,
    _dstate,
    _irwd,
    _rewards,
    _stkCreds,
    emptyAccount,
    emptyInstantaneousRewards,
    emptyLedgerState,
    esAccountState,
    esLState,
    esNonMyopic,
    esPp,
    esPrevPp,
    esSnapshots,
    pattern EpochState,
  )
import Shelley.Spec.Ledger.PParams (emptyPParams)
import Shelley.Spec.Ledger.Rewards (emptyNonMyopic)

data MIR crypto

instance Typeable crypto => STS (MIR crypto) where
  type State (MIR crypto) = EpochState crypto
  type Signal (MIR crypto) = ()
  type Environment (MIR crypto) = ()
  type BaseM (MIR crypto) = ShelleyBase
  data PredicateFailure (MIR crypto) -- No Failures
    deriving (Show, Generic, Eq)

  initialRules = [initialMir]
  transitionRules = [mirTransition]

instance NoUnexpectedThunks (PredicateFailure (MIR crypto))

initialMir :: InitialRule (MIR crypto)
initialMir =
  pure $
    EpochState
      emptyAccount
      emptySnapShots
      emptyLedgerState
      emptyPParams
      emptyPParams
      emptyNonMyopic

mirTransition :: forall crypto. TransitionRule (MIR crypto)
mirTransition = do
  TRC
    ( _,
      EpochState
        { esAccountState = acnt,
          esSnapshots = ss,
          esLState = ls,
          esPrevPp = pr,
          esPp = pp,
          esNonMyopic = nm
        },
      ()
      ) <-
    judgmentContext
  let dpState = _delegationState ls
      dState = _dstate dpState
      StakeCreds stkcreds = _stkCreds dState
      irwdR = eval $ (dom stkcreds) ◁ (iRReserves $ _irwd dState) :: RewardAccounts crypto
      totFromReserves = sum irwdR
      reserves = _reserves acnt
      irwdT = eval $ (dom stkcreds) ◁ (iRTreasury $ _irwd dState) :: RewardAccounts crypto
      totFromTreasury = sum irwdT
      treasury = _treasury acnt
      update = (eval (irwdR ∪+ irwdT)) :: RewardAccounts crypto

  if totFromReserves <= reserves && totFromTreasury <= treasury
    then
      pure $
        EpochState
          acnt
            { _reserves = reserves - totFromReserves,
              _treasury = treasury - totFromTreasury
            }
          ss
          ls
            { _delegationState =
                dpState
                  { _dstate =
                      dState
                        { _rewards = eval ((_rewards dState) ∪+ update),
                          _irwd = emptyInstantaneousRewards
                        }
                  }
            }
          pr
          pp
          nm
    else
      pure $
        EpochState
          acnt
          ss
          ls
            { _delegationState =
                dpState
                  { _dstate =
                      dState {_irwd = emptyInstantaneousRewards}
                  }
            }
          pr
          pp
          nm
