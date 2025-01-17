{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Cardano.Ledger.Alonzo.Rules.Utxos
  ( UTXOS,
    UtxosPredicateFailure (..),
    constructValidated,
    lbl2Phase,
    TagMismatchDescription (..),
  )
where

import Cardano.Binary (FromCBOR (..), ToCBOR (..))
import Cardano.Ledger.Alonzo.Language (Language)
import Cardano.Ledger.Alonzo.PlutusScriptApi
  ( CollectError,
    collectTwoPhaseScriptInputs,
    evalScripts,
  )
import Cardano.Ledger.Alonzo.Scripts (Script)
import Cardano.Ledger.Alonzo.Tx
  ( CostModel,
    DataHash,
    IsValid (..),
    ValidatedTx (..),
  )
import qualified Cardano.Ledger.Alonzo.TxBody as Alonzo
import Cardano.Ledger.Alonzo.TxInfo (FailureDescription (..), ScriptResult (..))
import qualified Cardano.Ledger.Alonzo.TxWitness as Alonzo
import Cardano.Ledger.BaseTypes
  ( Globals,
    ProtVer,
    ShelleyBase,
    StrictMaybe (..),
    epochInfo,
    strictMaybeToMaybe,
    systemStart,
  )
import Cardano.Ledger.Coin (Coin)
import qualified Cardano.Ledger.Core as Core
import Cardano.Ledger.Era (Crypto, Era, ValidateScript)
import Cardano.Ledger.Mary.Value (Value)
import Cardano.Ledger.Rules.ValidationMode (lblStatic)
import Cardano.Ledger.Shelley.LedgerState (PPUPState (..), UTxOState (..), keyRefunds, updateStakeDistribution)
import qualified Cardano.Ledger.Shelley.LedgerState as Shelley
import Cardano.Ledger.Shelley.PParams (Update)
import Cardano.Ledger.Shelley.Rules.Ppup (PPUP, PPUPEnv (..), PpupPredicateFailure)
import Cardano.Ledger.Shelley.Rules.Utxo (UtxoEnv (..), updateUTxOState)
import Cardano.Ledger.Shelley.TxBody (DCert, Wdrl)
import Cardano.Ledger.Shelley.UTxO (UTxO (..), balance, totalDeposits)
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Ledger.Val as Val
import Control.Monad.Except (MonadError (throwError))
import Control.Monad.Trans.Reader (asks)
import Control.State.Transition.Extended
import Data.Coders
import qualified Data.Compact.SplitMap as SplitMap
import Data.Foldable (toList)
import Data.Functor.Identity (Identity (..))
import Data.List (intercalate)
import qualified Data.Map.Strict as Map
import Data.Sequence.Strict (StrictSeq)
import Data.Set (Set)
import Debug.Trace (traceEvent)
import GHC.Generics (Generic)
import GHC.Records (HasField (..))
import NoThunks.Class (NoThunks)

--------------------------------------------------------------------------------
-- The UTXOS transition system
--------------------------------------------------------------------------------

data UTXOS era

instance
  forall era.
  ( Era era,
    Eq (Core.PParams era),
    Show (Core.PParams era),
    Show (Core.PParamsDelta era),
    Eq (Core.PParamsDelta era),
    Embed (Core.EraRule "PPUP" era) (UTXOS era),
    Environment (Core.EraRule "PPUP" era) ~ PPUPEnv era,
    State (Core.EraRule "PPUP" era) ~ PPUPState era,
    Signal (Core.EraRule "PPUP" era) ~ Maybe (Update era),
    Core.Script era ~ Script era,
    Core.Value era ~ Value (Crypto era),
    Core.TxOut era ~ Alonzo.TxOut era,
    Core.TxBody era ~ Alonzo.TxBody era,
    ValidateScript era,
    HasField "_keyDeposit" (Core.PParams era) Coin,
    HasField "_poolDeposit" (Core.PParams era) Coin,
    HasField "_costmdls" (Core.PParams era) (Map.Map Language CostModel),
    HasField "_protocolVersion" (Core.PParams era) ProtVer,
    HasField "datahash" (Core.TxOut era) (StrictMaybe (DataHash (Crypto era)))
  ) =>
  STS (UTXOS era)
  where
  type BaseM (UTXOS era) = ShelleyBase
  type Environment (UTXOS era) = UtxoEnv era
  type State (UTXOS era) = UTxOState era
  type Signal (UTXOS era) = ValidatedTx era
  type PredicateFailure (UTXOS era) = UtxosPredicateFailure era
  type Event (UTXOS era) = UtxosEvent era

  transitionRules = [utxosTransition]

utxosTransition ::
  forall era.
  ( Core.Script era ~ Script era,
    Environment (Core.EraRule "PPUP" era) ~ PPUPEnv era,
    State (Core.EraRule "PPUP" era) ~ PPUPState era,
    Signal (Core.EraRule "PPUP" era) ~ Maybe (Update era),
    Embed (Core.EraRule "PPUP" era) (UTXOS era),
    Eq (Core.PParams era),
    Show (Core.PParams era),
    Show (Core.PParamsDelta era),
    Eq (Core.PParamsDelta era),
    Core.TxOut era ~ Alonzo.TxOut era,
    Core.Value era ~ Value (Crypto era),
    Core.TxBody era ~ Alonzo.TxBody era,
    ValidateScript era,
    HasField "inputs" (Core.TxBody era) (Set (TxIn (Crypto era))),
    HasField "certs" (Core.TxBody era) (StrictSeq (DCert (Crypto era))),
    HasField "_keyDeposit" (Core.PParams era) Coin,
    HasField "_poolDeposit" (Core.PParams era) Coin,
    HasField "collateral" (Core.TxBody era) (Set (TxIn (Crypto era))),
    HasField "_protocolVersion" (Core.PParams era) ProtVer,
    HasField "_costmdls" (Core.PParams era) (Map.Map Language CostModel)
  ) =>
  TransitionRule (UTXOS era)
utxosTransition =
  judgmentContext >>= \(TRC (_, _, tx)) -> do
    case getField @"isValid" tx of
      IsValid True -> scriptsValidateTransition
      IsValid False -> scriptsNotValidateTransition

scriptsValidateTransition ::
  forall era.
  ( Environment (Core.EraRule "PPUP" era) ~ PPUPEnv era,
    State (Core.EraRule "PPUP" era) ~ PPUPState era,
    Signal (Core.EraRule "PPUP" era) ~ Maybe (Update era),
    Embed (Core.EraRule "PPUP" era) (UTXOS era),
    Eq (Core.PParams era),
    Show (Core.PParams era),
    Show (Core.PParamsDelta era),
    Eq (Core.PParamsDelta era),
    Core.Script era ~ Script era,
    Core.TxBody era ~ Alonzo.TxBody era,
    Core.TxOut era ~ Alonzo.TxOut era,
    Core.Value era ~ Value (Crypto era),
    ValidateScript era,
    HasField "inputs" (Core.TxBody era) (Set (TxIn (Crypto era))),
    HasField "certs" (Core.TxBody era) (StrictSeq (DCert (Crypto era))),
    HasField "_keyDeposit" (Core.PParams era) Coin,
    HasField "_poolDeposit" (Core.PParams era) Coin,
    HasField "_costmdls" (Core.PParams era) (Map.Map Language CostModel),
    HasField "_protocolVersion" (Core.PParams era) ProtVer
  ) =>
  TransitionRule (UTXOS era)
scriptsValidateTransition = do
  TRC (UtxoEnv slot pp poolParams genDelegs, u@(UTxOState utxo _ _ pup _), tx) <-
    judgmentContext
  let txb = body tx
      refunded = keyRefunds pp txb
      txcerts = toList $ getField @"certs" txb
      depositChange =
        totalDeposits pp (`Map.notMember` poolParams) txcerts <-> refunded
  sysSt <- liftSTS $ asks systemStart
  ei <- liftSTS $ asks epochInfo
  let !_ =
        traceEvent
          ( intercalate
              ","
              [ "[LEDGER][SCRIPTS_VALIDATION]",
                "BEGIN"
              ]
          )
          ()
  case collectTwoPhaseScriptInputs ei sysSt pp tx utxo of
    Right sLst ->
      case evalScripts @era tx sLst of
        Fails sss ->
          False
            ?!## ValidationTagMismatch
              (getField @"isValid" tx)
              (FailedUnexpectedly sss)
        Passes -> pure ()
    Left info -> failBecause (CollectErrors info)
  let !_ =
        traceEvent
          ( intercalate
              ","
              [ "[LEDGER][SCRIPTS_VALIDATION]",
                "END"
              ]
          )
          ()
  ppup' <-
    trans @(Core.EraRule "PPUP" era) $
      TRC
        (PPUPEnv slot pp genDelegs, pup, strictMaybeToMaybe $ getField @"update" txb)

  pure $! updateUTxOState u txb depositChange ppup'

scriptsNotValidateTransition ::
  forall era.
  ( Era era,
    Eq (Core.PParams era),
    Show (Core.PParams era),
    Show (Core.PParamsDelta era),
    Eq (Core.PParamsDelta era),
    Environment (Core.EraRule "PPUP" era) ~ PPUPEnv era,
    State (Core.EraRule "PPUP" era) ~ PPUPState era,
    Signal (Core.EraRule "PPUP" era) ~ Maybe (Update era),
    Embed (Core.EraRule "PPUP" era) (UTXOS era),
    ValidateScript era,
    Core.Script era ~ Script era,
    Core.TxBody era ~ Alonzo.TxBody era,
    Core.TxOut era ~ Alonzo.TxOut era,
    Core.Value era ~ Value (Crypto era),
    HasField "collateral" (Core.TxBody era) (Set (TxIn (Crypto era))),
    HasField "_costmdls" (Core.PParams era) (Map.Map Language CostModel),
    HasField "_keyDeposit" (Core.PParams era) Coin,
    HasField "_poolDeposit" (Core.PParams era) Coin,
    HasField "_protocolVersion" (Core.PParams era) ProtVer
  ) =>
  TransitionRule (UTXOS era)
scriptsNotValidateTransition = do
  TRC (UtxoEnv _ pp _ _, us@(UTxOState utxo _ fees _ _), tx) <- judgmentContext
  let txb = body tx
  sysSt <- liftSTS $ asks systemStart
  ei <- liftSTS $ asks epochInfo
  let !_ =
        traceEvent
          ( intercalate
              ","
              [ "[LEDGER][SCRIPTS_NOT_VALIDATE_TRANSITION]",
                "BEGIN"
              ]
          )
          ()
  case collectTwoPhaseScriptInputs ei sysSt pp tx utxo of
    Right sLst ->
      case evalScripts @era tx sLst of
        Passes -> False ?!## ValidationTagMismatch (getField @"isValid" tx) PassedUnexpectedly
        Fails _sss -> pure ()
    Left info -> failBecause (CollectErrors info)
  let !_ =
        traceEvent
          ( intercalate
              ","
              [ "[LEDGER][SCRIPTS_NOT_VALIDATE_TRANSITION]",
                "END"
              ]
          )
          ()
      {- utxoKeep = getField @"collateral" txb ⋪ utxo -}
      {- utxoDel  = getField @"collateral" txb ◁ utxo -}
      !(!utxoKeep, !utxoDel) =
        SplitMap.extractKeysSet (unUTxO utxo) (getField @"collateral" txb)
  pure
    $! us
      { _utxo = UTxO utxoKeep,
        _fees = fees <> Val.coin (balance (UTxO utxoDel)),
        _stakeDistro = updateStakeDistribution (_stakeDistro us) (UTxO utxoDel) mempty
      }

data TagMismatchDescription
  = PassedUnexpectedly
  | FailedUnexpectedly [FailureDescription]
  deriving (Show, Eq, Generic, NoThunks)

instance ToCBOR TagMismatchDescription where
  toCBOR PassedUnexpectedly = encode (Sum PassedUnexpectedly 0)
  toCBOR (FailedUnexpectedly fs) = encode (Sum FailedUnexpectedly 1 !> To fs)

instance FromCBOR TagMismatchDescription where
  fromCBOR = decode (Summands "TagMismatchDescription" dec)
    where
      dec 0 = SumD PassedUnexpectedly
      dec 1 = SumD FailedUnexpectedly <! From
      dec n = Invalid n

data UtxosPredicateFailure era
  = -- | The 'isValid' tag on the transaction is incorrect. The tag given
    --   here is that provided on the transaction (whereas evaluation of the
    --   scripts gives the opposite.). The Text tries to explain why it failed.
    ValidationTagMismatch IsValid TagMismatchDescription
  | -- | We could not find all the necessary inputs for a Plutus Script.
    --         Previous PredicateFailure tests should make this impossible, but the
    --         consequences of not detecting this means scripts get dropped, so things
    --         might validate that shouldn't. So we double check in the function
    --         collectTwoPhaseScriptInputs, it should find data for every Script.
    CollectErrors [CollectError (Crypto era)]
  | UpdateFailure (PredicateFailure (Core.EraRule "PPUP" era))
  deriving
    (Generic)

instance
  ( Era era,
    ToCBOR (PredicateFailure (Core.EraRule "PPUP" era))
  ) =>
  ToCBOR (UtxosPredicateFailure era)
  where
  toCBOR (ValidationTagMismatch v descr) = encode (Sum ValidationTagMismatch 0 !> To v !> To descr)
  toCBOR (CollectErrors cs) =
    encode (Sum (CollectErrors @era) 1 !> To cs)
  toCBOR (UpdateFailure pf) = encode (Sum (UpdateFailure @era) 2 !> To pf)

instance
  ( Era era,
    FromCBOR (PredicateFailure (Core.EraRule "PPUP" era))
  ) =>
  FromCBOR (UtxosPredicateFailure era)
  where
  fromCBOR = runIdentity <$> decode (Summands "UtxosPredicateFailure" decUtxosPredicateFailure)

instance
  ( Era era,
    FromCBOR (Annotator (PredicateFailure (Core.EraRule "PPUP" era)))
  ) =>
  FromCBOR (Annotator (UtxosPredicateFailure era))
  where
  fromCBOR = decode (Summands "UtxosPredicateFailure" decUtxosPredicateFailure)

decUtxosPredicateFailure ::
  forall f era.
  ( Era era,
    FromCBOR (f (PredicateFailure (Core.EraRule "PPUP" era))),
    Applicative f
  ) =>
  Word ->
  Decode 'Open (f (UtxosPredicateFailure era))
decUtxosPredicateFailure 0 = Ann $ SumD ValidationTagMismatch <! From <! From
decUtxosPredicateFailure 1 = Ann $ SumD (CollectErrors @era) <! From
decUtxosPredicateFailure 2 = SumD (pure UpdateFailure) <*! From
decUtxosPredicateFailure n = Ann $ Invalid n

deriving stock instance
  ( Shelley.TransUTxOState Show era,
    Show (PredicateFailure (Core.EraRule "PPUP" era))
  ) =>
  Show (UtxosPredicateFailure era)

instance
  ( Shelley.TransUTxOState Eq era,
    Eq (PredicateFailure (Core.EraRule "PPUP" era))
  ) =>
  Eq (UtxosPredicateFailure era)
  where
  (ValidationTagMismatch a x) == (ValidationTagMismatch b y) = a == b && x == y
  (CollectErrors x) == (CollectErrors y) = x == y
  (UpdateFailure x) == (UpdateFailure y) = x == y
  _ == _ = False

instance
  ( Shelley.TransUTxOState NoThunks era,
    NoThunks (PredicateFailure (Core.EraRule "PPUP" era))
  ) =>
  NoThunks (UtxosPredicateFailure era)

newtype UtxosEvent era
  = UpdateEvent (Event (Core.EraRule "PPUP" era))

instance
  ( Era era,
    STS (PPUP era),
    PredicateFailure (Core.EraRule "PPUP" era) ~ PpupPredicateFailure era,
    Event (Core.EraRule "PPUP" era) ~ Event (PPUP era)
  ) =>
  Embed (PPUP era) (UTXOS era)
  where
  wrapFailed = UpdateFailure
  wrapEvent = UpdateEvent

-- =================================================================

-- | Construct a 'ValidatedTx' from a 'Core.Tx' by setting the `IsValid`
-- flag.
--
-- Note that this simply constructs the transaction; it does not validate
-- anything other than the scripts. Thus the resulting transaction may be
-- completely invalid.
constructValidated ::
  forall era m.
  ( MonadError [UtxosPredicateFailure era] m,
    Core.Script era ~ Script era,
    Core.TxOut era ~ Alonzo.TxOut era,
    Core.Value era ~ Value (Crypto era),
    Core.TxBody era ~ Alonzo.TxBody era,
    Core.Witnesses era ~ Alonzo.TxWitness era,
    ValidateScript era,
    HasField "inputs" (Core.TxBody era) (Set (TxIn (Crypto era))),
    HasField "certs" (Core.TxBody era) (StrictSeq (DCert (Crypto era))),
    HasField "datahash" (Core.TxOut era) (StrictMaybe (DataHash (Crypto era))),
    HasField "_costmdls" (Core.PParams era) (Map.Map Language CostModel),
    HasField "_protocolVersion" (Core.PParams era) ProtVer,
    HasField "wdrls" (Core.TxBody era) (Wdrl (Crypto era))
  ) =>
  Globals ->
  UtxoEnv era ->
  UTxOState era ->
  Core.Tx era ->
  m (ValidatedTx era)
constructValidated globals (UtxoEnv _ pp _ _) st tx =
  case collectTwoPhaseScriptInputs ei sysS pp tx utxo of
    Left errs -> throwError [CollectErrors errs]
    Right sLst ->
      let scriptEvalResult = evalScripts @era tx sLst
          vTx =
            ValidatedTx
              (getField @"body" tx)
              (getField @"wits" tx)
              (IsValid (lift scriptEvalResult))
              (getField @"auxiliaryData" tx)
       in pure vTx
  where
    utxo = _utxo st
    sysS = systemStart globals
    ei = epochInfo globals
    lift Passes = True -- Convert a ScriptResult into a Bool
    lift (Fails _) = False

--------------------------------------------------------------------------------
-- 2-phase checks
--------------------------------------------------------------------------------

-- $2-phase
--
-- Above and beyond 'static' checks (see 'Cardano.Ledger.Rules.ValidateMode') we
-- additionally label 2-phase checks. This is to support a workflow where we
-- validate a 'ValidatedTx' directly after constructing it with
-- 'constructValidated' - we would like to trust the flag we have ourselves just
-- computed rather than re-calculating it. However, all other checks should be
-- computed as normal.

-- | Indicates that this check depends only upon the signal to the transition,
-- not the state or environment.
lbl2Phase :: Label
lbl2Phase = "2phase"

-- | Construct a 2-phase predicate check.
--
--   Note that 2-phase predicate checks are by definition static.
(?!##) :: Bool -> PredicateFailure sts -> Rule sts ctx ()
(?!##) = labeledPred [lblStatic, lbl2Phase]

infix 1 ?!##
