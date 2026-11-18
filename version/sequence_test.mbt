///| Behaviour of the sequence constructor and its binding digest.

///|
test "rejects an empty sequence" {
  let result = @version.Sequence::from_ids([])
  assert_true(result is Err(@version.EmptySequence))
}

///|
test "rejects duplicate identifiers and reports both positions" {
  let result = @version.Sequence::from_ids(["v0", "v1", "v0"])
  assert_true(result is Err(@version.DuplicateId(0, 2)))
}

///|
test "rejects blank and control-bearing identifiers" {
  assert_true(
    @version.Sequence::from_ids(["v0", ""]) is Err(@version.BlankId(1)),
  )
  assert_true(
    @version.Sequence::from_ids(["v0", "v 1"])
    is Err(@version.IdHasControl(1, 1)),
  )
  assert_true(
    @version.Sequence::from_ids(["v0", "v\t1"])
    is Err(@version.IdHasControl(1, 1)),
  )
}

///|
test "rejects a non-positive or exceeded length limit" {
  assert_true(
    @version.Sequence::from_ids(["v0"], max_commits=0)
    is Err(@version.LimitNotPositive(0)),
  )
  assert_true(
    @version.Sequence::from_ids(["v0", "v1"], max_commits=1)
    is Err(@version.TooLong(1, 2)),
  )
}

///|
test "keeps order and answers position lookups" {
  let sequence = @version.Sequence::from_ids(["v0", "v1", "v2"]).unwrap()
  assert_eq(sequence.length(), 3)
  assert_eq(sequence.at(0), Some("v0"))
  assert_eq(sequence.at(2), Some("v2"))
  assert_eq(sequence.at(3), None)
  assert_eq(sequence.at(-1), None)
  assert_eq(sequence.index_of("v1"), Some(1))
  assert_eq(sequence.index_of("nope"), None)
}

///|
test "returns a defensive copy of the identifiers" {
  let ids = ["v0", "v1"]
  let sequence = @version.Sequence::from_ids(ids).unwrap()
  let copy = sequence.ids()
  copy[0] = "changed"
  copy.push("v2")
  assert_eq(sequence.at(0), Some("v0"))
  assert_eq(sequence.length(), 2)
  ids[0] = "mutated"
  assert_eq(sequence.at(0), Some("v0"))
}

///|
test "digest is stable, order-sensitive and identifier-sensitive" {
  // Values produced by an independent FNV-1a implementation over UTF-8 bytes.
  assert_eq(
    @version.Sequence::from_ids(["v0", "v1"]).unwrap().digest(),
    "35a9865ac75c01d6",
  )
  assert_eq(
    @version.Sequence::from_ids(["v0", "v1", "v2"]).unwrap().digest(),
    "f9ca637c6b49538b",
  )
  assert_eq(
    @version.Sequence::from_ids(["v1", "v0"]).unwrap().digest(),
    "53746a68caa87ddc",
  )
  assert_true(
    @version.Sequence::from_ids(["v0", "v1"]).unwrap().digest() !=
    @version.Sequence::from_ids(["v0", "v2"]).unwrap().digest(),
  )
}

///|
/// Identifiers are printable ASCII by contract. Supplementary-plane input must
/// produce a typed error, not a panic from an unmatched surrogate.
test "non-ASCII identifiers are rejected without panicking" {
  match @version.Sequence::from_ids(["😀"]) {
    Err(@version.IdNotAscii(commit, character)) => {
      assert_eq(commit, 0)
      assert_eq(character, 0)
    }
    _ => assert_true(false)
  }
  match @version.Sequence::from_ids(["v0😀"]) {
    Err(@version.IdNotAscii(commit, character)) => {
      assert_eq(commit, 0)
      assert_eq(character, 2)
    }
    _ => assert_true(false)
  }
  match @version.Sequence::from_ids(["提交-0", "提交-1"]) {
    Err(@version.IdNotAscii(commit, character)) => {
      assert_eq(commit, 0)
      assert_eq(character, 0)
    }
    _ => assert_true(false)
  }
}

///|
test "printable ASCII identifiers of any length are accepted" {
  let sequence = @version.Sequence::from_ids([
    "v0", "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678", "release-1.0",
  ]).unwrap()
  assert_eq(sequence.length(), 3)
  assert_eq(sequence.digest().length(), 16)
}
