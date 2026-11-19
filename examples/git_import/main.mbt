///| A self-contained reproduction of the read-only Git import.
///
/// Running it with `moon run --target js examples/git_import` does everything a
/// new user would do, without a prepared repository:
///
/// 1. builds a synthetic repository under `examples/git_import/out` — eight
///    mainline commits, one of them a merge, plus one side-branch commit;
/// 2. imports the first-parent range `main~7..main` through `@gitio`;
/// 3. runs an investigation on the imported sequence: endpoints, advice, a
///    retraction, a re-record, and a replay;
/// 4. checks the rejection cases: missing repository, side branch as a start,
///    reversed range, and a repository path containing a space.
///
/// The output is a PASS/FAIL trace; the exit code is 1 if anything fails.

///|
#external
priv type RmOptions

///|
extern "js" fn rm_options() -> RmOptions =
  #| () => ({ recursive: true, force: true })

///|
#module("node:fs")
extern "js" fn rm_sync(path : String, options : RmOptions) -> Unit = "rmSync"

///|
extern "js" fn remove_tree(
  rm : (String, RmOptions) -> Unit,
  path : String,
  options : RmOptions,
) -> Unit =
  #| function(rm, path, options) {
  #|   try {
  #|     rm(path, options);
  #|   } catch (error) {}
  #| }

///|
extern "js" fn set_exit_code(code : Int32) -> Unit =
  #| (code) => {
  #|   globalThis.process.exitCode = code;
  #| }

///|
priv struct Report {
  mut checks : Int32
  mut failures : Int32
}

///|
fn Report::check(self : Report, condition : Bool, label : String) -> Unit {
  self.checks = self.checks + 1
  if condition {
    println("PASS: \{label}")
  } else {
    println("FAIL: \{label}")
    self.failures = self.failures + 1
  }
}

///|
fn run_git(args : Array[String]) -> Bool {
  match @gitio.run_args(args) {
    Ok(_) => true
    Err(detail) => {
      println("error: git \{args[0]}: \{detail}")
      false
    }
  }
}

///|
fn write_text(path : String, text : String) -> Bool {
  try {
    @fs.write_string_to_file(path, text)
    true
  } catch {
    _ => false
  }
}

///|
fn commit(repo : String, message : String) -> Bool {
  if !write_text("\{repo}/history.txt", "\{message}\n") {
    return false
  }
  run_git(["-C", repo, "add", "-A"]) &&
  run_git(["-C", repo, "commit", "-m", message])
}

///|
/// Build the fixture: v0..v3, a side commit, the merge v4, then v5..v7.
fn build_repository(repo : String) -> Bool {
  if !run_git(["init", "-b", "main", repo]) {
    return false
  }
  if !run_git(["-C", repo, "config", "user.name", "FaultTrail Fixture"]) {
    return false
  }
  if !run_git(["-C", repo, "config", "user.email", "fixture@faulttrail.invalid"]) {
    return false
  }
  let messages = ["v0", "v1", "v2", "v3"]
  for message in messages {
    if !commit(repo, message) {
      return false
    }
  }
  if !run_git(["-C", repo, "switch", "-c", "side"]) {
    return false
  }
  if !commit(repo, "side: synthetic branch") {
    return false
  }
  if !run_git(["-C", repo, "switch", "main"]) {
    return false
  }
  if !run_git(["-C", repo, "merge", "--no-ff", "side", "-m", "v4: merge side"]) {
    return false
  }
  let later = ["v5", "v6", "v7"]
  for message in later {
    if !commit(repo, message) {
      return false
    }
  }
  true
}

///|
fn import_sequence(path : String) -> Result[@gitimport.Range, String] {
  @gitio.import_range(path, "main~7", "main", 100)
}

///|
/// The investigation half: endpoints, the merge suggestion, a retraction and a
/// replay over the imported sequence.
fn investigate(report : Report, range : @gitimport.Range) -> Unit {
  let ids = range.ids
  report.check(ids.length() == 8, "import yields eight mainline positions")
  let sequence = @version.Sequence::from_ids(ids).unwrap()
  let session = @session.Session::start(sequence).unwrap()
  let _ = session.observe_commit(range.from_id, @engine.Passed).unwrap()
  let _ = session.observe_commit(range.to_id, @engine.Failed).unwrap()
  match session.outcome() {
    @engine.NeedObservation(advice) => {
      report.check(advice.index == 4, "the merge commit is suggested first")
      report.check(advice.commit_id == ids[4], "the suggestion names the merge")
    }
    _ => report.check(false, "the merge commit is suggested first")
  }
  let merge_bad = session.observe(4, @engine.Failed).unwrap()
  let _ = session.observe(2, @engine.Passed).unwrap()
  let _ = session.observe(3, @engine.Passed).unwrap()
  match session.outcome() {
    @engine.Located(found) =>
      report.check(
        found.index == 4,
        "the merge is the only compatible position",
      )
    _ => report.check(false, "the merge is the only compatible position")
  }
  match session.retract(merge_bad.id) {
    Ok(_) => report.check(true, "an explicit retraction is accepted")
    Err(_) => report.check(false, "an explicit retraction is accepted")
  }
  match session.outcome() {
    @engine.NeedObservation(advice) =>
      report.check(
        advice.span.lo == 4 && advice.span.hi == 7,
        "retraction reopens 4..7",
      )
    _ => report.check(false, "retraction reopens 4..7")
  }
  let _ = session.observe(4, @engine.Failed).unwrap()
  match session.outcome() {
    @engine.Located(found) =>
      report.check(found.index == 4, "re-recording restores the localisation")
    _ => report.check(false, "re-recording restores the localisation")
  }
  match @session.Session::replay(sequence, session.events()) {
    Ok(replayed) =>
      report.check(
        replayed.events() == session.events() &&
        replayed.outcome() == session.outcome(),
        "a fresh replay matches the stored session",
      )
    Err(_) => report.check(false, "a fresh replay matches the stored session")
  }
}

///|
fn check_rejections(report : Report, repo : String, root : String) -> Unit {
  match @gitio.import_range("\{root}/missing", "main", "main", 100) {
    Err(detail) =>
      report.check(
        detail.contains("cannot resolve"),
        "a missing repository is reported",
      )
    Ok(_) => report.check(false, "a missing repository is reported")
  }
  match @gitio.import_range(repo, "side", "main", 100) {
    Err(detail) =>
      report.check(
        detail.contains("first-parent chain"),
        "a side-branch start is refused",
      )
    Ok(_) => report.check(false, "a side-branch start is refused")
  }
  match @gitio.import_range(repo, "main", "main~7", 100) {
    Err(detail) =>
      report.check(
        detail.contains("first-parent chain"),
        "a reversed range is refused",
      )
    Ok(_) => report.check(false, "a reversed range is refused")
  }
  match @gitio.import_range(repo, "main", "main", 100) {
    Err(detail) =>
      report.check(
        detail.contains("single commit"),
        "a single-commit range is refused",
      )
    Ok(_) => report.check(false, "a single-commit range is refused")
  }
  // A clone whose path contains a space exercises the argument vector.
  if run_git(["clone", repo, "\{root}/repo with space"]) {
    match
      @gitio.import_range("\{root}/repo with space", "main~7", "main", 100) {
      Err(_) => report.check(false, "a repository path with a space imports")
      Ok(spaced) =>
        report.check(
          spaced.ids ==
          @gitio.import_range(repo, "main~7", "main", 100).unwrap().ids,
          "a repository path with a space imports",
        )
    }
  } else {
    report.check(false, "a repository path with a space imports")
  }
}

///|
fn main {
  let root = "examples/git_import/out"
  remove_tree(rm_sync, root, rm_options())
  @fs.create_dir(root) catch {
    _ => ()
  }
  let repo = "\{root}/repo"
  if !build_repository(repo) {
    println("FAIL: could not build the synthetic repository")
    set_exit_code(1)
    return
  }
  let report = { checks: 0, failures: 0, }
  println("repository: \{repo} (9 commits, 8 on the mainline)")
  match import_sequence(repo) {
    Err(detail) => {
      println("FAIL: import failed: \{detail}")
      set_exit_code(1)
      return
    }
    Ok(range) => {
      println(
        "imported: \{range.ids.length()} positions (\{range.from_id}..\{range.to_id})",
      )
      investigate(report, range)
      check_rejections(report, repo, root)
    }
  }
  println("checks: \{report.checks}, failures: \{report.failures}")
  if report.failures > 0 {
    set_exit_code(1)
  }
}
