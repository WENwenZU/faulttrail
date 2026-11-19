///| The Git adapter, tested through an injected runner: no git binary, no
/// repository, but the exact argument vector and error mapping are covered.

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
fn joined(args : FixedArray[String]) -> String {
  let out = StringBuilder::StringBuilder()
  let mut i = 0
  while i < args.length() {
    if i > 0 {
      out.write_string(" ")
    }
    out.write_string(args[i])
    i = i + 1
  }
  out.to_string()
}

///|
test "the import asks only for identifiers and order" {
  let a = hid("a")
  let b = hid("b")
  let c = hid("c")
  let seen : Array[String] = []
  let run : (FixedArray[String]) -> Result[String, String] = args => {
    let call = joined(args)
    seen.push(call)
    if args[0] == "rev-parse" {
      if call.contains("end^{commit}") {
        Ok("\{c}\n")
      } else {
        Ok("\{a}\n")
      }
    } else {
      Ok("\{c}\n\{b}\n\{a}\n")
    }
  }
  let range = import_with(run, "start", "end", 10).unwrap()
  assert_eq(range.ids, [a, b, c])
  assert_eq(seen.length(), 3)
  assert_true(seen[0].contains("rev-parse"))
  assert_true(seen[0].contains("--end-of-options"))
  assert_true(seen[0].contains("end^{commit}"))
  assert_true(seen[1].contains("rev-parse"))
  assert_true(seen[1].contains("start^{commit}"))
  assert_true(seen[2].contains("--first-parent"))
  assert_true(seen[2].contains("--max-count=11"))
  assert_true(seen[2].contains(c))
  for call in seen {
    // No metadata, no pager, no shell-oriented prefix: the runner receives the
    // subcommand tail only, and the adapter adds `-C <repo> --no-pager`.
    assert_true(!call.contains("--format"))
    assert_true(!call.contains("%an"))
    assert_true(!call.contains("%ae"))
    assert_true(!call.contains("-C"))
  }
}

///|
test "a revision that looks like an option is refused before any call" {
  let seen : Array[String] = []
  let run : (FixedArray[String]) -> Result[String, String] = args => {
    seen.push(joined(args))
    Ok("")
  }
  match import_with(run, "--upload-pack=evil", "main", 10) {
    Err(message) => assert_true(message.contains("'-'"))
    Ok(_) => assert_true(false)
  }
  assert_eq(seen.length(), 0)
}

///|
test "a failed resolution keeps the endpoint in the message" {
  let run : (FixedArray[String]) -> Result[String, String] = args => {
    if joined(args).contains("end^{commit}") {
      Ok(hid("c") + "\n")
    } else {
      Err("fatal: Needed a single revision")
    }
  }
  match import_with(run, "missing", "end", 10) {
    Err(message) => {
      assert_true(message.contains("--from"))
      assert_true(message.contains("cannot resolve 'missing'"))
    }
    Ok(_) => assert_true(false)
  }
}

///|
test "a start commit outside the mainline is reported, not imported" {
  let a = hid("a")
  let b = hid("b")
  let c = hid("c")
  let run : (FixedArray[String]) -> Result[String, String] = args => {
    let call = joined(args)
    if args[0] == "rev-parse" {
      if call.contains("end^{commit}") {
        Ok("\{c}\n")
      } else {
        Ok("\{a}\n")
      }
    } else {
      Ok("\{c}\n\{b}\n")
    }
  }
  match import_with(run, "start", "end", 10) {
    Err(message) => assert_true(message.contains("first-parent chain"))
    Ok(_) => assert_true(false)
  }
}
