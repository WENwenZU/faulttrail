///| Scenario tests: the contract statements from the scope document, one test
/// per statement, on sequences small enough to check by hand.

///|
test "spec walk: good(v0), bad(v7), skip(v3), good(v4), then a contradiction" {
  let session = @session.Session::start(seq(8)).unwrap()
  let _ = session.observe(0, @engine.Passed)
  match session.outcome() {
    @engine.Insufficient(report) => {
      assert_true(!report.missing_good)
      assert_true(report.missing_bad)
    }
    _ => assert_true(false)
  }
  let _ = session.observe(7, @engine.Failed)
  match session.outcome() {
    @engine.NeedObservation(advice) => {
      assert_eq(advice.index, 4)
      assert_eq(advice.span, { lo: 1, hi: 7, })
      assert_eq(advice.commit_id, "v4")
    }
    _ => assert_true(false)
  }
  let _ = session.observe(3, @engine.Skipped)
  match session.outcome() {
    @engine.NeedObservation(advice) => {
      assert_eq(advice.span, { lo: 1, hi: 7, })
      assert_true(advice.index != 3)
    }
    _ => assert_true(false)
  }
  let _ = session.observe(4, @engine.Passed)
  match session.outcome() {
    @engine.NeedObservation(advice) => {
      assert_eq(advice.span, { lo: 5, hi: 7, })
      assert_eq(advice.index, 6)
    }
    _ => assert_true(false)
  }
  let _ = session.observe(2, @engine.Failed)
  match session.outcome() {
    @engine.Conflict(report) => {
      assert_eq(report.good.index, 4)
      assert_eq(report.good.commit_id, "v4")
      assert_eq(report.bad.index, 2)
      assert_eq(report.bad.commit_id, "v2")
    }
    _ => assert_true(false)
  }
}

///|
test "skip next to the real fault leaves more than one candidate" {
  let session = @session.Session::start(seq(6)).unwrap()
  let _ = session.observe(0, @engine.Passed)
  let _ = session.observe(5, @engine.Failed)
  let _ = session.observe(3, @engine.Skipped)
  let _ = session.observe(2, @engine.Skipped)
  // Positions 1..5 are still compatible; 2 and 3 are not testable again.
  assert_eq(session.candidate_span().unwrap(), { lo: 1, hi: 5, })
  match session.outcome() {
    @engine.NeedObservation(advice) =>
      assert_true(advice.index != 2 && advice.index != 3)
    _ => assert_true(false)
  }
}

///|
test "all remaining candidates unprobeable yields ambiguity with reasons" {
  let session = @session.Session::start(seq(4)).unwrap()
  let _ = session.observe(0, @engine.Passed)
  let _ = session.observe(3, @engine.Failed)
  let _ = session.observe(1, @engine.Skipped)
  let _ = session.observe(2, @engine.Skipped)
  match session.outcome() {
    @engine.Ambiguous(report) => {
      assert_eq(report.span, { lo: 1, hi: 3, })
      assert_eq(report.blocked.length(), 3)
      assert_eq(report.blocked[0].index, 1)
      assert_eq(report.blocked[1].index, 2)
      assert_eq(report.blocked[2].index, 3)
      assert_true(report.blocked[0].reason.contains("attempt limit"))
      assert_true(report.blocked[2].reason.contains("recorded as bad"))
    }
    _ => assert_true(false)
  }
}

///|
test "repeating the same verdict is idempotent and keeps both records" {
  let once = @session.Session::start(seq(8)).unwrap()
  let _ = once.observe(0, @engine.Passed)
  let _ = once.observe(7, @engine.Failed)
  let _ = once.observe(4, @engine.Passed)
  let twice = @session.Session::start(seq(8)).unwrap()
  let _ = twice.observe(0, @engine.Passed)
  let _ = twice.observe(7, @engine.Failed)
  let _ = twice.observe(4, @engine.Passed)
  let _ = twice.observe(4, @engine.Passed)
  assert_eq(twice.candidate_span(), once.candidate_span())
  assert_eq(twice.events().length(), 4)
  assert_eq(twice.observations().length(), 4)
}

///|
test "build failures and timeouts never become a bad observation" {
  let session = @session.Session::start(seq(6)).unwrap()
  let _ = session.observe(0, @engine.Passed)
  let _ = session.observe(5, @engine.Failed)
  let failure = session.observe(4, @engine.BuildFailed).unwrap()
  let timeout = session.observe(4, @engine.TimedOut).unwrap()
  assert_eq(failure.verdict(), @engine.Skip)
  assert_eq(timeout.verdict(), @engine.Skip)
  assert_eq(session.candidate_span().unwrap(), { lo: 1, hi: 5, })
  match session.outcome() {
    @engine.Conflict(_) => assert_true(false)
    _ => assert_true(true)
  }
}

///|
test "an untestable history with no good baseline is never localised" {
  let session = @session.Session::start(seq(4)).unwrap()
  let _ = session.observe(0, @engine.Failed)
  let _ = session.observe(3, @engine.Failed)
  match session.outcome() {
    @engine.Insufficient(report) => assert_true(report.missing_good)
    _ => assert_true(false)
  }
}

///|
test "re-testing a settled position with the other verdict is a conflict, not an update" {
  let session = @session.Session::start(seq(6)).unwrap()
  let _ = session.observe(0, @engine.Passed)
  let _ = session.observe(5, @engine.Failed)
  let first = session.observe(3, @engine.Passed).unwrap()
  let second = session.observe(3, @engine.Failed).unwrap()
  match session.outcome() {
    @engine.Conflict(report) => {
      assert_eq(report.good.obs_id, first.id)
      assert_eq(report.bad.obs_id, second.id)
      assert_eq(report.good.index, report.bad.index)
    }
    _ => assert_true(false)
  }
}

///|
test "contradictory evidence is not outvoted by later agreeing records" {
  let session = @session.Session::start(seq(10)).unwrap()
  let _ = session.observe(0, @engine.Passed)
  let _ = session.observe(9, @engine.Failed)
  let late_good = session.observe(6, @engine.Passed).unwrap()
  let _ = session.observe(2, @engine.Failed)
  match session.outcome() {
    @engine.Conflict(_) => ()
    _ => assert_true(false)
  }
  // Three more records that agree with the bad side do not erase the conflict.
  let _ = session.observe(3, @engine.Failed)
  let _ = session.observe(4, @engine.Failed)
  let _ = session.observe(5, @engine.Failed)
  match session.outcome() {
    @engine.Conflict(_) => ()
    _ => assert_true(false)
  }
  // Only an explicit retraction of one record resolves it.
  assert_true(retracted_ok(session.retract(late_good.id)))
  match session.outcome() {
    @engine.NeedObservation(advice) => assert_eq(advice.span, { lo: 1, hi: 2, })
    _ => assert_true(false)
  }
}

///|
test "conflict report is stable across repeated queries" {
  let session = @session.Session::start(seq(6)).unwrap()
  let _ = session.observe(0, @engine.Passed)
  let _ = session.observe(5, @engine.Failed)
  let _ = session.observe(4, @engine.Passed)
  let _ = session.observe(1, @engine.Failed)
  let first = session.outcome()
  let second = session.outcome()
  assert_eq(first, second)
}

///|
test "retraction keeps history and reopens the candidate span" {
  let session = @session.Session::start(seq(8)).unwrap()
  let _ = session.observe(0, @engine.Passed)
  let _ = session.observe(7, @engine.Failed)
  let narrowed = session.observe(2, @engine.Passed).unwrap()
  assert_eq(session.candidate_span().unwrap(), { lo: 3, hi: 7, })
  assert_true(retracted_ok(session.retract(narrowed.id)))
  assert_eq(session.candidate_span().unwrap(), { lo: 1, hi: 7, })
  assert_eq(session.events().length(), 4)
  assert_eq(session.observations().length(), 3)
  assert_true(!session.is_active(narrowed.id))
}
