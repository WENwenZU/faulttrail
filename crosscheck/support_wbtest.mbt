///| Helpers shared by the cross-check tests.
///
/// The reference observations are rebuilt from the session's public event log,
/// not from engine internals, and probe results are mapped to reference codes
/// here rather than through the engine's own classification.

///|
fn seq(n : Int32) -> @version.Sequence {
  let ids : Array[String] = []
  for i = 0; i < n; i = i + 1 {
    ids.push("v\{i}")
  }
  @version.Sequence::from_ids(ids).unwrap()
}

///|
fn probe_of(code : Int32) -> @engine.Probe {
  match code {
    0 => @engine.Passed
    1 => @engine.Failed
    2 => @engine.Skipped
    _ => @engine.Undetermined
  }
}

///|
fn probe_code(probe : @engine.Probe) -> Int32 {
  match probe {
    @engine.Passed => 0
    @engine.Failed => 1
    @engine.BuildFailed | @engine.TimedOut | @engine.Skipped => 2
    @engine.Undetermined => 3
  }
}

///|
fn span_positions(span : @engine.Span) -> Array[Int32] {
  let out : Array[Int32] = []
  for i = span.lo; i <= span.hi; i = i + 1 {
    out.push(i)
  }
  out
}

///|
fn ref_obs_of(session : @session.Session) -> Array[@reference.RefObs] {
  let events = session.events()
  let result : Array[@reference.RefObs] = []
  let ids : Array[Int32] = []
  for i = 0; i < events.length(); i = i + 1 {
    match events[i] {
      @session.Recorded(observation) => {
        result.push({
          index: observation.index,
          verdict: probe_code(observation.probe),
          may_retry: observation.may_retry,
          active: true,
        })
        ids.push(observation.id)
      }
      @session.Retracted(_) => ()
    }
  }
  for i = 0; i < events.length(); i = i + 1 {
    match events[i] {
      @session.Retracted(target) =>
        for j = 0; j < ids.length(); j = j + 1 {
          if ids[j] == target {
            result[j].active = false
          }
        }
      @session.Recorded(_) => ()
    }
  }
  result
}

///|
fn as_ref(outcome : @engine.Outcome) -> @reference.RefVerdict? {
  match outcome {
    @engine.Insufficient(report) =>
      Some(@reference.NoBounds(report.missing_good, report.missing_bad))
    @engine.Conflict(_) => Some(@reference.Contradiction)
    @engine.Located(found) => Some(@reference.Unique(found.index))
    @engine.NeedObservation(advice) => Some(@reference.Next(advice.index))
    @engine.Ambiguous(report) =>
      Some(@reference.Stuck(span_positions(report.span)))
    @engine.Budget(_) => None
  }
}

///|
/// Build a session from verdict codes: -1 unobserved, 0 good, 1 bad, 2 skip,
/// 3 unknown.
fn build(codes : Array[Int32], attempt_limit~ : Int32 = 1) -> @session.Session {
  let session = @session.Session::start(seq(codes.length()), attempt_limit~).unwrap()
  for i = 0; i < codes.length(); i = i + 1 {
    if codes[i] >= 0 {
      let _ = session.observe(i, probe_of(codes[i])).unwrap()
    }
  }
  session
}

///|
fn int_pow(base : Int32, exponent : Int32) -> Int32 {
  let mut value = 1
  let mut i = 0
  while i < exponent {
    value = value * base
    i = i + 1
  }
  value
}

///|
fn retracted_ok(result : Result[Unit, @engine.RetractError]) -> Bool {
  match result {
    Ok(_) => true
    Err(_) => false
  }
}
