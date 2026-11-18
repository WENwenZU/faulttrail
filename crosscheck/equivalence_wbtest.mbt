///| Systematic comparison against the brute-force reference model.
///
/// The reference model enumerates every possible first-failing position and
/// checks each observation against it. For every evidence pattern over a short
/// sequence, the engine must produce the same candidate set, the same
/// classification and the same next position.

///|
fn decode(base5_index : Int32, n : Int32) -> Array[Int32] {
  let codes : Array[Int32] = Array::make(n, 0)
  let mut rest = base5_index
  for i = 0; i < n; i = i + 1 {
    codes[i] = rest % 5 - 1
    rest = rest / 5
  }
  codes
}

///|
test "exhaustive evidence patterns over 1..4 commits agree with the reference" {
  let mut cases = 0
  for n = 1; n <= 4; n = n + 1 {
    let total = int_pow(5, n)
    for pattern = 0; pattern < total; pattern = pattern + 1 {
      let codes = decode(pattern, n)
      let session = build(codes)
      let refs = ref_obs_of(session)
      let expected = @reference.ref_verdict(n, refs, 1)
      assert_eq(as_ref(session.outcome()), Some(expected))
      let compatible = @reference.compatible_positions(n, refs)
      match expected {
        @reference.NoBounds(_, _) =>
          assert_true(session.candidate_span() is None)
        @reference.Contradiction => {
          assert_eq(compatible.length(), 0)
          assert_true(session.candidate_span() is None)
        }
        _ =>
          assert_eq(
            span_positions(session.candidate_span().unwrap()),
            compatible,
          )
      }
      cases = cases + 1
    }
  }
  assert_eq(cases, 780)
}

///|
test "the exhaustive corpus actually reaches every outcome class" {
  let mut need_observation = 0
  let mut located = 0
  let mut ambiguous = 0
  let mut conflict = 0
  let mut insufficient = 0
  for n = 1; n <= 4; n = n + 1 {
    let total = int_pow(5, n)
    for pattern = 0; pattern < total; pattern = pattern + 1 {
      let session = build(decode(pattern, n))
      match session.outcome() {
        @engine.NeedObservation(_) => need_observation = need_observation + 1
        @engine.Located(_) => located = located + 1
        @engine.Ambiguous(_) => ambiguous = ambiguous + 1
        @engine.Conflict(_) => conflict = conflict + 1
        @engine.Insufficient(_) => insufficient = insufficient + 1
        @engine.Budget(_) => ()
      }
    }
  }
  assert_true(need_observation > 0)
  assert_true(located > 0)
  assert_true(ambiguous > 0)
  assert_true(conflict > 0)
  assert_true(insufficient > 0)
}

///|
/// A recommendation must sit inside the candidate span, and both possible
/// verdicts at that position must strictly shrink the span: a good verdict
/// raises the lower bound, a bad verdict lowers the upper bound.
test "every recommendation is inside the span and informative in both branches" {
  for n = 2; n <= 4; n = n + 1 {
    let total = int_pow(5, n)
    for pattern = 0; pattern < total; pattern = pattern + 1 {
      let codes = decode(pattern, n)
      match build(codes).outcome() {
        @engine.NeedObservation(advice) => {
          assert_true(advice.span.contains(advice.index))
          let good_branch = build(codes)
          let _ = good_branch.observe(advice.index, @engine.Passed).unwrap()
          match good_branch.candidate_span() {
            Some(span) => assert_true(span.lo > advice.span.lo)
            None => assert_true(false)
          }
          let bad_branch = build(codes)
          let _ = bad_branch.observe(advice.index, @engine.Failed).unwrap()
          match bad_branch.candidate_span() {
            Some(span) => assert_true(span.hi < advice.span.hi)
            None => assert_true(false)
          }
        }
        _ => ()
      }
    }
  }
}

///|
/// Deterministic linear congruential generator; no external dependency and the
/// same corpus on every machine.
struct Rng {
  mut state : Int32
}

///|
fn rng_new(seed : Int32) -> Rng {
  { state: seed, }
}

///|
fn Rng::next(self : Rng) -> Int32 {
  self.state = (self.state * 1103515245 + 12345) & 0x3fffffff
  self.state
}

///|
test "randomised evidence patterns over 5..13 commits agree with the reference" {
  let rng = rng_new(20261117)
  for round = 0; round < 400; round = round + 1 {
    let n = 5 + rng.next() % 9
    let codes : Array[Int32] = Array::make(n, -1)
    let mut anything = false
    for i = 0; i < n; i = i + 1 {
      let draw = rng.next() % 5
      if draw > 0 {
        codes[i] = draw - 1
        anything = true
      }
    }
    if anything {
      let session = build(codes)
      let refs = ref_obs_of(session)
      let expected = @reference.ref_verdict(n, refs, 1)
      assert_eq(as_ref(session.outcome()), Some(expected))
      match expected {
        @reference.NoBounds(_, _) | @reference.Contradiction => ()
        _ =>
          assert_eq(
            span_positions(session.candidate_span().unwrap()),
            @reference.compatible_positions(n, refs),
          )
      }
    }
  }
}

///|
/// How a walk ended. Only a terminal answer counts as a finished walk; a loop
/// that merely stopped is a failure, not a pass.
priv enum WalkEnd {
  FoundAt(Int32)
  StoppedAmbiguous(@engine.Span)
  Unexpected
}

///|
/// Walk a synthetic history with a known first-bad position.
///
/// Fully observable walk: every group must end at `Located(k)` with the true k.
/// Walk with skipped positions: every group must end at `Located(k)` or at an
/// ambiguity whose span still contains k. Conflict, budget and a loop that only
/// ran out of rounds are failures, not silent exits.
test "truth walk ends at the real position, or at an ambiguity containing it" {
  let rng = rng_new(7)
  let mut located_groups = 0
  for n = 2; n <= 12; n = n + 1 {
    for truth = 1; truth < n; truth = truth + 1 {
      let session = @session.Session::start(seq(n)).unwrap()
      let mut rounds = 0
      let mut end : WalkEnd = Unexpected
      while rounds < 4 * n {
        let terminal = match end {
          FoundAt(_) | StoppedAmbiguous(_) => true
          Unexpected => false
        }
        if terminal {
          break
        }
        rounds = rounds + 1
        match session.outcome() {
          @engine.Insufficient(_) => {
            // Seed the two endpoints a real investigation starts from.
            let _ = session.observe(0, @engine.Passed)
            let _ = session.observe(n - 1, @engine.Failed)
          }
          @engine.NeedObservation(advice) => {
            let probe = if advice.index >= truth {
              @engine.Failed
            } else {
              @engine.Passed
            }
            let _ = session.observe(advice.index, probe)
          }
          @engine.Located(found) => end = FoundAt(found.index)
          @engine.Ambiguous(report) => end = StoppedAmbiguous(report.span)
          @engine.Conflict(_) => end = Unexpected
          @engine.Budget(_) => end = Unexpected
        }
      }
      match end {
        FoundAt(index) => {
          assert_eq(index, truth)
          located_groups = located_groups + 1
        }
        StoppedAmbiguous(_) => assert_true(false)
        Unexpected => assert_true(false)
      }
      assert_true(rounds < 4 * n)
    }
  }
  assert_true(located_groups > 0)

  let mut settled_groups = 0
  for n = 2; n <= 10; n = n + 1 {
    for truth = 1; truth < n; truth = truth + 1 {
      let session = @session.Session::start(seq(n)).unwrap()
      let _ = session.observe(0, @engine.Passed)
      let _ = session.observe(n - 1, @engine.Failed)
      let mut rounds = 0
      let mut end : WalkEnd = Unexpected
      while rounds < 4 * n {
        let terminal = match end {
          FoundAt(_) | StoppedAmbiguous(_) => true
          Unexpected => false
        }
        if terminal {
          break
        }
        rounds = rounds + 1
        match session.outcome() {
          @engine.NeedObservation(advice) => {
            let draw = rng.next() % 3
            if draw == 0 {
              let _ = session.observe(advice.index, @engine.Skipped)
            } else if advice.index >= truth {
              let _ = session.observe(advice.index, @engine.Failed)
            } else {
              let _ = session.observe(advice.index, @engine.Passed)
            }
          }
          @engine.Located(found) => end = FoundAt(found.index)
          @engine.Ambiguous(report) => end = StoppedAmbiguous(report.span)
          @engine.Conflict(_) => end = Unexpected
          @engine.Budget(_) => end = Unexpected
          @engine.Insufficient(_) => end = Unexpected
        }
      }
      match end {
        FoundAt(index) => assert_eq(index, truth)
        StoppedAmbiguous(span) => assert_true(span.contains(truth))
        Unexpected => assert_true(false)
      }
      assert_true(rounds < 4 * n)
      settled_groups = settled_groups + 1
    }
  }
  assert_true(settled_groups > 0)
}
