///| Regression tests for defects reported against an earlier revision.
///
/// Each test states the public behaviour that was missing before, and is written
/// against the public API only, the way the reported counterexamples were.

///|
fn record(
  id : Int32,
  index : Int32,
  probe : @engine.Probe,
) -> @engine.Observation {
  { id, index, probe, attempt: 1, may_retry: false, note: "", }
}

///|
fn replay_log(
  events : Array[@session.Event],
) -> Result[@session.Session, @session.RestoreError] {
  @session.Session::replay(seq(3), events)
}

///|
/// Defect 1: a session used to hand out its internal engine, so a caller could
/// change derived state without appending an event. The query surface is now
/// read-only; mutating what it returns must not touch the session.
test "session queries return copies that cannot change the investigation" {
  let session = @session.Session::start(seq(4)).unwrap()
  let _ = session.observe(0, @engine.Passed)
  let before_span = session.candidate_span()
  let observations = session.observations()
  observations.push(record(99, 2, @engine.Failed))
  let events = session.events()
  events.push(@session.Retracted(0))
  assert_eq(session.observations().length(), 1)
  assert_eq(session.events().length(), 1)
  assert_eq(session.candidate_span(), before_span)
  assert_true(session.is_active(0))
}

///|
/// Defect 1, second half: the snapshot copied to the caller must not be a live
/// view of the session either.
test "snapshot and its accessors do not observe later records" {
  let session = @session.Session::start(seq(4)).unwrap()
  let _ = session.observe(0, @engine.Passed)
  let snapshot = session.snapshot()
  let frozen = snapshot.events()
  let _ = session.observe(3, @engine.Failed)
  let _ = session.observe(2, @engine.Passed)
  assert_eq(snapshot.events().length(), 1)
  assert_eq(frozen.length(), 1)
  assert_eq(snapshot.commit_count(), 4)
  assert_eq(snapshot.semantic_version(), @session.SEMANTIC_VERSION)
  let restored = @session.Session::restore(snapshot, seq(4)).unwrap()
  assert_eq(restored.events().length(), 1)
  assert_true(restored.outcome() is @engine.Insufficient(_))
}

///|
/// Defect 2: replay accepted a log with two records sharing id 0, after which a
/// retraction could only ever address the first one.
test "replay rejects duplicate observation identifiers" {
  let events = [
    @session.Recorded(record(0, 0, @engine.Passed)),
    @session.Recorded(record(0, 2, @engine.Failed)),
  ]
  match replay_log(events) {
    Err(@session.ReplayRejected(index, detail)) => {
      assert_eq(index, 1)
      assert_true(detail.contains("id 0"))
    }
    _ => assert_true(false)
  }
}

///|
test "replay rejects negative and out-of-order identifiers" {
  match replay_log([@session.Recorded(record(-1, 0, @engine.Passed))]) {
    Err(@session.ReplayRejected(index, _)) => assert_eq(index, 0)
    _ => assert_true(false)
  }
  let out_of_order = [
    @session.Recorded({
      id: 1,
      index: 0,
      probe: @engine.Passed,
      attempt: 1,
      may_retry: false,
      note: "",
    }),
  ]
  match replay_log(out_of_order) {
    Err(@session.ReplayRejected(index, detail)) => {
      assert_eq(index, 0)
      assert_true(detail.contains("next id"))
    }
    _ => assert_true(false)
  }
  let skipped_id = [
    @session.Recorded(record(0, 0, @engine.Passed)),
    @session.Recorded(record(2, 1, @engine.Failed)),
  ]
  match replay_log(skipped_id) {
    Err(@session.ReplayRejected(index, _)) => assert_eq(index, 1)
    _ => assert_true(false)
  }
}

///|
test "replay rejects a wrong attempt number" {
  let events = [
    @session.Recorded({
      id: 0,
      index: 0,
      probe: @engine.Passed,
      attempt: 2,
      may_retry: false,
      note: "",
    }),
  ]
  match replay_log(events) {
    Err(@session.ReplayRejected(index, detail)) => {
      assert_eq(index, 0)
      assert_true(detail.contains("attempt"))
    }
    _ => assert_true(false)
  }
  // Second attempt at the same position is numbered 2, not 1.
  let repeated = [
    @session.Recorded(record(0, 1, @engine.Skipped)),
    @session.Recorded({
      id: 1,
      index: 1,
      probe: @engine.Passed,
      attempt: 1,
      may_retry: false,
      note: "",
    }),
  ]
  match replay_log(repeated) {
    Err(@session.ReplayRejected(index, _)) => assert_eq(index, 1)
    _ => assert_true(false)
  }
}

///|
test "replay rejects identifiers outside the reserved space" {
  let events = [
    @session.Recorded({
      id: @engine.OBSERVATION_ID_BOUND,
      index: 0,
      probe: @engine.Passed,
      attempt: 1,
      may_retry: false,
      note: "",
    }),
  ]
  match replay_log(events) {
    Err(@session.ReplayRejected(index, detail)) => {
      assert_eq(index, 0)
      assert_true(detail.contains("identifier space"))
    }
    _ => assert_true(false)
  }
}

///|
test "replay rejects retractions that cannot be applied exactly once" {
  let unknown = [@session.Retracted(0)]
  match replay_log(unknown) {
    Err(@session.ReplayRejected(index, detail)) => {
      assert_eq(index, 0)
      assert_true(detail.contains("unknown observation"))
    }
    _ => assert_true(false)
  }
  let twice = [
    @session.Recorded(record(0, 0, @engine.Passed)),
    @session.Retracted(0),
    @session.Retracted(0),
  ]
  match replay_log(twice) {
    Err(@session.ReplayRejected(index, detail)) => {
      assert_eq(index, 2)
      assert_true(detail.contains("already retracted"))
    }
    _ => assert_true(false)
  }
}

///|
test "a canonical log with a retraction still replays" {
  let session = @session.Session::start(seq(3)).unwrap()
  let _ = session.observe(0, @engine.Passed)
  let _ = session.observe(2, @engine.Failed)
  let narrowed = session.observe(1, @engine.Passed).unwrap()
  let _ = session.retract(narrowed.id)
  let replayed = @session.Session::replay(seq(3), session.events()).unwrap()
  assert_eq(replayed.outcome(), session.outcome())
  assert_eq(replayed.events(), session.events())
  assert_true(!replayed.is_active(narrowed.id))
  assert_eq(replayed.events().length(), 4)
}

///|
/// Defect 3: an earlier identifier check indexed UTF-16 units and unwrapped, so
/// a supplementary-plane character panicked instead of returning an error.
test "supplementary-plane identifiers are rejected, not fatal" {
  match @version.Sequence::from_ids(["v0", "😀"]) {
    Err(@version.IdNotAscii(commit, character)) => {
      assert_eq(commit, 1)
      assert_eq(character, 0)
    }
    _ => assert_true(false)
  }
  match @version.Sequence::from_ids(["😀v0"]) {
    Err(@version.IdNotAscii(commit, character)) => {
      assert_eq(commit, 0)
      assert_eq(character, 0)
    }
    _ => assert_true(false)
  }
}

///|
/// Defect 4: the step budget did not cover the boundary scans, so a budget of
/// one step still produced `Located`. Every branch must now refuse to claim
/// completion when the budget cannot cover its work.
test "a one-step budget never reports a completed answer" {
  // Endpoint missing.
  let missing = @engine.Engine::new(seq(4), limits=@engine.Limits::new(10, 1)).unwrap()
  let _ = missing.observe(0, @engine.Passed)
  assert_true(missing.outcome() is @engine.Budget(_))
  // Unique position, the reported counterexample.
  let located = @engine.Engine::new(seq(4), limits=@engine.Limits::new(10, 1)).unwrap()
  let _ = located.observe(2, @engine.Passed)
  let _ = located.observe(3, @engine.Failed)
  match located.outcome() {
    @engine.Budget(report) => {
      assert_eq(report.kind, "steps")
      assert_eq(report.limit, 1)
    }
    _ => assert_true(false)
  }
  // Contradiction.
  let conflict = @engine.Engine::new(seq(8), limits=@engine.Limits::new(10, 1)).unwrap()
  let _ = conflict.observe(0, @engine.Passed)
  let _ = conflict.observe(2, @engine.Failed)
  let _ = conflict.observe(6, @engine.Passed)
  assert_true(conflict.outcome() is @engine.Budget(_))
  // Recommendation.
  let advice = @engine.Engine::new(seq(8), limits=@engine.Limits::new(10, 1)).unwrap()
  let _ = advice.observe(0, @engine.Passed)
  let _ = advice.observe(7, @engine.Failed)
  assert_true(advice.outcome() is @engine.Budget(_))
  // Ambiguity.
  let ambiguous = @engine.Engine::new(seq(4), limits=@engine.Limits::new(10, 1)).unwrap()
  let _ = ambiguous.observe(0, @engine.Passed)
  let _ = ambiguous.observe(3, @engine.Failed)
  let _ = ambiguous.observe(1, @engine.Skipped)
  let _ = ambiguous.observe(2, @engine.Skipped)
  assert_true(ambiguous.outcome() is @engine.Budget(_))
}

///|
test "the same evidence answers correctly once the budget covers the work" {
  let located = @engine.Engine::new(seq(4), limits=@engine.Limits::new(10, 100)).unwrap()
  let _ = located.observe(2, @engine.Passed)
  let _ = located.observe(3, @engine.Failed)
  match located.outcome() {
    @engine.Located(found) => assert_eq(found.index, 3)
    _ => assert_true(false)
  }
  let conflict = @engine.Engine::new(
    seq(8),
    limits=@engine.Limits::new(10, 100),
  ).unwrap()
  let _ = conflict.observe(0, @engine.Passed)
  let _ = conflict.observe(2, @engine.Failed)
  let _ = conflict.observe(6, @engine.Passed)
  assert_true(conflict.outcome() is @engine.Conflict(_))
  let advice = @engine.Engine::new(seq(8), limits=@engine.Limits::new(10, 100)).unwrap()
  let _ = advice.observe(0, @engine.Passed)
  let _ = advice.observe(7, @engine.Failed)
  assert_true(advice.outcome() is @engine.NeedObservation(_))
  let ambiguous = @engine.Engine::new(
    seq(4),
    limits=@engine.Limits::new(10, 100),
  ).unwrap()
  let _ = ambiguous.observe(0, @engine.Passed)
  let _ = ambiguous.observe(3, @engine.Failed)
  let _ = ambiguous.observe(1, @engine.Skipped)
  let _ = ambiguous.observe(2, @engine.Skipped)
  assert_true(ambiguous.outcome() is @engine.Ambiguous(_))
  let missing = @engine.Engine::new(seq(4), limits=@engine.Limits::new(10, 100)).unwrap()
  let _ = missing.observe(0, @engine.Passed)
  assert_true(missing.outcome() is @engine.Insufficient(_))
}

///|
/// `candidate_span` is documented as an unbudgeted, complete `O(n)` query; a
/// tiny outcome budget must not silently truncate it.
test "candidate_span stays complete under a tiny step budget" {
  let engine = @engine.Engine::new(seq(6), limits=@engine.Limits::new(10, 1)).unwrap()
  let _ = engine.observe(0, @engine.Passed)
  let _ = engine.observe(5, @engine.Failed)
  assert_eq(engine.candidate_span(), Some({ lo: 1, hi: 5, }))
}
