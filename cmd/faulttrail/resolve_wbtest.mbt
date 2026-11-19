///| Commit token resolution: exact match, unique prefix, ambiguous prefix.

///|
test "an exact identifier is accepted as-is" {
  let ids = ["aaaa1111", "bbbb2222"]
  assert_eq(resolve_commit_token(ids, "bbbb2222"), Ok("bbbb2222"))
}

///|
test "a unique prefix resolves to the full identifier" {
  let ids = ["aaaa1111", "bbbb2222", "bbbb3333"]
  assert_eq(resolve_commit_token(ids, "aaaa"), Ok("aaaa1111"))
  assert_eq(resolve_commit_token(ids, "bbbb2"), Ok("bbbb2222"))
}

///|
test "an ambiguous prefix is an error, not a guess" {
  let ids = ["bbbb2222", "bbbb3333"]
  match resolve_commit_token(ids, "bbbb") {
    Err(message) => assert_true(message.contains("matches 2 commits"))
    Ok(_) => assert_true(false)
  }
}

///|
test "an unknown or empty token is an error" {
  let ids = ["aaaa1111"]
  match resolve_commit_token(ids, "cccc") {
    Err(message) => assert_true(message.contains("no commit"))
    Ok(_) => assert_true(false)
  }
  match resolve_commit_token(ids, "") {
    Err(message) => assert_true(message.contains("empty"))
    Ok(_) => assert_true(false)
  }
}
