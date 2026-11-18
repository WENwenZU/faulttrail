///| Human-readable rendering of engine outcomes and session state.
///
/// The output is deliberately line-oriented and stable: one fact per line, no
/// decoration that a diff would trip over. Free text comes from the engine and
/// never contains operator-supplied notes (the CLI does not store notes).

///|
fn verdict_name(verdict : @engine.Verdict) -> String {
  match verdict {
    @engine.Good => "good"
    @engine.Bad => "bad"
    @engine.Skip => "skip"
    @engine.Unknown => "unknown"
  }
}

///|
fn outcome_name(outcome : @engine.Outcome) -> String {
  match outcome {
    @engine.NeedObservation(_) => "need-observation"
    @engine.Located(_) => "located"
    @engine.Ambiguous(_) => "ambiguous"
    @engine.Conflict(_) => "conflict"
    @engine.Insufficient(_) => "insufficient"
    @engine.Budget(_) => "budget"
  }
}

///|
/// Exit code for a `next` query: only a suggestion or a localisation counts as
/// a normal completion.
fn outcome_exit(outcome : @engine.Outcome) -> Int32 {
  match outcome {
    @engine.NeedObservation(_) | @engine.Located(_) => EXIT_OK
    @engine.Insufficient(_) => EXIT_INSUFFICIENT
    @engine.Ambiguous(_) => EXIT_AMBIGUOUS
    @engine.Conflict(_) => EXIT_CONFLICT
    @engine.Budget(_) => EXIT_BUDGET
  }
}

///|
fn span_text(span : @engine.Span) -> String {
  "\{span.lo}..\{span.hi}"
}

///|
/// Print the actionable part of an outcome.
fn print_outcome(outcome : @engine.Outcome) -> Unit {
  match outcome {
    @engine.NeedObservation(advice) => {
      println("next: \{advice.commit_id} (position \{advice.index})")
      println("candidates: \{span_text(advice.span)}")
      println("why: \{advice.why}")
    }
    @engine.Located(found) => {
      println("located: \{found.commit_id} (position \{found.index})")
      println("why: \{found.why}")
    }
    @engine.Insufficient(report) => {
      let mut missing = ""
      if report.missing_good {
        missing = "good"
      }
      if report.missing_bad {
        missing = if missing == "" { "bad" } else { "\{missing}, bad" }
      }
      println("no next step: insufficient evidence (missing \{missing})")
      println("why: \{report.why}")
    }
    @engine.Ambiguous(report) => {
      println("no next step: ambiguous candidates \{span_text(report.span)}")
      for note in report.blocked {
        println(
          "  blocked \{note.commit_id} (position \{note.index}): \{note.reason}",
        )
      }
      println("why: \{report.why}")
    }
    @engine.Conflict(report) => {
      println(
        "no next step: conflict between record #\{report.good.obs_id} (\{report.good.commit_id}) and record #\{report.bad.obs_id} (\{report.bad.commit_id})",
      )
      println("why: \{report.why}")
    }
    @engine.Budget(report) => {
      println(
        "no next step: budget exhausted (\{report.kind} limit \{report.limit})",
      )
      println("detail: \{report.detail}")
    }
  }
}

///|
fn print_sequence(session : @session.Session) -> Unit {
  let ids = session.sequence().ids()
  println("sequence: \{ids.length()} commits")
  if ids.length() <= 32 {
    for i = 0; i < ids.length(); i = i + 1 {
      println("  [\{i}] \{ids[i]}")
    }
  } else {
    for i = 0; i < 16; i = i + 1 {
      println("  [\{i}] \{ids[i]}")
    }
    println("  ...")
    for i = ids.length() - 16; i < ids.length(); i = i + 1 {
      println("  [\{i}] \{ids[i]}")
    }
  }
}

///|
/// Full state dump used by `explain`.
fn print_state(path : String, file : @sessionfile.SessionFile) -> Unit {
  let session = file.session
  println(
    "session: \{path} (revision \{file.revision}, semantic \{@session.SEMANTIC_VERSION}, format \{@sessionfile.FORMAT_VERSION})",
  )
  print_sequence(session)
  let records = session.observations()
  let mut active = 0
  for record in records {
    if session.is_active(record.id) {
      active = active + 1
    }
  }
  println("records: \{records.length()} (\{active} active)")
  for record in records {
    let state = if session.is_active(record.id) { "" } else { " (retracted)" }
    let commit = match session.sequence().at(record.index) {
      Some(id) => id
      None => "?"
    }
    println(
      "  #\{record.id} \{verdict_name(record.verdict())} \{commit} position \{record.index} attempt \{record.attempt}\{state}",
    )
  }
  match session.candidate_span() {
    Some(span) => println("candidates: \{span_text(span)}")
    None =>
      println("candidates: none (missing endpoint or contradictory evidence)")
  }
  let outcome = session.outcome()
  println("outcome: \{outcome_name(outcome)}")
  print_outcome(outcome)
}
