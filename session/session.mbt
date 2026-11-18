///| A resumable investigation.
///
/// `Session` owns the event log and keeps a folded engine for queries. The
/// engine is never handed out: every state change goes through `observe` /
/// `retract`, which append an event first, and the read-only queries below are
/// the only way to look inside. This is what makes "the log is the source of
/// truth" true rather than aspirational.

///|
/// All state is private. In this toolchain `pub struct` alone does not hide
/// fields, so privacy is declared per field; a caller cannot reach the internal
/// engine, the event array or the sequence through the session value.
pub struct Session {
  priv sequence : @version.Sequence
  priv engine : @engine.Engine
  priv events : Array[Event]
  priv limits : @engine.Limits
  priv attempt_limit : Int32
}

///|
pub fn Session::start(
  sequence : @version.Sequence,
  limits~ : @engine.Limits = @engine.Limits::default(),
  attempt_limit~ : Int32 = 1,
) -> Result[Session, @engine.InvalidReport] {
  match @engine.Engine::new(sequence, limits~, attempt_limit~) {
    Err(report) => Err(report)
    Ok(engine) => Ok({ sequence, engine, events: [], limits, attempt_limit, })
  }
}

///|
pub fn Session::sequence(self : Session) -> @version.Sequence {
  self.sequence
}

///|
pub fn Session::limits(self : Session) -> @engine.Limits {
  self.limits
}

///|
pub fn Session::attempt_limit(self : Session) -> Int32 {
  self.attempt_limit
}

///|
/// Defensive copy of the log, in append order.
pub fn Session::events(self : Session) -> Array[Event] {
  self.events.copy()
}

///|
/// Read-only query: the candidate span implied by the recorded evidence.
/// `None` when an endpoint is missing or the evidence contradicts itself.
pub fn Session::candidate_span(self : Session) -> @engine.Span? {
  self.engine.candidate_span()
}

///|
/// Read-only query: copy of every recorded observation, including retracted
/// ones.
pub fn Session::observations(self : Session) -> Array[@engine.Observation] {
  self.engine.observations()
}

///|
/// Read-only query: whether a recorded observation is still in force.
pub fn Session::is_active(self : Session, obs_id : Int32) -> Bool {
  self.engine.is_active(obs_id)
}

///|
/// Record a probe result at `index`. The observation is appended to the log only
/// after the engine accepted it, so a rejected observation leaves no trace.
pub fn Session::observe(
  self : Session,
  index : Int32,
  probe : @engine.Probe,
  may_retry~ : Bool = false,
  note~ : String = "",
) -> Result[@engine.Observation, @engine.RecordError] {
  match self.engine.observe(index, probe, may_retry~, note~) {
    Err(error) => Err(error)
    Ok(observation) => {
      self.events.push(Recorded(observation))
      Ok(observation)
    }
  }
}

///|
pub fn Session::observe_commit(
  self : Session,
  commit_id : String,
  probe : @engine.Probe,
  may_retry~ : Bool = false,
  note~ : String = "",
) -> Result[@engine.Observation, @engine.RecordError] {
  match self.sequence.index_of(commit_id) {
    None => Err(@engine.UnknownCommit(commit_id))
    Some(index) => self.observe(index, probe, may_retry~, note~)
  }
}

///|
/// Void a recorded observation. The log gains a `Retracted` entry; the original
/// `Recorded` entry stays where it was.
pub fn Session::retract(
  self : Session,
  obs_id : Int32,
) -> Result[Unit, @engine.RetractError] {
  match self.engine.retract(obs_id) {
    Err(error) => Err(error)
    Ok(_) => {
      self.events.push(Retracted(obs_id))
      Ok(())
    }
  }
}

///|
pub fn Session::outcome(self : Session) -> @engine.Outcome {
  self.engine.outcome()
}

///|
/// Freeze the log and its binding. The returned value shares no mutable state
/// with the session: later observations do not appear in it, and the log it
/// carries is a copy.
pub fn Session::snapshot(self : Session) -> Snapshot {
  {
    semantic_version: SEMANTIC_VERSION,
    digest: self.sequence.digest(),
    commit_count: self.sequence.length(),
    attempt_limit: self.attempt_limit,
    limits: self.limits,
    events: self.events.copy(),
  }
}

///|
/// Rebuild a session from a snapshot, refusing a snapshot bound to a different
/// sequence, a different semantic version, or a log that no longer replays.
/// Nothing is applied to an existing session; the result is a new one.
pub fn Session::restore(
  snapshot : Snapshot,
  sequence : @version.Sequence,
) -> Result[Session, RestoreError] {
  if snapshot.semantic_version != SEMANTIC_VERSION {
    return Err(VersionMismatch(snapshot.semantic_version, SEMANTIC_VERSION))
  }
  if snapshot.commit_count != sequence.length() {
    return Err(
      SequenceMismatch(
        "snapshot holds \{snapshot.commit_count} commits, sequence holds \{sequence.length()}",
      ),
    )
  }
  if snapshot.digest != sequence.digest() {
    return Err(
      SequenceMismatch(
        "commit identifiers differ from the ones in the snapshot",
      ),
    )
  }
  Session::replay(
    sequence,
    snapshot.events,
    limits=snapshot.limits,
    attempt_limit=snapshot.attempt_limit,
  )
}

///|
/// Replay a log onto a sequence without checking any binding. Callers that hold
/// a snapshot should use `restore`; this entry point is for hosts that keep the
/// log themselves and already know which sequence it belongs to.
///
/// Every event is validated against the canonical log rules. The first invalid
/// event aborts the replay with its index; the partially built session is
/// discarded, so a failed replay never leaves a half-applied log behind.
pub fn Session::replay(
  sequence : @version.Sequence,
  events : Array[Event],
  limits~ : @engine.Limits = @engine.Limits::default(),
  attempt_limit~ : Int32 = 1,
) -> Result[Session, RestoreError] {
  match @engine.Engine::new(sequence, limits~, attempt_limit~) {
    Err(report) => Err(ReplayRejected(0, "\{report.code}: \{report.detail}"))
    Ok(engine) => {
      let restored = { sequence, engine, events: [], limits, attempt_limit, }
      let mut i = 0
      while i < events.length() {
        match Session::apply(restored, events[i]) {
          Err(detail) => return Err(ReplayRejected(i, detail))
          Ok(_) => ()
        }
        i = i + 1
      }
      Ok(restored)
    }
  }
}

///|
fn Session::apply(self : Session, event : Event) -> Result[Unit, String] {
  match event {
    Recorded(observation) =>
      match self.engine.replay_observation(observation) {
        Err(error) => Err(error.message())
        Ok(_) => {
          self.events.push(event)
          Ok(())
        }
      }
    Retracted(target) =>
      match self.engine.retract(target) {
        Err(error) =>
          match error {
            @engine.NoSuchObservation(id) =>
              Err("retraction targets unknown observation \{id}")
            @engine.AlreadyRetracted(id) =>
              Err("observation \{id} was already retracted")
          }
        Ok(_) => {
          self.events.push(event)
          Ok(())
        }
      }
  }
}
