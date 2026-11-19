///| The shareable report: structure, redaction and replay status.

///|
fn report_session() -> @session.Session {
  let session = @session.Session::start(
    @version.Sequence::from_ids(["v0", "v1", "v2", "v3"]).unwrap(),
  ).unwrap()
  let _ = session.observe(0, @engine.Passed)
  let bad = session.observe(3, @engine.Failed).unwrap()
  let _ = session.observe(1, @engine.Skipped).unwrap()
  let _ = session.retract(bad.id)
  session
}

///|
test "a report carries the sequence, the evidence and the replay status" {
  let session = report_session()
  let text = render_report({ session, revision: 4, })
  assert_true(text.contains("# FaultTrail session report"))
  assert_true(text.contains("## Sequence"))
  assert_true(text.contains("| 0 | v0 |"))
  assert_true(text.contains("## Evidence"))
  assert_true(text.contains("| #1 | bad | 3 | v3 | 1 | retracted |"))
  assert_true(text.contains("## Result"))
  assert_true(text.contains("outcome: insufficient"))
  assert_true(text.contains("## Replay"))
  assert_true(text.contains("ok: 4 events replay to the same state"))
}

///|
test "a report contains no filesystem path" {
  let text = render_report({ session: report_session(), revision: 1, })
  assert_true(!text.contains(".session"))
  assert_true(!text.contains("C:"))
  assert_true(!text.contains("/"))
}
