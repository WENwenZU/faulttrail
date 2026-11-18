///| A linear, oldest-first sequence of opaque commit identifiers.
///
/// The decision core only reasons about positions, so a sequence has to
/// guarantee three things: order, uniqueness, and a digest a saved session can
/// be bound to. The constructor below is the only place where those guarantees
/// are established; every other operation is read-only, and the fields are
/// private to this package so no caller can reopen them.

///|
/// Reasons a list of identifiers cannot be used as a commit sequence.
pub(all) enum SeqError {
  EmptySequence
  LimitNotPositive(Int32)
  TooLong(Int32, Int32)
  BlankId(Int32)
  IdHasControl(Int32, Int32)
  IdNotAscii(Int32, Int32)
  DuplicateId(Int32, Int32)
} derive(Eq, Debug)

///|
pub fn SeqError::message(self : SeqError) -> String {
  match self {
    EmptySequence => "the sequence is empty"
    LimitNotPositive(limit) => "max_commits must be positive, got \{limit}"
    TooLong(limit, actual) =>
      "sequence has \{actual} commits, above the limit of \{limit}"
    BlankId(commit) => "the identifier at commit index \{commit} is empty"
    IdHasControl(commit, character) =>
      "the identifier at commit index \{commit} contains whitespace or a control character at character \{character}"
    IdNotAscii(commit, character) =>
      "the identifier at commit index \{commit} contains a non-ASCII character at character \{character} (printable ASCII 0x21..0x7e required)"
    DuplicateId(first, second) =>
      "the identifier at commit index \{second} duplicates commit index \{first}"
  }
}

///|
/// Internal classification of the first offending character of an identifier.
priv enum IdProblem {
  Control(Int32)
  NotAscii(Int32)
}

///|
/// The only way to obtain a `Sequence` is through `from_ids`, so an instance
/// always carries unique, non-blank, printable-ASCII identifiers in
/// caller-supplied order.
pub struct Sequence {
  priv ids : Array[String]
  priv positions : Map[String, Int32]
}

///|
/// Build a sequence from identifiers listed oldest first.
///
/// Identifiers are deliberately restricted to printable ASCII (0x21..0x7e).
/// They are opaque labels, not necessarily real object names: `v0` is as valid
/// as a full commit hash. The restriction keeps the digest definition, the log
/// encoding and the error reporting identical on every backend, and it removes
/// the whole class of surrogate-pair and normalisation edge cases.
///
/// The length limit is checked before the index map is allocated, so an
/// oversized input costs one bounds comparison, not a second array.
pub fn Sequence::from_ids(
  ids : Array[String],
  max_commits~ : Int32 = 10000,
) -> Result[Sequence, SeqError] {
  if max_commits <= 0 {
    return Err(LimitNotPositive(max_commits))
  }
  let n = ids.length()
  if n == 0 {
    return Err(EmptySequence)
  }
  if n > max_commits {
    return Err(TooLong(max_commits, n))
  }
  let positions : Map[String, Int32] = Map([])
  let mut i = 0
  while i < n {
    let id = ids[i]
    if id.length() == 0 {
      return Err(BlankId(i))
    }
    match id_problem(id) {
      Some(Control(at)) => return Err(IdHasControl(i, at))
      Some(NotAscii(at)) => return Err(IdNotAscii(i, at))
      None => ()
    }
    match positions.get(id) {
      Some(first) => return Err(DuplicateId(first, i))
      None => positions.set(id, i)
    }
    i = i + 1
  }
  Ok({ ids: ids.copy(), positions, })
}

///|
/// Iterates by Unicode scalar value rather than by code unit, so a
/// supplementary-plane character is classified instead of panicking on an
/// unmatched surrogate.
fn id_problem(id : String) -> IdProblem? {
  let mut position = 0
  for character in id {
    let code = character.to_int()
    if code <= 32 || code == 127 {
      return Some(Control(position))
    }
    if code > 126 {
      return Some(NotAscii(position))
    }
    position = position + 1
  }
  None
}

///|
pub fn Sequence::length(self : Sequence) -> Int32 {
  self.ids.length()
}

///|
/// Identifier at `index`, or `None` outside `0 .. length-1`.
pub fn Sequence::at(self : Sequence, index : Int32) -> String? {
  if index < 0 || index >= self.ids.length() {
    None
  } else {
    Some(self.ids[index])
  }
}

///|
/// Position of `id`, or `None` when the identifier is not in this sequence.
pub fn Sequence::index_of(self : Sequence, id : String) -> Int32? {
  self.positions.get(id)
}

///|
/// Defensive copy of the identifiers. The internal array is private, so this is
/// the only way to read them in bulk.
pub fn Sequence::ids(self : Sequence) -> Array[String] {
  self.ids.copy()
}

///|
/// Binding digest used by snapshots. FNV-1a (64-bit) over the UTF-8 bytes of
/// every identifier, each terminated by byte `0x1f`. Since identifiers are
/// printable ASCII, the byte sequence is unambiguous. It detects a snapshot
/// restored against a different sequence; it is not a cryptographic digest.
pub fn Sequence::digest(self : Sequence) -> String {
  let mut hash : Int64 = -3750763034362895579L
  let mut i = 0
  while i < self.ids.length() {
    let bytes = @utf8.encode(self.ids[i])
    let mut j = 0
    while j < bytes.length() {
      hash = (hash ^ bytes[j].to_int().to_int64()) * 1099511628211L
      j = j + 1
    }
    hash = (hash ^ 31L) * 1099511628211L
    i = i + 1
  }
  hex16(hash)
}

///|
fn hex16(value : Int64) -> String {
  let digits = "0123456789abcdef"
  let mut out = ""
  let mut shift = 15
  while shift >= 0 {
    let nibble = ((value >> (shift * 4)) & 15L).to_int()
    out = out + digits[nibble:nibble + 1].to_owned()
    shift = shift - 1
  }
  out
}
