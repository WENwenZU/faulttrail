///| On-disk session format: parsing, validation and serialization.
///
/// The file is deliberately a strict, line-oriented text format. Anything the
/// core would not have produced is rejected with a typed error and the position
/// of the offending line or event; nothing is repaired, coerced or migrated.
/// The format is versioned separately from the inference rules, and a file from
/// another version is refused rather than relabelled.
///
/// Layout (fixed order, one blank-line-tolerant record per line):
///
/// ```
/// faulttrail-session 1
/// semantic 1
/// revision 3
/// attempt-limit 1
/// limits 10000 1000000
/// sequence 8
/// commit v0
/// ... one commit line per sequence entry ...
/// digest 35a9865ac75c01d6
/// events 4
/// record 0 0 passed 1 0
/// record 1 7 failed 1 0
/// retract 2
/// end
/// ```
///
/// `record` fields are: observation id, commit position, probe token, attempt,
/// may-retry (0/1). `retract` names the observation id to void. Free-text notes
/// are not part of this format, so a saved session cannot leak operator notes.

///|
pub const FORMAT_VERSION : Int32 = 1

///|
/// Application-level read limits. They bound what this repository is willing to
/// parse; they are not a claim about the host's memory.
pub const MAX_FILE_BYTES : Int32 = 4194304

///|
pub const MAX_LINES : Int32 = 200000

///|
pub const MAX_SEQUENCE : Int32 = 10000

///|
pub const MAX_EVENTS : Int32 = 10000

///|
pub const MAX_ATTEMPT_LIMIT : Int32 = 1000

///|
pub const MAX_OBSERVATIONS_LIMIT : Int32 = 100000

///|
pub const MAX_STEPS_LIMIT : Int32 = 100000000

///|
/// Revision numbers are compared for staleness and incremented on save; this
/// bound keeps the next value parseable by the same contract.
pub const MAX_REVISION : Int32 = 1000000000

///|
/// A session as stored on disk: the folded session plus its save revision.
pub(all) struct SessionFile {
  session : @session.Session
  revision : Int32
}

///|
pub(all) enum FileError {
  TooLarge(Int32, Int32)
  TooManyLines(Int32, Int32)
  BadHeader(String)
  UnsupportedFormat(Int32)
  UnsupportedSemantic(Int32)
  MissingLine(String)
  BadField(String, String)
  BadNumber(String, String)
  BadProbe(String)
  SequenceRejected(String)
  DigestMismatch(String, String)
  MissingEnd
  TrailingLine(String)
  ReplayRejected(Int32, String)
} derive(Eq, Debug)

///|
pub fn FileError::message(self : FileError) -> String {
  match self {
    TooLarge(size, limit) =>
      "session file is \{size} bytes, above the application limit of \{limit}"
    TooManyLines(count, limit) =>
      "session file has \{count} lines, above the application limit of \{limit}"
    BadHeader(line) => "unexpected header line: \{line}"
    UnsupportedFormat(version) =>
      "unsupported session format version \{version}; this build reads \{FORMAT_VERSION}"
    UnsupportedSemantic(version) =>
      "unsupported semantic version \{version}; this build implements \{@session.SEMANTIC_VERSION} and does not relabel older sessions"
    MissingLine(kind) => "the file ends before the \{kind} line"
    BadField(field, value) => "field \{field} has an unexpected value: \{value}"
    BadNumber(field, value) =>
      "field \{field} is not a bounded integer: \{value}"
    BadProbe(token) => "unknown probe token: \{token}"
    SequenceRejected(detail) => "commit list rejected: \{detail}"
    DigestMismatch(found, expected) =>
      "sequence digest \{found} does not match the commit list (expected \{expected})"
    MissingEnd => "missing end marker; the file is truncated"
    TrailingLine(line) => "unexpected content after the end marker: \{line}"
    ReplayRejected(index, detail) =>
      "event \{index} is not a canonical record: \{detail}"
  }
}

///|
fn probe_token(probe : @engine.Probe) -> String {
  match probe {
    @engine.Passed => "passed"
    @engine.Failed => "failed"
    @engine.BuildFailed => "build-failed"
    @engine.TimedOut => "timed-out"
    @engine.Skipped => "skipped"
    @engine.Undetermined => "undetermined"
  }
}

///|
pub fn probe_from_token(token : String) -> @engine.Probe? {
  match token {
    "passed" => Some(@engine.Passed)
    "failed" => Some(@engine.Failed)
    "build-failed" => Some(@engine.BuildFailed)
    "timed-out" => Some(@engine.TimedOut)
    "skipped" => Some(@engine.Skipped)
    "undetermined" => Some(@engine.Undetermined)
    _ => None
  }
}

///|
/// Serialize a session. `revision` is the revision the new file will carry; the
/// caller is responsible for having checked the on-disk revision first.
pub fn encode(session : @session.Session, revision : Int32) -> String {
  let out = StringBuilder::StringBuilder()
  out.write_string("faulttrail-session \{FORMAT_VERSION}\n")
  out.write_string("semantic \{@session.SEMANTIC_VERSION}\n")
  out.write_string("revision \{revision}\n")
  out.write_string("attempt-limit \{session.attempt_limit()}\n")
  let limits = session.limits()
  out.write_string("limits \{limits.max_observations} \{limits.max_steps}\n")
  let ids = session.sequence().ids()
  out.write_string("sequence \{ids.length()}\n")
  for id in ids {
    out.write_string("commit \{id}\n")
  }
  out.write_string("digest \{session.sequence().digest()}\n")
  let events = session.events()
  out.write_string("events \{events.length()}\n")
  for event in events {
    match event {
      @session.Recorded(observation) =>
        out.write_string(
          "record \{observation.id} \{observation.index} \{probe_token(observation.probe)} \{observation.attempt} \{if observation.may_retry { 1 } else { 0 }}\n",
        )
      @session.Retracted(target) => out.write_string("retract \{target}\n")
    }
  }
  out.write_string("end\n")
  out.to_string()
}

///|

///|
/// Remove one trailing carriage return without indexing by code unit: a line
/// that ends with a supplementary-plane character must be classified by the
/// parser, not crash here.
fn strip_trailing_cr(text : String) -> String {
  match text.rev_find("\r") {
    Some(index) =>
      if index == text.length() - 1 {
        text[:index].to_owned()
      } else {
        text
      }
    None => text
  }
}

///|
fn clean_lines(text : String) -> Array[String] {
  let out : Array[String] = []
  for raw in text.split("\n") {
    let line = strip_trailing_cr(raw.to_owned())
    if line.length() > 0 {
      out.push(line)
    }
  }
  out
}

///|
/// Parse a bounded decimal integer from untrusted text.
///
/// The accumulator is 64-bit and the bound is checked before narrowing, so a
/// value like 4294967297 is rejected instead of wrapping into a small valid
/// number. Iteration is by Unicode scalar value: an emoji anywhere in the token
/// is a format error, never a crash and never a panic on a surrogate.
pub fn parse_bounded_int(
  text : String,
  field : String,
) -> Result[Int32, FileError] {
  if text.length() == 0 || text.length() > 12 {
    return Err(BadNumber(field, text))
  }
  let mut first = true
  let mut sign = 1
  let mut seen_digit = false
  let mut value : Int64 = 0L
  for character in text {
    let code = character.to_int()
    if first && code == 45 {
      sign = -1
    } else if code >= 48 && code <= 57 {
      value = value * 10L + (code - 48).to_int64()
      if value > 1000000000L {
        return Err(BadNumber(field, text))
      }
      seen_digit = true
    } else {
      return Err(BadNumber(field, text))
    }
    first = false
  }
  if !seen_digit {
    return Err(BadNumber(field, text))
  }
  Ok(sign * value.to_int())
}

///|
fn tokens_of(line : String) -> Array[String] {
  let out : Array[String] = []
  for token in line.split(" ") {
    out.push(token.to_owned())
  }
  out
}

///|
fn line_at(
  lines : Array[String],
  index : Int32,
  kind : String,
) -> Result[String, FileError] {
  if index < 0 || index >= lines.length() {
    Err(MissingLine(kind))
  } else {
    Ok(lines[index])
  }
}

///|
/// Parse and validate a session file. Every check is applied before the session
/// is returned; a rejected file never yields a partially loaded session.
pub fn decode(text : String) -> Result[SessionFile, FileError] {
  if text.length() > MAX_FILE_BYTES {
    return Err(TooLarge(text.length(), MAX_FILE_BYTES))
  }
  let lines = clean_lines(text)
  if lines.length() > MAX_LINES {
    return Err(TooManyLines(lines.length(), MAX_LINES))
  }
  let mut at = 0
  // Header.
  let header = match line_at(lines, at, "faulttrail-session") {
    Ok(line) => line
    Err(error) => return Err(error)
  }
  let header_tokens = tokens_of(header)
  if header_tokens.length() != 2 || header_tokens[0] != "faulttrail-session" {
    return Err(BadHeader(header))
  }
  let format = match parse_bounded_int(header_tokens[1], "faulttrail-session") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if format != FORMAT_VERSION {
    return Err(UnsupportedFormat(format))
  }
  at = at + 1
  // Semantic version of the inference rules.
  let semantic_line = match line_at(lines, at, "semantic") {
    Ok(line) => line
    Err(error) => return Err(error)
  }
  let semantic_tokens = tokens_of(semantic_line)
  if semantic_tokens.length() != 2 || semantic_tokens[0] != "semantic" {
    return Err(BadField("semantic", semantic_line))
  }
  let semantic = match parse_bounded_int(semantic_tokens[1], "semantic") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if semantic != @session.SEMANTIC_VERSION {
    return Err(UnsupportedSemantic(semantic))
  }
  at = at + 1
  // Revision.
  let revision_line = match line_at(lines, at, "revision") {
    Ok(line) => line
    Err(error) => return Err(error)
  }
  let revision_tokens = tokens_of(revision_line)
  if revision_tokens.length() != 2 || revision_tokens[0] != "revision" {
    return Err(BadField("revision", revision_line))
  }
  let revision = match parse_bounded_int(revision_tokens[1], "revision") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if revision < 1 || revision > MAX_REVISION {
    return Err(BadField("revision", revision_line))
  }
  at = at + 1
  // Attempt limit.
  let attempt_line = match line_at(lines, at, "attempt-limit") {
    Ok(line) => line
    Err(error) => return Err(error)
  }
  let attempt_tokens = tokens_of(attempt_line)
  if attempt_tokens.length() != 2 || attempt_tokens[0] != "attempt-limit" {
    return Err(BadField("attempt-limit", attempt_line))
  }
  let attempt_limit = match
    parse_bounded_int(attempt_tokens[1], "attempt-limit") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if attempt_limit < 1 || attempt_limit > MAX_ATTEMPT_LIMIT {
    return Err(BadField("attempt-limit", attempt_line))
  }
  at = at + 1
  // Limits.
  let limits_line = match line_at(lines, at, "limits") {
    Ok(line) => line
    Err(error) => return Err(error)
  }
  let limits_tokens = tokens_of(limits_line)
  if limits_tokens.length() != 3 || limits_tokens[0] != "limits" {
    return Err(BadField("limits", limits_line))
  }
  let max_observations = match parse_bounded_int(limits_tokens[1], "limits") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let max_steps = match parse_bounded_int(limits_tokens[2], "limits") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if max_observations < 1 ||
    max_observations > MAX_OBSERVATIONS_LIMIT ||
    max_steps < 1 ||
    max_steps > MAX_STEPS_LIMIT {
    return Err(BadField("limits", limits_line))
  }
  let limits = @engine.Limits::new(max_observations, max_steps)
  at = at + 1
  // Sequence.
  let sequence_line = match line_at(lines, at, "sequence") {
    Ok(line) => line
    Err(error) => return Err(error)
  }
  let sequence_tokens = tokens_of(sequence_line)
  if sequence_tokens.length() != 2 || sequence_tokens[0] != "sequence" {
    return Err(BadField("sequence", sequence_line))
  }
  let count = match parse_bounded_int(sequence_tokens[1], "sequence") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if count < 1 || count > MAX_SEQUENCE {
    return Err(BadField("sequence", sequence_line))
  }
  at = at + 1
  let ids : Array[String] = []
  let mut commit_index = 0
  while commit_index < count {
    let commit_line = match line_at(lines, at, "commit") {
      Ok(line) => line
      Err(error) => return Err(error)
    }
    let commit_tokens = tokens_of(commit_line)
    if commit_tokens.length() != 2 || commit_tokens[0] != "commit" {
      return Err(BadField("commit", commit_line))
    }
    ids.push(commit_tokens[1])
    at = at + 1
    commit_index = commit_index + 1
  }
  let sequence = match
    @version.Sequence::from_ids(ids, max_commits=MAX_SEQUENCE) {
    Ok(sequence) => sequence
    Err(error) => return Err(SequenceRejected(error.message()))
  }
  // Digest.
  let digest_line = match line_at(lines, at, "digest") {
    Ok(line) => line
    Err(error) => return Err(error)
  }
  let digest_tokens = tokens_of(digest_line)
  if digest_tokens.length() != 2 || digest_tokens[0] != "digest" {
    return Err(BadField("digest", digest_line))
  }
  let expected_digest = sequence.digest()
  if digest_tokens[1] != expected_digest {
    return Err(DigestMismatch(digest_tokens[1], expected_digest))
  }
  at = at + 1
  // Events.
  let events_line = match line_at(lines, at, "events") {
    Ok(line) => line
    Err(error) => return Err(error)
  }
  let events_tokens = tokens_of(events_line)
  if events_tokens.length() != 2 || events_tokens[0] != "events" {
    return Err(BadField("events", events_line))
  }
  let event_count = match parse_bounded_int(events_tokens[1], "events") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if event_count < 0 || event_count > MAX_EVENTS {
    return Err(BadField("events", events_line))
  }
  at = at + 1
  let events : Array[@session.Event] = []
  let mut record_count = 0
  let mut event_index = 0
  while event_index < event_count {
    let event_line = match line_at(lines, at, "event") {
      Ok(line) => line
      Err(error) => return Err(error)
    }
    let parts = tokens_of(event_line)
    if parts.length() == 0 {
      return Err(BadField("event", event_line))
    }
    if parts[0] == "record" {
      if parts.length() != 6 {
        return Err(BadField("record", event_line))
      }
      record_count = record_count + 1
      let id = match parse_bounded_int(parts[1], "record.id") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let index = match parse_bounded_int(parts[2], "record.position") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let probe = match probe_from_token(parts[3]) {
        Some(probe) => probe
        None => return Err(BadProbe(parts[3]))
      }
      let attempt = match parse_bounded_int(parts[4], "record.attempt") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if parts[5] != "0" && parts[5] != "1" {
        return Err(BadField("record.may-retry", parts[5]))
      }
      events.push(
        @session.Recorded({
          id,
          index,
          probe,
          attempt,
          may_retry: parts[5] == "1",
          note: "",
        }),
      )
    } else if parts[0] == "retract" {
      if parts.length() != 2 {
        return Err(BadField("retract", event_line))
      }
      let target = match parse_bounded_int(parts[1], "retract.target") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      events.push(@session.Retracted(target))
    } else {
      return Err(BadField("event", event_line))
    }
    at = at + 1
    event_index = event_index + 1
  }
  // The observation budget bounds records, not retractions: a successful
  // investigation may legitimately carry more events than observations.
  if record_count > max_observations {
    return Err(
      BadField(
        "events", "more observation records than the observation limit allows",
      ),
    )
  }
  // End marker and no trailing content.
  if at >= lines.length() || lines[at] != "end" {
    return Err(MissingEnd)
  }
  at = at + 1
  if at < lines.length() {
    return Err(TrailingLine(lines[at]))
  }
  // Replay validates identifiers and attempts against the sequence.
  match @session.Session::replay(sequence, events, limits~, attempt_limit~) {
    Ok(session) => Ok({ session, revision, })
    Err(@session.ReplayRejected(index, detail)) =>
      Err(ReplayRejected(index, detail))
    Err(@session.VersionMismatch(_, _)) =>
      Err(BadField("semantic", "replay refused this semantic version"))
    Err(@session.SequenceMismatch(detail)) => Err(SequenceRejected(detail))
  }
}
