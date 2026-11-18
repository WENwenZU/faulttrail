///| Budget tests: every limit is checked before the work it bounds, and hitting
/// one produces an unfinished status rather than a localisation.

///|
test "sequence length is rejected before the index map is built" {
  let ids : Array[String] = ["v0", "v1", "v2", "v3", "v4"]
  match @version.Sequence::from_ids(ids, max_commits=4) {
    Err(@version.TooLong(limit, actual)) => {
      assert_eq(limit, 4)
      assert_eq(actual, 5)
    }
    _ => assert_true(false)
  }
  match @version.Sequence::from_ids(ids, max_commits=0) {
    Err(@version.LimitNotPositive(0)) => ()
    _ => assert_true(false)
  }
}

///|
test "observation budget rejects the next record and logs nothing" {
  let session = @session.Session::start(
    seq(8),
    limits=@engine.Limits::new(2, 1000),
  ).unwrap()
  let _ = session.observe(0, @engine.Passed)
  let _ = session.observe(7, @engine.Failed)
  match session.observe(4, @engine.Passed) {
    Err(@engine.ObservationsExhausted(limit)) => assert_eq(limit, 2)
    _ => assert_true(false)
  }
  assert_eq(session.events().length(), 2)
  assert_eq(session.observations().length(), 2)
}

///|
test "step budget stops the scan and is reported as unfinished" {
  let session = @session.Session::start(
    seq(9),
    limits=@engine.Limits::new(100, 3),
  ).unwrap()
  let _ = session.observe(0, @engine.Passed)
  let _ = session.observe(8, @engine.Failed)
  for i = 1; i <= 7; i = i + 1 {
    let _ = session.observe(i, @engine.Skipped)
  }
  match session.outcome() {
    @engine.Budget(report) => {
      assert_eq(report.kind, "steps")
      assert_eq(report.limit, 3)
    }
    _ => assert_true(false)
  }
  // The same evidence under a larger budget is an ambiguity, not a location.
  let generous = @session.Session::start(
    seq(9),
    limits=@engine.Limits::new(100, 1000),
  ).unwrap()
  let _ = generous.observe(0, @engine.Passed)
  let _ = generous.observe(8, @engine.Failed)
  for i = 1; i <= 7; i = i + 1 {
    let _ = generous.observe(i, @engine.Skipped)
  }
  match generous.outcome() {
    @engine.Ambiguous(report) => assert_eq(report.span, { lo: 1, hi: 8, })
    _ => assert_true(false)
  }
}

///|
test "an invalid budget is rejected when the session starts" {
  match @session.Session::start(seq(4), limits=@engine.Limits::new(-1, 100)) {
    Err(report) => assert_eq(report.code, "limits.max_observations")
    Ok(_) => assert_true(false)
  }
  match @session.Session::start(seq(4), limits=@engine.Limits::new(100, 0)) {
    Err(report) => assert_eq(report.code, "limits.max_steps")
    Ok(_) => assert_true(false)
  }
}
