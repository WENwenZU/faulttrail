///| Redacted, shareable report for a finished or paused investigation.
///
/// The renderer never receives a file path and never reads notes: the report is
/// built from the validated session only, so a shared report cannot leak where
/// the repository or the session file lives.

///|
fn render_report(file : @sessionfile.SessionFile) -> String {
  let session = file.session
  let out = StringBuilder::StringBuilder()
  out.write_string("# FaultTrail session report\n\n")
  out.write_string(
    "format \{@sessionfile.FORMAT_VERSION}, semantic \{@session.SEMANTIC_VERSION}, revision \{file.revision}\n\n",
  )
  let records = session.observations()
  let mut active = 0
  for record in records {
    if session.is_active(record.id) {
      active = active + 1
    }
  }
  out.write_string(
    "commits: \{session.sequence().length()}; records: \{records.length()} (\{active} active)\n\n",
  )
  out.write_string("## Sequence\n\n| position | commit |\n| --- | --- |\n")
  let ids = session.sequence().ids()
  for i = 0; i < ids.length(); i = i + 1 {
    out.write_string("| \{i} | \{ids[i]} |\n")
  }
  out.write_string("\n## Evidence\n\n")
  if records.length() == 0 {
    out.write_string("No observations recorded yet.\n")
  } else {
    out.write_string(
      "| observation | verdict | position | commit | attempt | state |\n| --- | --- | --- | --- | --- | --- |\n",
    )
    for record in records {
      let commit = match session.sequence().at(record.index) {
        Some(id) => id
        None => "?"
      }
      let state = if session.is_active(record.id) {
        "active"
      } else {
        "retracted"
      }
      out.write_string(
        "| #\{record.id} | \{verdict_name(record.verdict())} | \{record.index} | \{commit} | \{record.attempt} | \{state} |\n",
      )
    }
  }
  let outcome = session.outcome()
  out.write_string("\n## Result\n\n")
  out.write_string("outcome: \{outcome_name(outcome)}\n\n")
  match session.candidate_span() {
    Some(span) => out.write_string("candidates: \{span_text(span)}\n\n")
    None =>
      out.write_string(
        "candidates: none (missing endpoint or contradictory evidence)\n\n",
      )
  }
  match outcome {
    @engine.Located(found) =>
      out.write_string(
        "located: \{found.commit_id} (position \{found.index})\n\n",
      )
    @engine.NeedObservation(advice) =>
      out.write_string(
        "next: \{advice.commit_id} (position \{advice.index})\n\n",
      )
    _ => ()
  }
  match outcome {
    @engine.NeedObservation(advice) => out.write_string("why: \{advice.why}\n")
    @engine.Located(found) => out.write_string("why: \{found.why}\n")
    @engine.Ambiguous(report) => {
      out.write_string("why: \{report.why}\n\n")
      out.write_string(
        "| blocked candidate | position | reason |\n| --- | --- | --- |\n",
      )
      for note in report.blocked {
        out.write_string(
          "| \{note.commit_id} | \{note.index} | \{note.reason} |\n",
        )
      }
    }
    @engine.Conflict(report) => {
      out.write_string("why: \{report.why}\n\n")
      out.write_string(
        "conflict: record #\{report.good.obs_id} (\{report.good.commit_id}, position \{report.good.index}) against record #\{report.bad.obs_id} (\{report.bad.commit_id}, position \{report.bad.index})\n",
      )
    }
    @engine.Insufficient(report) => out.write_string("why: \{report.why}\n")
    @engine.Budget(report) =>
      out.write_string("why: \{report.detail} (limit \{report.limit})\n")
  }
  out.write_string("\n## Replay\n\n")
  match
    @session.Session::replay(
      session.sequence(),
      session.events(),
      limits=session.limits(),
      attempt_limit=session.attempt_limit(),
    ) {
    Ok(replayed) =>
      out.write_string(
        "ok: \{replayed.events().length()} events replay to the same state (\{outcome_name(replayed.outcome())})\n",
      )
    Err(error) => out.write_string("failed: \{error.message()}\n")
  }
  out.to_string()
}
