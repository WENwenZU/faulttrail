///| Resolve the `--commit` value against the sequence.
///
/// Imported identifiers are long hashes, and copying 40 characters is a common
/// source of mistakes. An exact identifier is always accepted; a prefix is
/// accepted only when it matches exactly one commit, so an ambiguous prefix is
/// an error rather than a guess.

///|
pub fn resolve_commit_token(
  ids : Array[String],
  token : String,
) -> Result[String, String] {
  if token.length() == 0 {
    return Err("empty commit identifier")
  }
  for id in ids {
    if id == token {
      return Ok(id)
    }
  }
  let matches : Array[String] = []
  for id in ids {
    if id.has_prefix(token) {
      matches.push(id)
    }
  }
  if matches.length() == 1 {
    Ok(matches[0])
  } else if matches.length() == 0 {
    Err("no commit in this sequence matches '\{token}'")
  } else {
    Err(
      "'\{token}' matches \{matches.length()} commits; use a longer prefix or the full identifier",
    )
  }
}
