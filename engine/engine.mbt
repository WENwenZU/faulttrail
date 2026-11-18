///| The decision core.
///
/// The engine never runs a test, never reads a repository and never looks at a
/// file. It receives positions and probe results, keeps every observation it
/// was given, and answers with the set of first-anomalous positions still
/// compatible with that evidence plus one deterministic next step.
///
/// Model: on a linear sequence `v0 .. v(n-1)` the target property is assumed to
/// hold for `v0 .. v(k-1)` and to fail for `vk .. v(n-1)`, for exactly one
/// hidden `k` in `0 .. n-1`. A good observation at `i` implies `k > i`; a bad
/// observation at `i` implies `k <= i`. Nothing else is assumed, so `skip` and
/// `unknown` cannot move a boundary, and a good record at or after a bad record
/// is a contradiction rather than a majority vote.

///|
/// Counts the elements one `outcome()` call examines, so a single call has one
/// budget shared by every phase instead of one counter per helper.
priv struct Meter {
  mut used : Int32
  limit : Int32
  mut stopped : Bool
}

///|
fn meter_new(limit : Int32) -> Meter {
  { used: 0, limit, stopped: false, }
}

///|
/// Take one step if the budget still allows it. The limit is checked before the
/// item is examined, so a call never looks at more than `limit` elements.
fn Meter::take(self : Meter) -> Bool {
  if self.used >= self.limit {
    self.stopped = true
    return false
  }
  self.used = self.used + 1
  true
}

///|
fn Meter::stopped(self : Meter) -> Bool {
  self.stopped
}

///|
/// All state is private. Callers can query an engine and record evidence, but
/// they cannot reach the underlying arrays, the sequence copy or the counters,
/// so the invariants established by `new` and maintained by `accept` /
/// `retract` cannot be edited from outside this package.
pub struct Engine {
  priv sequence : @version.Sequence
  priv limits : Limits
  priv attempt_limit : Int32
  priv observations : Array[Observation]
  priv active : Array[Bool]
  priv good_at : Array[Int32]
  priv bad_at : Array[Int32]
  priv nonconclusive_at : Array[Int32]
  priv retry_forbidden_at : Array[Bool]
  priv mut next_id : Int32
}

///|
/// Create an engine for a validated sequence.
///
/// `attempt_limit` is the maximum number of probes the engine is willing to
/// suggest for one commit whose earlier attempts were non-conclusive. The
/// default of 1 means a skipped commit is never suggested twice.
pub fn Engine::new(
  sequence : @version.Sequence,
  limits~ : Limits = Limits::default(),
  attempt_limit~ : Int32 = 1,
) -> Result[Engine, InvalidReport] {
  match limits.validate() {
    Err(report) => return Err(report)
    Ok(_) => ()
  }
  if attempt_limit <= 0 {
    return Err({
      code: "attempt_limit",
      detail: "attempt_limit must be positive, got \{attempt_limit}",
    })
  }
  let n = sequence.length()
  Ok({
    sequence,
    limits,
    attempt_limit,
    observations: [],
    active: [],
    good_at: Array::make(n, 0),
    bad_at: Array::make(n, 0),
    nonconclusive_at: Array::make(n, 0),
    retry_forbidden_at: Array::make(n, false),
    next_id: 0,
  })
}

///|
pub fn Engine::sequence(self : Engine) -> @version.Sequence {
  self.sequence
}

///|
pub fn Engine::attempt_limit(self : Engine) -> Int32 {
  self.attempt_limit
}

///|
pub fn Engine::limits(self : Engine) -> Limits {
  self.limits
}

///|
/// All observations ever recorded, including retracted ones, in recording order.
/// The array is a copy; the records themselves are immutable.
pub fn Engine::observations(self : Engine) -> Array[Observation] {
  self.observations.copy()
}

///|
pub fn Engine::is_active(self : Engine, obs_id : Int32) -> Bool {
  match self.find(obs_id) {
    Some(index) => self.active[index]
    None => false
  }
}

///|
fn Engine::find(self : Engine, obs_id : Int32) -> Int32? {
  let mut i = 0
  while i < self.observations.length() {
    if self.observations[i].id == obs_id {
      return Some(i)
    }
    i = i + 1
  }
  None
}

///|
/// Record a probe result for `index`, or explain why it cannot be recorded.
pub fn Engine::observe(
  self : Engine,
  index : Int32,
  probe : Probe,
  may_retry~ : Bool = false,
  note~ : String = "",
) -> Result[Observation, RecordError] {
  if index < 0 || index >= self.sequence.length() {
    return Err(IndexOutOfRange(index, self.sequence.length()))
  }
  if self.next_id >= OBSERVATION_ID_BOUND {
    return Err(IdentifierSpaceExhausted(OBSERVATION_ID_BOUND))
  }
  let attempt = self.good_at[index] +
    self.bad_at[index] +
    self.nonconclusive_at[index] +
    1
  let observation = {
    id: self.next_id,
    index,
    probe,
    attempt,
    may_retry,
    note,
  }
  match self.accept(observation) {
    Err(error) => Err(error)
    Ok(_) => Ok(observation)
  }
}

///|
/// Same as `observe`, addressed by commit identifier.
pub fn Engine::observe_commit(
  self : Engine,
  commit_id : String,
  probe : Probe,
  may_retry~ : Bool = false,
  note~ : String = "",
) -> Result[Observation, RecordError] {
  match self.sequence.index_of(commit_id) {
    Some(index) => self.observe(index, probe, may_retry~, note~)
    None => Err(UnknownCommit(commit_id))
  }
}

///|
/// Append an observation verbatim, after checking that it is a record this
/// engine could have produced. Replay is deliberately strict:
///
/// * the identifier must be the next one in this log (dense, ordered, in range);
/// * the attempt number must equal `1 + active records at that position`;
/// * the position must exist and the evidence budget must not be exhausted.
///
/// A log that violates any rule is rejected as a whole by `Session::replay`;
/// nothing is silently repaired.
fn Engine::accept(
  self : Engine,
  observation : Observation,
) -> Result[Unit, RecordError] {
  let index = observation.index
  let length = self.sequence.length()
  if index < 0 || index >= length {
    return Err(IndexOutOfRange(index, length))
  }
  if observation.id < 0 || observation.id >= OBSERVATION_ID_BOUND {
    return Err(IdentifierSpaceExhausted(OBSERVATION_ID_BOUND))
  }
  if observation.id != self.next_id {
    return Err(NonCanonicalId(observation.id, self.next_id))
  }
  let expected = self.good_at[index] +
    self.bad_at[index] +
    self.nonconclusive_at[index] +
    1
  if observation.attempt != expected {
    return Err(NonCanonicalAttempt(observation.attempt, expected))
  }
  if self.observations.length() >= self.limits.max_observations {
    return Err(ObservationsExhausted(self.limits.max_observations))
  }
  self.observations.push(observation)
  self.active.push(true)
  match observation.verdict() {
    Good => self.good_at[index] = self.good_at[index] + 1
    Bad => self.bad_at[index] = self.bad_at[index] + 1
    Skip | Unknown => {
      self.nonconclusive_at[index] = self.nonconclusive_at[index] + 1
      if !observation.may_retry {
        self.retry_forbidden_at[index] = true
      }
    }
  }
  self.next_id = observation.id + 1
  Ok(())
}

///|
/// Append a previously recorded observation exactly as it was, preserving its
/// identifier and attempt number. This is the entry point used by session
/// replay; it validates the record instead of allocating a new identifier.
pub fn Engine::replay_observation(
  self : Engine,
  observation : Observation,
) -> Result[Unit, RecordError] {
  self.accept(observation)
}

///|
/// Void one observation. The record stays in the log with `is_active == false`;
/// nothing is overwritten, so a later replay reaches the same state.
pub fn Engine::retract(
  self : Engine,
  obs_id : Int32,
) -> Result[Unit, RetractError] {
  match self.find(obs_id) {
    None => Err(NoSuchObservation(obs_id))
    Some(slot) =>
      if !self.active[slot] {
        Err(AlreadyRetracted(obs_id))
      } else {
        self.active[slot] = false
        self.recount()
        Ok(())
      }
  }
}

///|
fn Engine::recount(self : Engine) -> Unit {
  let n = self.sequence.length()
  let mut i = 0
  while i < n {
    self.good_at[i] = 0
    self.bad_at[i] = 0
    self.nonconclusive_at[i] = 0
    self.retry_forbidden_at[i] = false
    i = i + 1
  }
  let mut j = 0
  while j < self.observations.length() {
    if self.active[j] {
      let observation = self.observations[j]
      let index = observation.index
      match observation.verdict() {
        Good => self.good_at[index] = self.good_at[index] + 1
        Bad => self.bad_at[index] = self.bad_at[index] + 1
        Skip | Unknown => {
          self.nonconclusive_at[index] = self.nonconclusive_at[index] + 1
          if !observation.may_retry {
            self.retry_forbidden_at[index] = true
          }
        }
      }
    }
    j = j + 1
  }
}

///|
/// Highest position holding an active good record, if any.
fn Engine::max_good(self : Engine, meter : Meter) -> Int32? {
  let mut best : Int32? = None
  let mut i = 0
  while i < self.good_at.length() {
    if !meter.take() {
      return best
    }
    if self.good_at[i] > 0 {
      best = Some(i)
    }
    i = i + 1
  }
  best
}

///|
/// Lowest position holding an active bad record, if any.
fn Engine::min_bad(self : Engine, meter : Meter) -> Int32? {
  let mut i = 0
  while i < self.bad_at.length() {
    if !meter.take() {
      return None
    }
    if self.bad_at[i] > 0 {
      return Some(i)
    }
    i = i + 1
  }
  None
}

///|
/// Candidate positions implied by the current boundaries, or `None` when the
/// boundaries are missing or contradictory. Empty span means contradiction.
///
/// This is a bounded `O(n)` query with no evidence search and no budget: it
/// never claims more than the current boundaries support. Use `outcome` when a
/// budgeted, complete answer is required.
pub fn Engine::candidate_span(self : Engine) -> Span? {
  // The scan must be complete, so it gets a meter that cannot run out rather
  // than the outcome budget.
  let meter = meter_new(OBSERVATION_ID_BOUND)
  let good = self.max_good(meter)
  let bad = self.min_bad(meter)
  match (good, bad) {
    (Some(g), Some(b)) =>
      if g >= b {
        None
      } else {
        Some({ lo: g + 1, hi: b, })
      }
    _ => None
  }
}

///|
/// Evaluate the evidence once and return a complete answer.
///
/// All phases of this call share one step budget. If it runs out, the answer is
/// `Budget` with the phase that was interrupted; no partial conclusion is
/// returned.
pub fn Engine::outcome(self : Engine) -> Outcome {
  let meter = meter_new(self.limits.max_steps)
  let good = self.max_good(meter)
  if meter.stopped() {
    return self.step_budget("scanning for the highest good position")
  }
  let bad = self.min_bad(meter)
  if meter.stopped() {
    return self.step_budget("scanning for the lowest bad position")
  }
  match (good, bad) {
    (None, None) =>
      Insufficient({
        missing_good: true,
        missing_bad: true,
        why: "no good and no bad endpoint recorded; the engine does not guess endpoints",
      })
    (None, Some(bad_index)) =>
      Insufficient({
        missing_good: true,
        missing_bad: false,
        why: "only bad or non-conclusive evidence so far: the lowest bad position is \{bad_index}, but nothing marks a position as still good",
      })
    (Some(good_index), None) =>
      Insufficient({
        missing_good: false,
        missing_bad: true,
        why: "only good or non-conclusive evidence so far: the highest good position is \{good_index}, but nothing marks a position as failing",
      })
    (Some(good_index), Some(bad_index)) =>
      if good_index >= bad_index {
        self.conflict(good_index, bad_index, meter)
      } else {
        self.infer(good_index, bad_index, meter)
      }
  }
}

///|
fn Engine::infer(
  self : Engine,
  good_index : Int32,
  bad_index : Int32,
  meter : Meter,
) -> Outcome {
  let span = { lo: good_index + 1, hi: bad_index, }
  if span.size() == 1 {
    let commit = self.commit_at(span.lo)
    Located({
      index: span.lo,
      commit_id: commit,
      why: "good at position \{good_index} and bad at position \{bad_index} leave exactly one compatible first-failing position",
    })
  } else {
    self.recommend(span, meter)
  }
}

///|
fn Engine::recommend(self : Engine, span : Span, meter : Meter) -> Outcome {
  let mid = span.lo + (span.hi - span.lo) / 2
  let mut distance = 0
  while distance <= span.hi - span.lo {
    let lower = mid - distance
    if lower >= span.lo {
      if !meter.take() {
        return self.step_budget(
          "scanning candidates outward from the middle of the span",
        )
      }
      if self.testable(lower) {
        return self.advice(lower, span)
      }
    }
    let upper = mid + distance
    if distance > 0 && upper <= span.hi {
      if !meter.take() {
        return self.step_budget(
          "scanning candidates outward from the middle of the span",
        )
      }
      if self.testable(upper) {
        return self.advice(upper, span)
      }
    }
    distance = distance + 1
  }
  self.ambiguous(span, meter)
}

///|
fn Engine::advice(self : Engine, index : Int32, span : Span) -> Outcome {
  NeedObservation({
    index,
    commit_id: self.commit_at(index),
    span,
    why: "position \{index} is the closest untested candidate to the middle of \{span.lo}..\{span.hi}: a good verdict raises the lower bound to \{index + 1}, a bad verdict lowers the upper bound to \{index}",
  })
}

///|
fn Engine::ambiguous(self : Engine, span : Span, meter : Meter) -> Outcome {
  let blocked : Array[BlockedNote] = []
  let mut i = span.lo
  while i <= span.hi {
    if !meter.take() {
      return self.step_budget("building the blocked-candidate explanation")
    }
    let attempts = self.nonconclusive_at[i]
    let reason = if self.bad_at[i] > 0 {
      "already recorded as bad, so the first failing position is at or before it"
    } else if self.good_at[i] > 0 {
      "already recorded as good, so the first failing position is after it"
    } else if attempts >= self.attempt_limit {
      "probed \{attempts} time(s); the per-commit attempt limit is \{self.attempt_limit}"
    } else {
      "an earlier attempt at this position forbade another one"
    }
    blocked.push({ index: i, commit_id: self.commit_at(i), reason, })
    i = i + 1
  }
  Ambiguous({
    span,
    blocked,
    why: "positions \{span.lo}..\{span.hi} are all still compatible with the evidence, but none of them can be probed again under the current retry policy",
  })
}

///|
fn Engine::step_budget(self : Engine, stage : String) -> Outcome {
  Budget({
    kind: "steps",
    limit: self.limits.max_steps,
    detail: "stopped at the step budget while \{stage}; the evidence was not evaluated to completion",
  })
}

///|
fn Engine::commit_at(self : Engine, index : Int32) -> String {
  match self.sequence.at(index) {
    Some(id) => id
    None => ""
  }
}

///|
/// A position may be probed when it has no conclusive record yet and the retry
/// policy still allows another attempt. Retry flags are maintained when records
/// are accepted or retracted, so this check examines no records itself.
fn Engine::testable(self : Engine, index : Int32) -> Bool {
  if self.good_at[index] > 0 || self.bad_at[index] > 0 {
    return false
  }
  let attempts = self.nonconclusive_at[index]
  if attempts == 0 {
    return true
  }
  if attempts >= self.attempt_limit {
    return false
  }
  !self.retry_forbidden_at[index]
}

///|
fn Engine::conflict(
  self : Engine,
  good_index : Int32,
  bad_index : Int32,
  meter : Meter,
) -> Outcome {
  let good_id = self.first_active_at(good_index, Good, meter)
  if meter.stopped() {
    return self.step_budget("locating the good record named in the conflict")
  }
  let bad_id = self.first_active_at(bad_index, Bad, meter)
  if meter.stopped() {
    return self.step_budget("locating the bad record named in the conflict")
  }
  let why = if good_index == bad_index {
    "position \{good_index} is recorded as both good and bad; the two records cannot both hold"
  } else {
    "a good record at position \{good_index} lies after a bad record at position \{bad_index}; the monotone model requires every good position to precede every bad one"
  }
  Conflict({
    good: {
      obs_id: good_id,
      index: good_index,
      commit_id: self.commit_at(good_index),
    },
    bad: {
      obs_id: bad_id,
      index: bad_index,
      commit_id: self.commit_at(bad_index),
    },
    why,
  })
}

///|
/// Identifier of the first still-active record of the given verdict at `index`.
fn Engine::first_active_at(
  self : Engine,
  index : Int32,
  want : Verdict,
  meter : Meter,
) -> Int32 {
  let mut i = 0
  while i < self.observations.length() {
    if !meter.take() {
      return -1
    }
    let observation = self.observations[i]
    if self.active[i] &&
      observation.index == index &&
      observation.verdict() == want {
      return observation.id
    }
    i = i + 1
  }
  -1
}
