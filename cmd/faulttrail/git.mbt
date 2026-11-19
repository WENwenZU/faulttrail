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
fn run_git(repo : String, args : FixedArray[String]) -> Result[String, String] {
  let full = FixedArray::make(3 + args.length(), "")
  full[0] = "-C"
  full[1] = repo
  full[2] = "--no-pager"
  let mut i = 0
  while i < args.length() {
    full[3 + i] = args[i]
    i = i + 1
  }
  let result = exec_checked(exec_file_sync, "git", full, git_options())
  if result.ok() {
    Ok(result.stdout())
  } else {
    Err(first_line(result.stderr()))
  }
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
fn short(id : String) -> String {
  if id.length() <= 12 {
    id
  } else {
    id[:12].to_owned()
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
  if revision.length() == 0 {
    return Err("empty revision")
  }
  if revision.get_char(0) == Some('-') {
    return Err("revisions starting with '-' are not accepted")
  }
  let args = FixedArray::make(4, "")
  args[0] = "rev-parse"
  args[1] = "--verify"
  args[2] = "--end-of-options"
  args[3] = "\{revision}^{commit}"
  match run_git(repo, args) {
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
/// Newest-first first-parent chain of `to`, bounded to `limit` entries so a huge
/// repository cannot produce an unbounded read.
pub fn first_parent_chain(
  repo : String,
  to : String,
  limit : Int32,
) -> Result[Array[String], String] {
  let args = FixedArray::make(4, "")
  args[0] = "rev-list"
  args[1] = "--first-parent"
  args[2] = "--max-count=\{limit}"
  args[3] = to
  match run_git(repo, args) {
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
/// Import an inclusive first-parent range. The result is validated by
/// `gitimport` before any session is created.
pub fn import_range(
  repo : String,
  from : String,
  to : String,
  max : Int32,
) -> Result[@gitimport.Range, String] {
  let to_hash = match resolve_commit(repo, to) {
    Err(detail) => return Err("--to: \{detail}")
    Ok(id) => id
  }
  let from_hash = match resolve_commit(repo, from) {
    Err(detail) => return Err("--from: \{detail}")
    Ok(id) => id
  }
  let chain = match first_parent_chain(repo, to_hash, max + 1) {
    Err(detail) => return Err(detail)
    Ok(chain) => chain
  }
  match @gitimport.plan_range(chain, from_hash, to_hash, max) {
    Err(error) => Err(error.message())
    Ok(range) => Ok(range)
  }
}
