///| Independent reference model for the inference rules.
///
/// This package answers the same questions as the engine by brute force and by
/// a deliberate restatement of the contract:
/// * enumerate every possible first-failing position `0 .. n-1`;
/// * drop the ones a recorded good or bad observation rules out;
/// * classify what is left.
///
/// It imports nothing from the engine, shares no type with it, and never calls
/// its candidate or selection functions, so agreement between the two is
/// evidence about the rules rather than about a shared implementation.

///|
/// Plain observation, indexed by position. `verdict` uses the wire codes below
/// so that this package cannot accidentally depend on engine enums.
pub(all) struct RefObs {
  index : Int32
  verdict : Int32 // 0 good, 1 bad, 2 skip, 3 unknown
  may_retry : Bool
  mut active : Bool
} derive(Eq, Debug)

///|
pub fn verdict_code_is_conclusive(code : Int32) -> Bool {
  code == 0 || code == 1
}

///|
/// Every position that could be the first failing one, ascending.
pub fn compatible_positions(n : Int32, obs : Array[RefObs]) -> Array[Int32] {
  let out : Array[Int32] = []
  for k = 0; k < n; k = k + 1 {
    let mut ok = true
    for j = 0; j < obs.length(); j = j + 1 {
      let item = obs[j]
      if item.active {
        if item.verdict == 0 && item.index >= k {
          ok = false
        }
        if item.verdict == 1 && item.index < k {
          ok = false
        }
      }
    }
    if ok {
      out.push(k)
    }
  }
  out
}

///|
/// What the reference model concludes from the same observations.
pub(all) enum RefVerdict {
  NoBounds(Bool, Bool) // missing_good, missing_bad
  Contradiction
  Unique(Int32)
  Next(Int32)
  Stuck(Array[Int32])
} derive(Eq, Debug)

///|
pub fn ref_verdict(
  n : Int32,
  obs : Array[RefObs],
  attempt_limit : Int32,
) -> RefVerdict {
  let mut has_good = false
  let mut has_bad = false
  for j = 0; j < obs.length(); j = j + 1 {
    let item = obs[j]
    if item.active {
      if item.verdict == 0 {
        has_good = true
      }
      if item.verdict == 1 {
        has_bad = true
      }
    }
  }
  if !has_good || !has_bad {
    return NoBounds(!has_good, !has_bad)
  }
  let candidates = compatible_positions(n, obs)
  if candidates.length() == 0 {
    return Contradiction
  }
  if candidates.length() == 1 {
    return Unique(candidates[0])
  }
  let lo = candidates[0]
  let hi = candidates[candidates.length() - 1]
  let mid = lo + (hi - lo) / 2
  let mut distance = 0
  while distance <= hi - lo {
    let lower = mid - distance
    if lower >= lo && ref_testable(lower, obs, attempt_limit) {
      return Next(lower)
    }
    let upper = mid + distance
    if distance > 0 && upper <= hi && ref_testable(upper, obs, attempt_limit) {
      return Next(upper)
    }
    distance = distance + 1
  }
  Stuck(candidates)
}

///|
fn ref_testable(
  index : Int32,
  obs : Array[RefObs],
  attempt_limit : Int32,
) -> Bool {
  let mut attempts = 0
  let mut forbidden = false
  for j = 0; j < obs.length(); j = j + 1 {
    let item = obs[j]
    if item.active && item.index == index {
      // A position already settled by a good or bad record is not worth probing
      // again: it cannot move the boundary, and re-testing it is the caller's
      // decision, not a suggestion of this model.
      if verdict_code_is_conclusive(item.verdict) {
        return false
      }
      attempts = attempts + 1
      if !item.may_retry {
        forbidden = true
      }
    }
  }
  if attempts == 0 {
    return true
  }
  if attempts >= attempt_limit {
    return false
  }
  !forbidden
}
