///| Public behaviour of the session layer.

///|
fn small() -> @version.Sequence {
  @version.Sequence::from_ids(["v0", "v1", "v2"]).unwrap()
}

///|
test "observe_commit resolves an identifier to its position" {
  let session = @session.Session::start(small()).unwrap()
  let observation = session.observe_commit("v1", @engine.Failed).unwrap()
  assert_eq(observation.index, 1)
  assert_eq(session.events().length(), 1)
}

///|
test "a rejected observation leaves the log untouched" {
  let session = @session.Session::start(small()).unwrap()
  match session.observe_commit("v9", @engine.Passed) {
    Err(@engine.UnknownCommit(id)) => assert_eq(id, "v9")
    _ => assert_true(false)
  }
  match session.observe(3, @engine.Passed) {
    Err(@engine.IndexOutOfRange(3, 3)) => ()
    _ => assert_true(false)
  }
  assert_eq(session.events().length(), 0)
}

///|
test "a rejected retraction leaves the log untouched" {
  let session = @session.Session::start(small()).unwrap()
  match session.retract(7) {
    Err(@engine.NoSuchObservation(7)) => ()
    _ => assert_true(false)
  }
  assert_eq(session.events().length(), 0)
}

///|
test "notes are stored with the record and survive replay" {
  let session = @session.Session::start(small()).unwrap()
  let _ = session.observe(0, @engine.Passed, note="baseline build")
  let restored = @session.Session::restore(session.snapshot(), small()).unwrap()
  assert_eq(restored.observations()[0].note, "baseline build")
}
