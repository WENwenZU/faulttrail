///| Read-only Git access for the command line tool.
///
/// Only two queries are issued: resolve a revision to a commit identifier, and
/// list the first-parent chain of a commit. Both use `execFileSync` with an
/// argument vector, so the repository path and revision are never interpreted by
/// a shell. Nothing reads author names, emails or commit messages, and no hook,
/// alias or repository script runs for these plumbing commands.
///
/// A failed query returns a message; the caller must not create or replace a
/// session file in that case.

///|
#external
priv type ExecResult

///|
extern "js" fn ExecResult::ok(self : ExecResult) -> Bool =
  #| (result) => result.ok

///|
extern "js" fn ExecResult::stdout(self : ExecResult) -> String =
  #| (result) => result.stdout

///|
extern "js" fn ExecResult::stderr(self : ExecResult) -> String =
  #| (result) => result.stderr

///|
#external
priv type ExecOptions

///|
extern "js" fn git_options() -> ExecOptions =
  #| () => ({
  #|   encoding: "utf8",
  #|   maxBuffer: 8 * 1024 * 1024,
  #|   windowsHide: true,
  #|   stdio: ["ignore", "pipe", "pipe"],
  #| })

///|
#module("node:child_process")
extern "js" fn exec_file_sync(
  file : String,
  args : FixedArray[String],
  options : ExecOptions,
) -> String = "execFileSync"

///|
extern "js" fn exec_checked(
  run : (String, FixedArray[String], ExecOptions) -> String,
  file : String,
  args : FixedArray[String],
  options : ExecOptions,
) -> ExecResult =
  #| function(run, file, args, options) {
  #|   try {
  #|     const out = run(file, args, options);
  #|     return { ok: true, stdout: String(out), stderr: "" };
  #|   } catch (error) {
  #|     const detail =
  #|       (error && error.stderr) || (error && error.message) || String(error);
  #|     return { ok: false, stdout: "", stderr: String(detail) };
  #|   }
  #| }

///|
/// Reduce a Git error to one bounded line: the command line tool never prints a
/// full stack or a stream of advisory messages.
fn first_line(text : String) -> String {
  let out = StringBuilder::StringBuilder()
  let mut count = 0
  for character in text {
    if character == '\n' || character == '\r' {
      break
    }
    if count < 240 {
      out.write_char(character)
    }
    count = count + 1
  }
  let line = out.to_string()
  if line.length() == 0 {
    "git failed without a message"
  } else {
    line
  }
}

///|
fn full_args(repo : String, tail : FixedArray[String]) -> FixedArray[String] {
  let full = FixedArray::make(3 + tail.length(), "")
  full[0] = "-C"
  full[1] = repo
  full[2] = "--no-pager"
  let mut i = 0
  while i < tail.length() {
    full[3 + i] = tail[i]
    i = i + 1
  }
  full
}

///|
fn exec_git(args : FixedArray[String]) -> Result[String, String] {
  let result = exec_checked(exec_file_sync, "git", args, git_options())
  if result.ok() {
    Ok(result.stdout())
  } else {
    Err(first_line(result.stderr()))
  }
}

///|
fn run_git(repo : String, tail : FixedArray[String]) -> Result[String, String] {
  exec_git(full_args(repo, tail))
}

///|
/// Run `git` with a complete argument vector.
///
/// Exposed so an example or a host can build a fixture repository; the command
/// line tool itself only uses the read-only helpers above. Arguments are passed
/// as a vector, never through a shell.
pub fn run_args(args : Array[String]) -> Result[String, String] {
  let fixed = FixedArray::make(args.length(), "")
  let mut i = 0
  while i < args.length() {
    fixed[i] = args[i]
    i = i + 1
  }
  exec_git(fixed)
}

///|
fn trim_line(text : String) -> String {
  let out = StringBuilder::StringBuilder()
  for character in text {
    if character != '\n' && character != '\r' && character != ' ' {
      out.write_char(character)
    }
  }
  out.to_string()
}

///|
/// A revision is a value, never an option: empty and `-`-prefixed inputs are
/// rejected before any process is started.
fn revision_error(revision : String) -> String? {
  if revision.length() == 0 {
    Some("empty revision")
  } else if revision.get_char(0) == Some('-') {
    Some("revisions starting with '-' are not accepted")
  } else {
    None
  }
}

///|
/// Resolve a revision through an injected runner. Split from `resolve_commit`
/// so the argument vector can be tested without a repository or a git binary.
fn resolve_with(
  run : (FixedArray[String]) -> Result[String, String],
  revision : String,
) -> Result[String, String] {
  match revision_error(revision) {
    Some(error) => return Err(error)
    None => ()
  }
  let args = FixedArray::make(4, "")
  args[0] = "rev-parse"
  args[1] = "--verify"
  args[2] = "--end-of-options"
  args[3] = "\{revision}^{commit}"
  match run(args) {
    Err(detail) => Err("cannot resolve '\{revision}': \{detail}")
    Ok(text) => {
      let id = trim_line(text)
      if @gitimport.looks_like_commit_id(id) {
        Ok(id)
      } else {
        Err("cannot resolve '\{revision}': unexpected identifier")
      }
    }
  }
}

///|
/// Resolve a user-supplied revision (branch, tag, short or full hash) to the
/// full commit identifier. Revisions starting with `-` are refused so a value can
/// never be read as an option.
pub fn resolve_commit(
  repo : String,
  revision : String,
) -> Result[String, String] {
  resolve_with(args => run_git(repo, args), revision)
}

///|
/// Newest-first first-parent chain of `to`, bounded to `limit` entries so a huge
/// repository cannot produce an unbounded read.
fn chain_with(
  run : (FixedArray[String]) -> Result[String, String],
  to : String,
  limit : Int32,
) -> Result[Array[String], String] {
  let args = FixedArray::make(4, "")
  args[0] = "rev-list"
  args[1] = "--first-parent"
  args[2] = "--max-count=\{limit}"
  args[3] = to
  match run(args) {
    Err(detail) => Err("cannot list first-parent history: \{detail}")
    Ok(text) => {
      let ids : Array[String] = []
      for line in text.split("\n") {
        let id = trim_line(line.to_owned())
        if id.length() > 0 {
          ids.push(id)
        }
      }
      Ok(ids)
    }
  }
}

///|
pub fn first_parent_chain(
  repo : String,
  to : String,
  limit : Int32,
) -> Result[Array[String], String] {
  chain_with(args => run_git(repo, args), to, limit)
}

///|
/// Import an inclusive first-parent range through an injected runner. Exposed for
/// tests, which assert the argument vector without a git binary.
pub fn import_with(
  run : (FixedArray[String]) -> Result[String, String],
  from : String,
  to : String,
  max : Int32,
) -> Result[@gitimport.Range, String] {
  match revision_error(to) {
    Some(error) => return Err("--to: \{error}")
    None => ()
  }
  match revision_error(from) {
    Some(error) => return Err("--from: \{error}")
    None => ()
  }
  let to_hash = match resolve_with(run, to) {
    Err(detail) => return Err("--to: \{detail}")
    Ok(id) => id
  }
  let from_hash = match resolve_with(run, from) {
    Err(detail) => return Err("--from: \{detail}")
    Ok(id) => id
  }
  let chain = match chain_with(run, to_hash, max + 1) {
    Err(detail) => return Err(detail)
    Ok(chain) => chain
  }
  match @gitimport.plan_range(chain, from_hash, to_hash, max) {
    Err(error) => Err(error.message())
    Ok(range) => Ok(range)
  }
}

///|
/// Import an inclusive first-parent range. The result is validated by
/// `gitimport` before any session is created.
pub fn import_range(
  repo : String,
  from : String,
  to : String,
  max : Int32,
) -> Result[@gitimport.Range, String] {
  import_with(args => run_git(repo, args), from, to, max)
}
