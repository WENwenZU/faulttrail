///| Public data model of the decision core.
///
/// Three ideas are kept apart on purpose:
/// * `Probe` is what the host did or failed to do.
/// * `Verdict` is what that result says about the target property.
/// * `Outcome` is what the engine can conclude from all recorded verdicts.
///
/// Collapsing a build failure or a timeout into "bad" is the most common way a
/// bisect session reports the wrong commit, so the mapping is explicit here and
/// only `Passed`/`Failed` constrain the fault boundary.

///|
/// What a single probe run produced on one commit.
pub(all) enum Probe {
  Passed // the target property was observed to hold
  Failed // the target property was observed not to hold
  BuildFailed // the revision could not be built, so nothing was observed
  TimedOut // the probe exceeded its time limit
  Skipped // the host decided not to run the probe
  Undetermined // the probe ran, but its result is not trustworthy
} derive(Eq, Debug)

///|
/// What a probe result says about the target property.
pub(all) enum Verdict {
  Good // the property held
  Bad // the property did not hold
  Skip // no reliable judgement was obtained
  Unknown // no reliable judgement was obtained
} derive(Eq, Debug)

///|
pub fn Probe::verdict(self : Probe) -> Verdict {
  match self {
    Passed => Good
    Failed => Bad
    BuildFailed | TimedOut | Skipped => Skip
    Undetermined => Unknown
  }
}

///|
/// Only a good or a bad observation narrows the fault boundary.
pub fn Verdict::constrains(self : Verdict) -> Bool {
  match self {
    Good | Bad => true
    Skip | Unknown => false
  }
}

///|
/// One recorded observation. `id` is assigned in recording order and is stable
/// for the lifetime of the session, so a conflict can name the exact records
/// that disagree and a correction can point at the record it retracts.
pub(all) struct Observation {
  id : Int32
  index : Int32
  probe : Probe
  attempt : Int32
  may_retry : Bool
  note : String
} derive(Eq, Debug)

///|
pub fn Observation::verdict(self : Observation) -> Verdict {
  self.probe.verdict()
}

///|
/// Budgets for evidence and computation. Both are checked before the work they
/// bound; reaching one yields an unfinished status, never a "located" result.
///
/// One **step** is one element examined by one `outcome()` call:
///
/// * one commit position visited while looking for the highest good or the
///   lowest bad position, while scanning for a testable candidate, or while
///   building the blocked-candidate explanation;
/// * one observation record visited while locating the records named in a
///   conflict report.
///
/// Testability itself is O(1): the engine keeps per-position retry flags up to
/// date when a record is accepted or retracted, so no evidence scan is charged
/// there. The step budget covers one `outcome()` call; it is not a lifetime
/// quota and it does not bound `candidate_span()` or the recording APIs.
pub(all) struct Limits {
  max_observations : Int32
  max_steps : Int32
} derive(Eq, Debug)

///|
pub fn Limits::new(max_observations : Int32, max_steps : Int32) -> Limits {
  { max_observations, max_steps, }
}

///|
pub fn Limits::default() -> Limits {
  { max_observations: 10000, max_steps: 1000000, }
}

///|
pub fn Limits::validate(self : Limits) -> Result[Unit, InvalidReport] {
  if self.max_observations <= 0 {
    return Err({
      code: "limits.max_observations",
      detail: "max_observations must be positive, got \{self.max_observations}",
    })
  }
  if self.max_steps <= 0 {
    return Err({
      code: "limits.max_steps",
      detail: "max_steps must be positive, got \{self.max_steps}",
    })
  }
  Ok(())
}

///|
/// Inclusive range of positions, used for candidate sets.
pub(all) struct Span {
  lo : Int32
  hi : Int32
} derive(Eq, Debug)

///|
pub fn Span::size(self : Span) -> Int32 {
  if self.hi < self.lo {
    0
  } else {
    self.hi - self.lo + 1
  }
}

///|
pub fn Span::contains(self : Span, index : Int32) -> Bool {
  index >= self.lo && index <= self.hi
}

///|
/// Reference to one recorded observation, used when reporting a conflict.
pub(all) struct EvidenceRef {
  obs_id : Int32
  index : Int32
  commit_id : String
} derive(Eq, Debug)

///|
pub(all) struct Recommendation {
  index : Int32
  commit_id : String
  span : Span
  why : String
} derive(Eq, Debug)

///|
pub(all) struct Located {
  index : Int32
  commit_id : String
  why : String
} derive(Eq, Debug)

///|
pub(all) struct BlockedNote {
  index : Int32
  commit_id : String
  reason : String
} derive(Eq, Debug)

///|
pub(all) struct Ambiguity {
  span : Span
  blocked : Array[BlockedNote]
  why : String
} derive(Eq, Debug)

///|
pub(all) struct ConflictReport {
  good : EvidenceRef
  bad : EvidenceRef
  why : String
} derive(Eq, Debug)

///|
pub(all) struct InsufficientReport {
  missing_good : Bool
  missing_bad : Bool
  why : String
} derive(Eq, Debug)

///|
pub(all) struct InvalidReport {
  code : String
  detail : String
} derive(Eq, Debug)

///|
pub(all) struct BudgetReport {
  kind : String
  limit : Int32
  detail : String
} derive(Eq, Debug)

///|
/// What the engine can say. Every constructor is a complete answer: none of
/// them is a silent guess, and `Conflict`/`Insufficient`/`Budget` never carry a
/// position that could be mistaken for a localisation.
///
/// Invalid input never reaches this type. A malformed sequence, an invalid
/// budget or an out-of-range observation is rejected at construction or at
/// record time (`SeqError`, `InvalidReport`, `RecordError`), before any evidence
/// exists to reason about; a soft "invalid" outcome would suggest the engine had
/// state worth interpreting.
pub(all) enum Outcome {
  NeedObservation(Recommendation)
  Located(Located)
  Ambiguous(Ambiguity)
  Conflict(ConflictReport)
  Insufficient(InsufficientReport)
  Budget(BudgetReport)
} derive(Eq, Debug)

///|
/// Reasons an observation cannot be accepted.
///
/// `NonCanonicalId`, `NonCanonicalAttempt` and `IdentifierSpaceExhausted` exist
/// because `Engine::replay_observation` is public: a replay must be a byte-for-
/// byte replay of a log this engine could have produced, not a convenient way to
/// inject records that no `observe` call would ever create.
pub(all) enum RecordError {
  IndexOutOfRange(Int32, Int32)
  UnknownCommit(String)
  ObservationsExhausted(Int32)
  NonCanonicalId(Int32, Int32)
  NonCanonicalAttempt(Int32, Int32)
  IdentifierSpaceExhausted(Int32)
} derive(Eq, Debug)

///|
/// Observation identifiers are dense and ordered, starting at 0. The value
/// below is reserved as the "one past the last usable identifier" marker, so the
/// largest identifier an engine will issue is `OBSERVATION_ID_BOUND - 1`.
pub const OBSERVATION_ID_BOUND : Int32 = 2147483647

///|
pub fn RecordError::message(self : RecordError) -> String {
  match self {
    IndexOutOfRange(index, length) =>
      "position \{index} is outside 0..\{length - 1}"
    UnknownCommit(id) => "the commit identifier '\{id}' is not in this sequence"
    ObservationsExhausted(limit) =>
      "the observation budget of \{limit} is exhausted"
    NonCanonicalId(found, expected) =>
      "observation id \{found} is not the next id of this log (expected \{expected})"
    NonCanonicalAttempt(found, expected) =>
      "attempt number \{found} does not match the active records at that position (expected \{expected})"
    IdentifierSpaceExhausted(limit) =>
      "the identifier space is exhausted; identifiers must stay below \{limit}"
  }
}

///|
/// Reasons a recorded observation cannot be retracted.
pub(all) enum RetractError {
  NoSuchObservation(Int32)
  AlreadyRetracted(Int32)
} derive(Eq, Debug)
