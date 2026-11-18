///| Snapshot, restore and replay tests.
///
/// The claim under test is narrow and checkable: a fresh engine fed the same
/// event log produces the same candidates, the same outcome and the same next
/// suggestion; and a snapshot refuses a sequence it was not bound to.

///|
fn investigated() -> @session.Session {
  let session = @session.Session::start(seq(8)).unwrap()
  let _ = session.observe(0, @engine.Passed)
  let _ = session.observe(7, @engine.Failed)
  let _ = session.observe(3, @engine.Skipped)
  let _ = session.observe(4, @engine.Passed)
  session
}

///|
test "restore reproduces candidates, outcome and next suggestion" {
  let original = investigated()
  let snapshot = original.snapshot()
  let restored = @session.Session::restore(snapshot, seq(8)).unwrap()
  assert_eq(restored.outcome(), original.outcome())
  assert_eq(restored.candidate_span(), original.candidate_span())
  assert_eq(restored.events(), original.events())
  assert_eq(restored.attempt_limit(), original.attempt_limit())
}

///|
test "replay is deterministic and equal to restore" {
  let original = investigated()
  let events = original.events()
  let first = @session.Session::replay(seq(8), events).unwrap()
  let second = @session.Session::replay(seq(8), events).unwrap()
  assert_eq(first.outcome(), second.outcome())
  let restored = @session.Session::restore(original.snapshot(), seq(8)).unwrap()
  assert_eq(first.outcome(), restored.outcome())
}

///|
test "a snapshot bound to another sequence is refused" {
  let snapshot = investigated().snapshot()
  let other = @version.Sequence::from_ids([
    "w0", "w1", "w2", "w3", "w4", "w5", "w6", "w7",
  ]).unwrap()
  match @session.Session::restore(snapshot, other) {
    Err(@session.SequenceMismatch(_)) => ()
    _ => assert_true(false)
  }
  let shorter = @version.Sequence::from_ids(["v0", "v1", "v2"]).unwrap()
  match @session.Session::restore(snapshot, shorter) {
    Err(@session.SequenceMismatch(_)) => ()
    _ => assert_true(false)
  }
}

///|
test "a snapshot does not change when the session continues" {
  let session = investigated()
  let snapshot = session.snapshot()
  let frozen = snapshot.events().length()
  let _ = session.observe(5, @engine.Failed)
  let _ = session.observe(5, @engine.Failed)
  assert_eq(snapshot.events().length(), frozen)
  assert_eq(session.events().length(), frozen + 2)
  let restored = @session.Session::restore(snapshot, seq(8)).unwrap()
  assert_eq(restored.events().length(), frozen)
}

///|
test "the event list handed out by a session is a copy" {
  let session = investigated()
  let events = session.events()
  let length = events.length()
  events.push(@session.Retracted(0))
  assert_eq(session.events().length(), length)
}

///|
test "a retraction survives save and restore, and the record stays visible" {
  let session = @session.Session::start(seq(8)).unwrap()
  let _ = session.observe(0, @engine.Passed)
  let _ = session.observe(7, @engine.Failed)
  let narrowed = session.observe(2, @engine.Passed).unwrap()
  assert_true(retracted_ok(session.retract(narrowed.id)))
  let restored = @session.Session::restore(session.snapshot(), seq(8)).unwrap()
  assert_eq(restored.candidate_span().unwrap(), { lo: 1, hi: 7, })
  assert_eq(restored.observations().length(), 3)
  assert_true(!restored.is_active(narrowed.id))
  assert_eq(restored.events().length(), 4)
  match restored.events()[3] {
    @session.Retracted(target) => assert_eq(target, narrowed.id)
    _ => assert_true(false)
  }
}

///|
test "replay rejects a log whose positions do not exist in the sequence" {
  let forged : Array[@session.Event] = [
    @session.Recorded({
      id: 0,
      index: 99,
      probe: @engine.Failed,
      attempt: 1,
      may_retry: false,
      note: "",
    }),
  ]
  match @session.Session::replay(seq(4), forged) {
    Err(@session.ReplayRejected(event_index, _)) => assert_eq(event_index, 0)
    _ => assert_true(false)
  }
}

///|
test "restoring twice yields identical independent sessions" {
  let snapshot = investigated().snapshot()
  let first = @session.Session::restore(snapshot, seq(8)).unwrap()
  let second = @session.Session::restore(snapshot, seq(8)).unwrap()
  let _ = first.observe(5, @engine.Failed)
  assert_eq(first.events().length(), 5)
  assert_eq(second.events().length(), 4)
  assert_eq(
    second.outcome(),
    @session.Session::restore(snapshot, seq(8)).unwrap().outcome(),
  )
}
