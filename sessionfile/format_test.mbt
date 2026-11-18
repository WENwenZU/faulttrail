///| Format contract tests: a saved session must round-trip, and every malformed
/// file must be refused with the error that names the actual problem.

///|
fn sample() -> @session.Session {
  let sequence = @version.Sequence::from_ids(["v0", "v1", "v2", "v3"]).unwrap()
  let session = @session.Session::start(sequence).unwrap()
  let _ = session.observe(0, @engine.Passed)
  let _ = session.observe(3, @engine.Failed)
  let _ = session.observe(2, @engine.Skipped)
  session
}

///|
fn build_text(
  ids : Array[String],
  events : Array[String],
  format~ : Int32 = 1,
  semantic~ : Int32 = 1,
  revision~ : Int32 = 1,
  digest~ : String = "",
  end_marker~ : String = "end",
  trailing~ : String = "",
  attempt~ : Int32 = 1,
  limits_text~ : String = "1000 1000000",
) -> String {
  let computed = match @version.Sequence::from_ids(ids) {
    Ok(sequence) => sequence.digest()
    Err(_) => "0000000000000000"
  }
  let out = StringBuilder::StringBuilder()
  out.write_string("faulttrail-session \{format}\n")
  out.write_string("semantic \{semantic}\n")
  out.write_string("revision \{revision}\n")
  out.write_string("attempt-limit \{attempt}\n")
  out.write_string("limits \{limits_text}\n")
  out.write_string("sequence \{ids.length()}\n")
  for id in ids {
    out.write_string("commit \{id}\n")
  }
  let digest_text = if digest == "" { computed } else { digest }
  out.write_string("digest \{digest_text}\n")
  out.write_string("events \{events.length()}\n")
  for event in events {
    out.write_string("\{event}\n")
  }
  out.write_string("\{end_marker}\n")
  out.write_string(trailing)
  out.to_string()
}

///|
test "a saved session round-trips with its revision, events and outcome" {
  let session = sample()
  let text = @sessionfile.encode(session, 3)
  let loaded = @sessionfile.decode(text).unwrap()
  assert_eq(loaded.revision, 3)
  assert_eq(loaded.session.events(), session.events())
  assert_eq(loaded.session.outcome(), session.outcome())
  assert_eq(loaded.session.candidate_span(), session.candidate_span())
  assert_eq(loaded.session.sequence().ids(), session.sequence().ids())
  assert_eq(loaded.session.attempt_limit(), session.attempt_limit())
  assert_eq(loaded.session.limits(), session.limits())
}

///|
test "the file carries no free-text notes" {
  let sequence = @version.Sequence::from_ids(["v0", "v1"]).unwrap()
  let session = @session.Session::start(sequence).unwrap()
  let _ = session.observe(0, @engine.Passed, note="operator note")
  let text = @sessionfile.encode(session, 1)
  assert_true(!text.contains("operator note"))
  assert_true(!text.contains("note"))
}

///|
test "CRLF line endings are accepted" {
  let ids = ["v0", "v1"]
  let events = ["record 0 0 passed 1 0"]
  let unix = build_text(ids, events)
  let windows = build_text(ids, events)
  let out = StringBuilder::StringBuilder()
  for line in windows.split("\n") {
    if line.length() > 0 {
      out.write_string("\{line.to_owned()}\r\n")
    }
  }
  let loaded = @sessionfile.decode(out.to_string()).unwrap()
  assert_eq(loaded.session.events().length(), 1)
  // The same file without CRLF must behave identically.
  assert_eq(
    @sessionfile.decode(unix).unwrap().session.events(),
    loaded.session.events(),
  )
}

///|
test "an unsupported format version is refused, not migrated" {
  let text = build_text(["v0", "v1"], [], format=2)
  match @sessionfile.decode(text) {
    Err(@sessionfile.UnsupportedFormat(version)) => assert_eq(version, 2)
    _ => assert_true(false)
  }
}

///|
test "an unsupported semantic version is refused, not relabelled" {
  let text = build_text(["v0", "v1"], [], semantic=2)
  match @sessionfile.decode(text) {
    Err(@sessionfile.UnsupportedSemantic(version)) => assert_eq(version, 2)
    _ => assert_true(false)
  }
}

///|
test "a digest that does not match the commit list is refused" {
  let text = build_text(["v0", "v1"], [], digest="0000000000000000")
  match @sessionfile.decode(text) {
    Err(@sessionfile.DigestMismatch(_, expected)) =>
      assert_eq(expected.length(), 16)
    _ => assert_true(false)
  }
}

///|
test "a commit list that is invalid on its own is refused" {
  let duplicate = "faulttrail-session 1\nsemantic 1\nrevision 1\nattempt-limit 1\nlimits 1000 1000000\nsequence 2\ncommit v0\ncommit v0\ndigest 0000000000000000\nevents 0\nend\n"
  match @sessionfile.decode(duplicate) {
    Err(@sessionfile.SequenceRejected(detail)) =>
      assert_true(detail.contains("duplicates"))
    _ => assert_true(false)
  }
}

///|
test "duplicate observation identifiers are refused during replay" {
  let events = ["record 0 0 passed 1 0", "record 0 1 failed 1 0"]
  let text = build_text(["v0", "v1"], events)
  match @sessionfile.decode(text) {
    Err(@sessionfile.ReplayRejected(index, _)) => assert_eq(index, 1)
    _ => assert_true(false)
  }
}

///|
test "negative and non-canonical event identifiers are refused" {
  let negative = build_text(["v0", "v1"], ["record -1 0 passed 1 0"])
  match @sessionfile.decode(negative) {
    Err(@sessionfile.ReplayRejected(index, _)) => assert_eq(index, 0)
    _ => assert_true(false)
  }
  let skipped = build_text(["v0", "v1"], [
    "record 0 0 passed 1 0", "record 2 1 failed 1 0",
  ])
  match @sessionfile.decode(skipped) {
    Err(@sessionfile.ReplayRejected(index, _)) => assert_eq(index, 1)
    _ => assert_true(false)
  }
  let wrong_attempt = build_text(["v0", "v1"], ["record 0 0 skipped 2 0"])
  match @sessionfile.decode(wrong_attempt) {
    Err(@sessionfile.ReplayRejected(index, _)) => assert_eq(index, 0)
    _ => assert_true(false)
  }
}

///|
test "a truncated file is reported as missing its end marker" {
  let text = build_text(["v0", "v1"], [], end_marker="")
  match @sessionfile.decode(text) {
    Err(@sessionfile.MissingEnd) => ()
    _ => assert_true(false)
  }
}

///|
test "content after the end marker is refused" {
  let text = build_text(["v0", "v1"], [], trailing="record 0 0 passed 1 0\n")
  match @sessionfile.decode(text) {
    Err(@sessionfile.TrailingLine(_)) => ()
    _ => assert_true(false)
  }
}

///|
test "unknown probe tokens and event kinds are refused" {
  let bad_probe = build_text(["v0", "v1"], ["record 0 0 maybe 1 0"])
  match @sessionfile.decode(bad_probe) {
    Err(@sessionfile.BadProbe(token)) => assert_eq(token, "maybe")
    _ => assert_true(false)
  }
  let bad_kind = build_text(["v0", "v1"], ["annotate 0 0 passed 1 0"])
  match @sessionfile.decode(bad_kind) {
    Err(@sessionfile.BadField(field, _)) => assert_eq(field, "event")
    _ => assert_true(false)
  }
}

///|
test "declared counts above the application limits are refused" {
  let huge_sequence = "faulttrail-session 1\nsemantic 1\nrevision 1\nattempt-limit 1\nlimits 1000 1000000\nsequence 999999\nend\n"
  match @sessionfile.decode(huge_sequence) {
    Err(@sessionfile.BadField(field, _)) => assert_eq(field, "sequence")
    _ => assert_true(false)
  }
  let one = @version.Sequence::from_ids(["v0"]).unwrap()
  let huge_events = "faulttrail-session 1\nsemantic 1\nrevision 1\nattempt-limit 1\nlimits 1000 1000000\nsequence 1\ncommit v0\ndigest \{one.digest()}\nevents 999999\nend\n"
  match @sessionfile.decode(huge_events) {
    Err(@sessionfile.BadField(field, _)) => assert_eq(field, "events")
    _ => assert_true(false)
  }
}

///|
test "an invalid revision and invalid limits are refused" {
  let zero_revision = build_text(["v0", "v1"], [], revision=0)
  match @sessionfile.decode(zero_revision) {
    Err(@sessionfile.BadField(field, _)) => assert_eq(field, "revision")
    _ => assert_true(false)
  }
  let text = "faulttrail-session 1\nsemantic 1\nrevision 1\nattempt-limit 1\nlimits 0 1000\nsequence 1\ncommit v0\ndigest 0000000000000000\nevents 0\nend\n"
  match @sessionfile.decode(text) {
    Err(@sessionfile.BadField(field, _)) => assert_eq(field, "limits")
    _ => assert_true(false)
  }
}

///|
test "a wrong header is refused before anything else is interpreted" {
  let text = "faulttrail 1\nsemantic 1\n"
  match @sessionfile.decode(text) {
    Err(@sessionfile.BadHeader(_)) => ()
    _ => assert_true(false)
  }
}

///|
/// A reported counterexample: two observations reached the limit, then one was
/// retracted. The file carries three events but only two records, and it must
/// still load.
test "a retraction may push the event count past the observation limit" {
  let sequence = @version.Sequence::from_ids(["v0", "v1", "v2"]).unwrap()
  let session = @session.Session::start(
    sequence,
    limits=@engine.Limits::new(2, 1000),
  ).unwrap()
  let first = session.observe(0, @engine.Passed).unwrap()
  let _ = session.observe(2, @engine.Failed)
  match session.retract(first.id) {
    Ok(_) => ()
    Err(_) => assert_true(false)
  }
  assert_eq(session.events().length(), 3)
  let text = @sessionfile.encode(session, 1)
  let loaded = @sessionfile.decode(text).unwrap()
  assert_eq(loaded.session.events().length(), 3)
  assert_eq(loaded.session.outcome(), session.outcome())
}

///|
test "more records than the observation limit are refused" {
  let text = build_text(
    ["v0", "v1"],
    ["record 0 0 passed 1 0", "record 1 1 failed 1 0"],
    limits_text="1 1000000",
  )
  match @sessionfile.decode(text) {
    Err(@sessionfile.BadField(field, _)) => assert_eq(field, "events")
    _ => assert_true(false)
  }
}

///|
test "an attempt limit above the file bound is refused" {
  let text = build_text(["v0", "v1"], [], attempt=1001)
  match @sessionfile.decode(text) {
    Err(@sessionfile.BadField(field, _)) => assert_eq(field, "attempt-limit")
    _ => assert_true(false)
  }
}

///|
test "bounded integers reject values that would wrap" {
  assert_true(
    match @sessionfile.parse_bounded_int("1000000000", "x") {
      Ok(value) => value == 1000000000
      Err(_) => false
    },
  )
  for
    text in [
      "1000000001", "2147483648", "4294967296", "4294967297", "99999999999999999999",
    ] {
    match @sessionfile.parse_bounded_int(text, "x") {
      Ok(_) => assert_true(false)
      Err(_) => assert_true(true)
    }
  }
  match @sessionfile.parse_bounded_int("-1", "x") {
    Ok(value) => assert_eq(value, -1)
    Err(_) => assert_true(false)
  }
  for text in ["-", "12a", "+1", " 1", "1😀", "😀", ""] {
    match @sessionfile.parse_bounded_int(text, "x") {
      Ok(_) => assert_true(false)
      Err(_) => assert_true(true)
    }
  }
}

///|
test "a supplementary character in a commit line is refused, not fatal" {
  let text = build_text(["v0", "😀"], [])
  match @sessionfile.decode(text) {
    Err(@sessionfile.SequenceRejected(detail)) =>
      assert_true(detail.contains("non-ASCII"))
    _ => assert_true(false)
  }
  // The same line ending in CRLF exercises the line stripper.
  let out = StringBuilder::StringBuilder()
  for line in text.split("\n") {
    if line.length() > 0 {
      out.write_string("\{line.to_owned()}\r\n")
    }
  }
  match @sessionfile.decode(out.to_string()) {
    Err(@sessionfile.SequenceRejected(_)) => ()
    _ => assert_true(false)
  }
}

///|
test "an emoji in a numeric field is a format error, not a crash" {
  let one = @version.Sequence::from_ids(["v0"]).unwrap()
  let text = "faulttrail-session 1\nsemantic 1\nrevision 1😀\nattempt-limit 1\nlimits 1000 1000000\nsequence 1\ncommit v0\ndigest \{one.digest()}\nevents 0\nend\n"
  match @sessionfile.decode(text) {
    Err(@sessionfile.BadNumber(field, _)) => assert_eq(field, "revision")
    _ => assert_true(false)
  }
}

///|
test "an emoji in an event flag is refused with the field name" {
  let text = build_text(["v0"], ["record 0 0 passed 1 0😀"])
  match @sessionfile.decode(text) {
    Err(@sessionfile.BadField(field, _)) => assert_eq(field, "record.may-retry")
    _ => assert_true(false)
  }
}
