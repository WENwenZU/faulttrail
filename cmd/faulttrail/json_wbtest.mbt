///| The JSON rendering: one object per outcome, stable keys, escaped strings.

///|
fn session_for(ids : Array[String]) -> @session.Session {
  @session.Session::start(@version.Sequence::from_ids(ids).unwrap()).unwrap()
}

///|
test "strings are escaped without changing their meaning" {
  assert_eq(json_escape("plain"), "plain")
  assert_eq(json_escape("a\"b"), "a\\\"b")
  assert_eq(json_escape("a\\b"), "a\\\\b")
  assert_eq(json_escape("a\nb"), "a\\u000ab")
}

///|
test "a suggestion exports candidates and the next position" {
  let session = session_for(["v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7"])
  let _ = session.observe(0, @engine.Passed)
  let _ = session.observe(7, @engine.Failed)
  let json = outcome_json(session.outcome())
  assert_true(json.contains("\"outcome\":\"need-observation\""))
  assert_true(json.contains("\"candidates\":{\"lo\":1,\"hi\":7}"))
  assert_true(json.contains("\"next\":{\"index\":4"))
  assert_true(json.contains("\"commit\":\"v4\""))
}

///|
test "a localisation exports the position and commit" {
  let session = session_for(["v0", "v1", "v2"])
  let _ = session.observe(1, @engine.Passed)
  let _ = session.observe(2, @engine.Failed)
  let json = outcome_json(session.outcome())
  assert_true(json.contains("\"outcome\":\"located\""))
  assert_true(json.contains("\"index\":2"))
  assert_true(json.contains("\"commit\":\"v2\""))
}

///|
test "a conflict names both records" {
  let session = session_for(["v0", "v1", "v2", "v3", "v4", "v5"])
  let _ = session.observe(4, @engine.Passed)
  let _ = session.observe(2, @engine.Failed)
  let json = outcome_json(session.outcome())
  assert_true(json.contains("\"outcome\":\"conflict\""))
  assert_true(json.contains("\"good\":{\"observation\":0,\"index\":4"))
  assert_true(json.contains("\"bad\":{\"observation\":1,\"index\":2"))
}

///|
test "an ambiguity exports every blocked candidate" {
  let session = session_for(["v0", "v1", "v2", "v3"])
  let _ = session.observe(0, @engine.Passed)
  let _ = session.observe(3, @engine.Failed)
  let _ = session.observe(1, @engine.Skipped)
  let _ = session.observe(2, @engine.Skipped)
  let json = outcome_json(session.outcome())
  assert_true(json.contains("\"outcome\":\"ambiguous\""))
  assert_true(json.contains("\"blocked\":["))
  assert_true(json.contains("\"commit\":\"v1\""))
  assert_true(json.contains("\"commit\":\"v2\""))
  assert_true(json.contains("\"commit\":\"v3\""))
}

///|
test "insufficient and budget keep their distinguishing fields" {
  let session = session_for(["v0", "v1", "v2"])
  let _ = session.observe(0, @engine.Passed)
  let insufficient = outcome_json(session.outcome())
  assert_true(insufficient.contains("\"outcome\":\"insufficient\""))
  assert_true(insufficient.contains("\"missing_good\":false"))
  assert_true(insufficient.contains("\"missing_bad\":true"))

  let budgeted = @engine.Engine::new(
    @version.Sequence::from_ids(["v0", "v1", "v2", "v3"]).unwrap(),
    limits=@engine.Limits::new(10, 1),
  ).unwrap()
  let _ = budgeted.observe(0, @engine.Passed)
  let _ = budgeted.observe(3, @engine.Failed)
  let budget = outcome_json(budgeted.outcome())
  assert_true(budget.contains("\"outcome\":\"budget\""))
  assert_true(budget.contains("\"kind\":\"steps\""))
  assert_true(budget.contains("\"limit\":1"))
}
