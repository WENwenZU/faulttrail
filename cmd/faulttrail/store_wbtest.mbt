///| White-box tests for the save/load boundary: overwrite refusal, stale
/// revision detection, and a failed replace that must leave the previous file
/// intact. These use a scratch directory next to the project and remove it
/// afterwards.

///|
#module("node:fs")
extern "js" fn chmod_sync(path : String, mode : Int32) -> Unit = "chmodSync"

///|
fn scratch_dir() -> String {
  "_tmp_store_test"
}

///|
fn prepare() -> Unit {
  @fs.create_dir(scratch_dir()) catch {
    _ => ()
  }
}

///|
fn cleanup(path : String) -> Unit {
  remove_quiet(path)
  remove_quiet("\{path}.tmp")
  @fs.remove_dir("\{path}.tmp") catch {
    _ => ()
  }
}

///|
fn finish() -> Unit {
  @fs.remove_dir(scratch_dir()) catch {
    _ => ()
  }
}

///|
fn tiny_session() -> @session.Session {
  let sequence = @version.Sequence::from_ids(["v0", "v1"]).unwrap()
  @session.Session::start(sequence).unwrap()
}

///|
test "create writes revision 1 and refuses to overwrite" {
  prepare()
  let path = "\{scratch_dir()}/create.session"
  cleanup(path)
  match create(path, tiny_session()) {
    Ok(revision) => assert_eq(revision, 1)
    Err(_) => assert_true(false)
  }
  match create(path, tiny_session()) {
    Err(message) => assert_true(message.contains("already exists"))
    Ok(_) => assert_true(false)
  }
  assert_eq(load(path).unwrap().revision, 1)
  cleanup(path)
  finish()
}

///|
test "a stale revision is refused instead of overwriting the file" {
  prepare()
  let path = "\{scratch_dir()}/stale.session"
  cleanup(path)
  let _ = create(path, tiny_session()).unwrap()
  let loaded = load(path).unwrap()
  // Claim an older revision, as if another process had saved after this one
  // loaded the file.
  match update(path, loaded.session, loaded.revision - 1) {
    Err(message) => assert_true(message.contains("changed on disk"))
    Ok(_) => assert_true(false)
  }
  assert_eq(load(path).unwrap().revision, 1)
  cleanup(path)
  finish()
}

///|
/// A read-only destination makes the rename fail on this platform; the previous
/// session must stay intact and our temporary file must be removed.
test "a failed replace leaves the previous session readable" {
  prepare()
  let path = "\{scratch_dir()}/blocked.session"
  cleanup(path)
  let session = tiny_session()
  let _ = create(path, session).unwrap()
  chmod_sync(path, 292) // 0o444, read-only
  let _ = session.observe(0, @engine.Passed)
  match update(path, session, 1) {
    Err(_) => assert_true(true)
    Ok(_) => assert_true(false)
  }
  let reloaded = load(path).unwrap()
  assert_eq(reloaded.revision, 1)
  assert_eq(reloaded.session.events().length(), 0)
  let entries = @fs.read_dir(scratch_dir()) catch { _ => [] }
  for entry in entries {
    assert_true(!entry.contains(".tmp."))
  }
  chmod_sync(path, 438) // 0o666, writable again for cleanup
  cleanup(path)
  finish()
}

///|
test "load reports a missing file instead of creating one" {
  prepare()
  let path = "\{scratch_dir()}/missing.session"
  cleanup(path)
  match load(path) {
    Err(message) => assert_true(message.contains("not found"))
    Ok(_) => assert_true(false)
  }
  assert_true(!exists(path))
  cleanup(path)
  finish()
}

///|
/// A reported counterexample: a pre-existing `<session>.tmp` belonged to
/// something else. Saves now create an exclusively-owned file with a unique
/// name, so the sentinel survives untouched.
test "an unrelated temporary file is not overwritten" {
  prepare()
  let path = "\{scratch_dir()}/sentinel.session"
  cleanup(path)
  let sentinel = "\{path}.tmp"
  remove_quiet(sentinel)
  @fs.write_string_to_file(sentinel, "sentinel content") catch {
    _ => assert_true(false)
  }
  match create(path, tiny_session()) {
    Ok(_) => assert_true(true)
    Err(_) => assert_true(false)
  }
  let kept = @fs.read_file_to_string(sentinel) catch { _ => "" }
  assert_eq(kept, "sentinel content")
  assert_eq(load(path).unwrap().revision, 1)
  cleanup(path)
  finish()
}

///|
test "a successful save leaves no temporary file of its own" {
  prepare()
  let path = "\{scratch_dir()}/fresh.session"
  cleanup(path)
  let _ = create(path, tiny_session()).unwrap()
  let entries = @fs.read_dir(scratch_dir()) catch { _ => [] }
  for entry in entries {
    assert_true(!entry.contains(".tmp."))
  }
  cleanup(path)
  finish()
}

///|
test "a revision outside the contract is refused before writing" {
  prepare()
  let path = "\{scratch_dir()}/revbound.session"
  cleanup(path)
  let session = tiny_session()
  match write_atomically(path, session, 0) {
    Err(_) => assert_true(true)
    Ok(_) => assert_true(false)
  }
  match write_atomically(path, session, @sessionfile.MAX_REVISION + 1) {
    Err(_) => assert_true(true)
    Ok(_) => assert_true(false)
  }
  assert_true(!exists(path))
  cleanup(path)
  finish()
}

///|
test "a session the file contract would reject is not written" {
  prepare()
  let path = "\{scratch_dir()}/contract.session"
  cleanup(path)
  let sequence = @version.Sequence::from_ids(["v0", "v1"]).unwrap()
  let oversized = @session.Session::start(sequence, attempt_limit=1001).unwrap()
  match create(path, oversized) {
    Err(message) => assert_true(message.contains("would not reload"))
    Ok(_) => assert_true(false)
  }
  assert_true(!exists(path))
  cleanup(path)
  finish()
}
