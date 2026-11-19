///| Range planning from a first-parent listing: endpoint semantics and the
/// failure cases a repository can produce.

///|
fn hid(character : String) -> String {
  let out = StringBuilder::StringBuilder()
  let mut i = 0
  while i < 40 {
    out.write_string(character)
    i = i + 1
  }
  out.to_string()
}

///|
test "a chain becomes an oldest-first range with both endpoints" {
  let a = hid("a")
  let b = hid("b")
  let c = hid("c")
  let planned = @gitimport.plan_range([c, b, a], a, c, 10).unwrap()
  assert_eq(planned.ids, [a, b, c])
  assert_eq(planned.from_id, a)
  assert_eq(planned.to_id, c)
  assert_eq(planned.ids[0], a)
  assert_eq(planned.ids[2], c)
}

///|
test "the listing must start at the requested end commit" {
  let a = hid("a")
  let b = hid("b")
  let c = hid("c")
  match @gitimport.plan_range([b, a], a, c, 10) {
    Err(@gitimport.ToNotTip(head, to)) => {
      assert_eq(head, b)
      assert_eq(to, c)
    }
    _ => assert_true(false)
  }
}

///|
test "a start commit outside the first-parent chain is refused" {
  let a = hid("a")
  let b = hid("b")
  let c = hid("c")
  match @gitimport.plan_range([c, b], a, c, 10) {
    Err(@gitimport.FromNotOnChain(from, to)) => {
      assert_eq(from, a)
      assert_eq(to, c)
    }
    _ => assert_true(false)
  }
}

///|
test "a single-commit range is refused" {
  let a = hid("a")
  match @gitimport.plan_range([a], a, a, 10) {
    Err(@gitimport.SingleCommit(id)) => assert_eq(id, a)
    _ => assert_true(false)
  }
}

///|
test "an empty listing is refused" {
  let a = hid("a")
  match @gitimport.plan_range([], a, hid("b"), 10) {
    Err(@gitimport.EmptyChain) => ()
    _ => assert_true(false)
  }
}

///|
test "a range longer than the limit is refused in both shapes" {
  let a = hid("a")
  let b = hid("b")
  let c = hid("c")
  let d = hid("d")
  // The start commit sits beyond the limit.
  match @gitimport.plan_range([d, c, b, a], a, d, 3) {
    Err(@gitimport.RangeTooLong(limit)) => assert_eq(limit, 3)
    _ => assert_true(false)
  }
  // The window was full and the start commit was not in it.
  match @gitimport.plan_range([d, c, b, a], hid("e"), d, 3) {
    Err(@gitimport.RangeTooLong(limit)) => assert_eq(limit, 3)
    _ => assert_true(false)
  }
  // Exactly at the limit is accepted.
  let planned = @gitimport.plan_range([c, b, a], a, c, 3).unwrap()
  assert_eq(planned.ids.length(), 3)
}

///|
test "non-hex identifiers are refused instead of stored" {
  match @gitimport.plan_range([hid("a")], "not-hex", hid("a"), 10) {
    Err(@gitimport.BadCommitId(id)) => assert_eq(id, "not-hex")
    _ => assert_true(false)
  }
  match @gitimport.plan_range(["not-hex"], hid("a"), "not-hex", 10) {
    Err(@gitimport.BadCommitId(id)) => assert_eq(id, "not-hex")
    _ => assert_true(false)
  }
}

///|
test "an uppercase SHA is still a commit identifier" {
  let a = hid("A")
  let b = hid("B")
  let planned = @gitimport.plan_range([b, a], a, b, 10).unwrap()
  assert_eq(planned.ids, [a, b])
}
