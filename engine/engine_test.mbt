///| Public behaviour of the decision core, exercised without the session layer.

///|
fn seq(n : Int32) -> @version.Sequence {
  let ids : Array[String] = []
  for i = 0; i < n; i = i + 1 {
    ids.push("v\{i}")
  }
  @version.Sequence::from_ids(ids).unwrap()
}

///|
fn engine(n : Int32, attempt_limit~ : Int32 = 1) -> @engine.Engine {
  @engine.Engine::new(seq(n), attempt_limit~).unwrap()
}

///|
test "rejects non-positive limits instead of running unbounded" {
  match @engine.Engine::new(seq(3), limits=@engine.Limits::new(0, 10)) {
    Ok(_) => assert_true(false)
    Err(report) => assert_eq(report.code, "limits.max_observations")
  }
  match @engine.Engine::new(seq(3), limits=@engine.Limits::new(10, 0)) {
    Ok(_) => assert_true(false)
    Err(report) => assert_eq(report.code, "limits.max_steps")
  }
  match @engine.Engine::new(seq(3), attempt_limit=0) {
    Ok(_) => assert_true(false)
    Err(report) => assert_eq(report.code, "attempt_limit")
  }
}

///|
test "rejects observations outside the sequence and unknown identifiers" {
  let subject = engine(3)
  assert_true(
    subject.observe(3, @engine.Passed) is Err(@engine.IndexOutOfRange(3, 3)),
  )
  assert_true(
    subject.observe(-1, @engine.Passed) is Err(@engine.IndexOutOfRange(-1, 3)),
  )
  assert_true(
    subject.observe_commit("v9", @engine.Passed)
    is Err(@engine.UnknownCommit("v9")),
  )
  assert_eq(subject.observations().length(), 0)
}

///|
test "reports insufficient evidence instead of guessing endpoints" {
  let subject = engine(8)
  match subject.outcome() {
    Insufficient(report) => {
      assert_true(report.missing_good)
      assert_true(report.missing_bad)
    }
    _ => assert_true(false)
  }
  let _ = subject.observe(0, @engine.Passed)
  match subject.outcome() {
    Insufficient(report) => {
      assert_true(!report.missing_good)
      assert_true(report.missing_bad)
    }
    _ => assert_true(false)
  }
  let _ = subject.observe(7, @engine.Failed)
  match subject.outcome() {
    NeedObservation(advice) => assert_eq(advice.span, { lo: 1, hi: 7, })
    _ => assert_true(false)
  }
}

///|
test "locates the only compatible position" {
  let subject = engine(8)
  let _ = subject.observe(6, @engine.Passed)
  let _ = subject.observe(7, @engine.Failed)
  match subject.outcome() {
    Located(found) => {
      assert_eq(found.index, 7)
      assert_eq(found.commit_id, "v7")
    }
    _ => assert_true(false)
  }
}

///|
test "reports a conflict when a good record follows a bad one" {
  let subject = engine(8)
  let good = subject.observe(4, @engine.Passed).unwrap()
  let bad = subject.observe(2, @engine.Failed).unwrap()
  match subject.outcome() {
    Conflict(report) => {
      assert_eq(report.good.obs_id, good.id)
      assert_eq(report.good.index, 4)
      assert_eq(report.bad.obs_id, bad.id)
      assert_eq(report.bad.index, 2)
    }
    _ => assert_true(false)
  }
}

///|
test "the same position cannot be good and bad at once" {
  let subject = engine(4)
  let first = subject.observe(2, @engine.Failed).unwrap()
  let second = subject.observe(2, @engine.Passed).unwrap()
  match subject.outcome() {
    Conflict(report) => {
      assert_eq(report.bad.obs_id, first.id)
      assert_eq(report.good.obs_id, second.id)
      assert_eq(report.good.index, report.bad.index)
    }
    _ => assert_true(false)
  }
}

///|
test "skip and unknown do not narrow the boundary" {
  let subject = engine(8)
  let _ = subject.observe(0, @engine.Passed)
  let _ = subject.observe(7, @engine.Failed)
  let before = subject.candidate_span().unwrap()
  let _ = subject.observe(3, @engine.Skipped)
  let _ = subject.observe(5, @engine.Undetermined)
  assert_eq(subject.candidate_span().unwrap(), before)
  assert_eq(before, { lo: 1, hi: 7, })
}

///|
test "a build failure is not recorded as a bad observation" {
  let subject = engine(6)
  let record = subject.observe(3, @engine.BuildFailed).unwrap()
  assert_eq(record.verdict(), @engine.Skip)
  let _ = subject.observe(0, @engine.Passed)
  let _ = subject.observe(5, @engine.Failed)
  assert_eq(subject.candidate_span().unwrap(), { lo: 1, hi: 5, })
}

///|
test "a skipped position is not offered again under the default policy" {
  let subject = engine(8)
  let _ = subject.observe(0, @engine.Passed)
  let _ = subject.observe(7, @engine.Failed)
  let first = match subject.outcome() {
    NeedObservation(advice) => advice.index
    _ => -1
  }
  assert_eq(first, 4)
  let _ = subject.observe(first, @engine.Skipped)
  match subject.outcome() {
    NeedObservation(advice) => assert_true(advice.index != first)
    _ => assert_true(false)
  }
}

///|
test "retry policy is explicit: allowed retries stay available up to the limit" {
  let subject = engine(8, attempt_limit=2)
  let _ = subject.observe(0, @engine.Passed)
  let _ = subject.observe(7, @engine.Failed)
  let _ = subject.observe(4, @engine.Skipped, may_retry=true)
  match subject.outcome() {
    NeedObservation(advice) => assert_eq(advice.index, 4)
    _ => assert_true(false)
  }
  let _ = subject.observe(4, @engine.TimedOut, may_retry=true)
  match subject.outcome() {
    NeedObservation(advice) => assert_true(advice.index != 4)
    _ => assert_true(false)
  }
}

///|
test "retraction keeps the record and widens the candidate set again" {
  let subject = engine(8)
  let _ = subject.observe(0, @engine.Passed)
  let _ = subject.observe(7, @engine.Failed)
  let verdict = subject.observe(5, @engine.Passed).unwrap()
  assert_eq(subject.candidate_span().unwrap(), { lo: 6, hi: 7, })
  assert_true(subject.retract(verdict.id) is Ok(_))
  assert_eq(subject.candidate_span().unwrap(), { lo: 1, hi: 7, })
  assert_eq(subject.observations().length(), 3)
  assert_true(!subject.is_active(verdict.id))
  match subject.retract(verdict.id) {
    Err(@engine.AlreadyRetracted(id)) => assert_eq(id, verdict.id)
    _ => assert_true(false)
  }
  assert_true(subject.retract(99) is Err(@engine.NoSuchObservation(99)))
}

///|
test "exposes a copy of the observation log" {
  let subject = engine(4)
  let _ = subject.observe(0, @engine.Passed)
  let log = subject.observations()
  log.push({
    id: 42,
    index: 1,
    probe: @engine.Failed,
    attempt: 1,
    may_retry: false,
    note: "",
  })
  assert_eq(subject.observations().length(), 1)
}
