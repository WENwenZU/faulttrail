///| Runnable tour of the pure core on a real first-parent sequence.
///
/// The fixture is the output of
///   git log --first-parent --reverse --format="%H %s"
/// on a throwaway synthetic repository (eight first-parent commits, one merge,
/// one side branch that is deliberately absent from the first-parent line).
///
/// Usage:
///   moon run examples/first_parent -- <path-to-first-parent.txt>
/// The default path is examples/first_parent/fixture/first-parent.txt.

///|
struct Tally {
  mut passed : Int32
}

///|
fn tally_new() -> Tally {
  { passed: 0, }
}

///|
fn Tally::check(self : Tally, label : String, condition : Bool) -> Unit {
  if !condition {
    abort("check failed: \{label}")
  }
  self.passed = self.passed + 1
}

///|
fn read_text(path : String) -> String {
  @fs.read_file_to_string(path) catch {
    _ => abort("cannot read fixture: \{path}")
  }
}

///|
struct Entry {
  id : String
  label : String
}

///|
fn parse_entries(text : String) -> Array[Entry] {
  let out : Array[Entry] = []
  for raw in text.split("\n") {
    let line = raw.trim().to_owned()
    if line.length() > 0 {
      let (id, rest) = match line.split_once(" ") {
        Some(pair) => (pair.0.to_owned(), pair.1.to_owned())
        None => (line, "")
      }
      let label = match rest.split_once(":") {
        Some(pair) => pair.0.to_owned()
        None => rest
      }
      out.push({ id, label, })
    }
  }
  out
}

///|
fn span_text(span : @engine.Span) -> String {
  "\{span.lo}..\{span.hi}"
}

///|
fn describe(outcome : @engine.Outcome) -> String {
  match outcome {
    @engine.NeedObservation(advice) =>
      "NEED_OBSERVATION v\{advice.index} [\{advice.commit_id}] span=\{span_text(advice.span)}"
    @engine.Located(found) => "LOCATED v\{found.index} [\{found.commit_id}]"
    @engine.Ambiguous(report) =>
      "AMBIGUOUS span=\{span_text(report.span)} blocked=\{report.blocked.length()}"
    @engine.Conflict(report) =>
      "CONFLICT good@v\{report.good.index} vs bad@v\{report.bad.index}"
    @engine.Insufficient(report) =>
      "INSUFFICIENT missing_good=\{report.missing_good} missing_bad=\{report.missing_bad}"
    @engine.Budget(report) => "BUDGET \{report.kind} limit=\{report.limit}"
  }
}

///|
fn record(
  session : @session.Session,
  label : String,
  index : Int32,
  probe : @engine.Probe,
) -> @engine.Outcome {
  let _ = session.observe(index, probe).unwrap()
  let outcome = session.outcome()
  println("  \{label} -> \{describe(outcome)}")
  outcome
}

///|
fn main {
  let args = @env.args()
  // moon run passes the program and its script path first; the fixture path
  // follows when the caller uses the documented `-- <path>` form.
  let path = if args.length() >= 3 {
    args[2]
  } else {
    "examples/first_parent/fixture/first-parent.txt"
  }
  let entries = parse_entries(read_text(path))
  let tally = tally_new()
  println("fixture: \{entries.length()} first-parent commits")
  tally.check("fixture has eight entries", entries.length() == 8)
  for i = 0; i < entries.length(); i = i + 1 {
    println("  [\{i}] \{entries[i].label}  \{entries[i].id}")
  }
  let ids : Array[String] = []
  for i = 0; i < entries.length(); i = i + 1 {
    tally.check("label v\{i} at position \{i}", entries[i].label == "v\{i}")
    ids.push(entries[i].id)
  }
  let sequence = @version.Sequence::from_ids(ids).unwrap()
  let session = @session.Session::start(sequence).unwrap()

  println("walk:")
  let first = record(session, "record good(v0)", 0, @engine.Passed)
  tally.check(
    "one endpoint is not enough",
    match first {
      @engine.Insufficient(report) => report.missing_bad && !report.missing_good
      _ => false
    },
  )
  let second = record(session, "record bad(v7) ", 7, @engine.Failed)
  tally.check(
    "midpoint of 1..7 is 4",
    match second {
      @engine.NeedObservation(advice) =>
        advice.index == 4 && advice.span == { lo: 1, hi: 7, }
      _ => false
    },
  )
  let third = record(session, "record skip(v3)", 3, @engine.Skipped)
  tally.check(
    "a skip keeps the span and is not recommended again",
    match third {
      @engine.NeedObservation(advice) =>
        advice.span == { lo: 1, hi: 7, } && advice.index != 3
      _ => false
    },
  )
  let fourth = record(session, "record good(v4)", 4, @engine.Passed)
  tally.check(
    "a good verdict raises the lower bound",
    match fourth {
      @engine.NeedObservation(advice) => advice.span == { lo: 5, hi: 7, }
      _ => false
    },
  )
  let _ = record(session, "record bad(v6) ", 6, @engine.Failed)
  let sixth = record(session, "record bad(v5) ", 5, @engine.Failed)
  tally.check(
    "the last compatible position is v5",
    match sixth {
      @engine.Located(found) => found.index == 5 && found.commit_id == ids[5]
      _ => false
    },
  )

  let snapshot = session.snapshot()
  let restored = @session.Session::restore(snapshot, sequence).unwrap()
  tally.check(
    "restore keeps the outcome",
    restored.outcome() == session.outcome(),
  )
  tally.check("restore keeps the log", restored.events() == session.events())
  tally.check(
    "restore keeps the next suggestion",
    restored.candidate_span() == session.candidate_span(),
  )
  println(
    "replay: snapshot -> restore identical, events=\{restored.events().length()}",
  )

  let conflict_session = @session.Session::start(sequence).unwrap()
  let _ = conflict_session.observe(4, @engine.Passed)
  let _ = conflict_session.observe(2, @engine.Failed)
  let conflict = conflict_session.outcome()
  println("conflict demo: \{describe(conflict)}")
  tally.check(
    "good after bad is reported, not resolved",
    match conflict {
      @engine.Conflict(report) =>
        report.good.index == 4 && report.bad.index == 2
      _ => false
    },
  )

  match @version.Sequence::from_ids(["v0", "v0", "v2"]) {
    Err(error) => {
      println("invalid demo: \{error.message()}")
      tally.check("duplicate identifier rejected", true)
    }
    Ok(_) => tally.check("duplicate identifier rejected", false)
  }
  println("checks passed: \{tally.passed}")
}
