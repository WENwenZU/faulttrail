///| Turn a Git first-parent listing into an investigation range.
///
/// This package is deliberately free of IO and of any Git process call: the
/// command layer asks Git for the commit identifiers, and this code decides
/// whether the two endpoints describe a usable range. That keeps the validation
/// testable on both backends, including the parts that used to be "trust the
/// tool output".

///|
/// A validated range. `ids` is oldest-first and includes both endpoints, so the
/// start commit is position 0 and the end commit is the last position.
pub(all) struct Range {
  ids : Array[String]
  from_id : String
  to_id : String
} derive(Eq, Debug)

///|
pub(all) enum ImportError {
  EmptyChain
  ToNotTip(String, String)
  FromNotOnChain(String, String)
  SingleCommit(String)
  RangeTooLong(Int32)
  BadCommitId(String)
} derive(Eq, Debug)

///|
pub fn ImportError::message(self : ImportError) -> String {
  match self {
    EmptyChain => "the repository produced no commits for this range"
    ToNotTip(head, to) =>
      "the first-parent listing starts at \{head}, not at the requested end commit \{to}"
    FromNotOnChain(from, to) =>
      "commit \{from} is not on the first-parent chain of \{to}; only mainline positions can be imported"
    SingleCommit(id) =>
      "the range holds a single commit (\{id}); a range needs at least two positions"
    RangeTooLong(limit) =>
      "the range exceeds \{limit} first-parent commits, or the start commit is older than the scanned window"
    BadCommitId(id) =>
      "the repository returned an unexpected commit identifier: \{id}"
  }
}

///|
/// A commit identifier is hex and bounded. Git uses 40 (SHA-1) or 64 (SHA-256)
/// characters; short forms are accepted only to keep the check forward
/// compatible, never as a claim that a short form is a full identifier.
pub fn looks_like_commit_id(text : String) -> Bool {
  let length = text.length()
  if length < 4 || length > 64 {
    return false
  }
  for character in text {
    let code = character.to_int()
    let hex = (code >= 48 && code <= 57) ||
      (code >= 97 && code <= 102) ||
      (code >= 65 && code <= 70)
    if !hex {
      return false
    }
  }
  true
}

///|
/// Plan a range from a newest-first first-parent listing.
///
/// `chain` must start at `to`; `from` must appear somewhere in it. The caller
/// asks Git for at most `max + 1` commits, so "not found" is reported as either
/// `RangeTooLong` (the window was full) or `FromNotOnChain` (the whole chain was
/// seen and the start commit is not on it).
pub fn plan_range(
  chain : Array[String],
  from : String,
  to : String,
  max : Int32,
) -> Result[Range, ImportError] {
  if chain.length() == 0 {
    return Err(EmptyChain)
  }
  for id in chain {
    if !looks_like_commit_id(id) {
      return Err(BadCommitId(id))
    }
  }
  if !looks_like_commit_id(from) || !looks_like_commit_id(to) {
    return Err(BadCommitId(if looks_like_commit_id(from) { to } else { from }))
  }
  if chain[0] != to {
    return Err(ToNotTip(chain[0], to))
  }
  let mut found : Int32? = None
  let mut position = 0
  while position < chain.length() {
    if chain[position] == from {
      found = Some(position)
      break
    }
    position = position + 1
  }
  let index = match found {
    Some(index) => index
    None =>
      if chain.length() > max {
        return Err(RangeTooLong(max))
      } else {
        return Err(FromNotOnChain(from, to))
      }
  }
  let length = index + 1
  if length == 1 {
    return Err(SingleCommit(from))
  }
  if length > max {
    return Err(RangeTooLong(max))
  }
  let ids : Array[String] = []
  let mut cursor = index
  while cursor >= 0 {
    ids.push(chain[cursor])
    cursor = cursor - 1
  }
  Ok({ ids, from_id: from, to_id: to, })
}
