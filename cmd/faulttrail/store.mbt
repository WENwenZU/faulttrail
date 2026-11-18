///| File access for the command line tool.
///
/// The CLI targets the JS backend because the project needs real files and this
/// is the backend where the toolchain can read and replace them on the current
/// machine. Declaring `supported_targets = "js"` keeps that honest: the core
/// passing on Wasm says nothing about the CLI's disk behaviour.
///
/// Reads are treated as untrusted input: the size is checked before the content
/// is read, and the parser validates every line. Writes go to a sibling
/// temporary file that is renamed over the target, so a failed save leaves the
/// previous session intact instead of a truncated file.

///|
#external
priv type OpResult

///|
extern "js" fn OpResult::ok(self : OpResult) -> Bool =
  #| (result) => result.ok

///|
extern "js" fn OpResult::message(self : OpResult) -> String =
  #| (result) => result.message

///|
#module("node:fs")
extern "js" fn rename_sync(from : String, to : String) -> Unit = "renameSync"

///|
extern "js" fn rename_checked(
  rename : (String, String) -> Unit,
  from : String,
  to : String,
) -> OpResult =
  #| function(rename, from, to) {
  #|   try {
  #|     rename(from, to);
  #|     return { ok: true, message: "" };
  #|   } catch (error) {
  #|     return { ok: false, message: String((error && error.message) || error) };
  #|   }
  #| }

///|
#external
priv type FileStat

///|
#module("node:fs")
extern "js" fn stat_sync(path : String) -> FileStat = "statSync"

///|
extern "js" fn size_checked(
  stat : (String) -> FileStat,
  path : String,
) -> Int32 =
  #| function(stat, path) {
  #|   try {
  #|     return stat(path).size;
  #|   } catch (error) {
  #|     return -1;
  #|   }
  #| }

///|
#external
priv type WriteOptions

///|
extern "js" fn exclusive_options() -> WriteOptions =
  #| () => ({ flag: "wx" })

///|
#module("node:fs")
extern "js" fn write_file_sync(
  path : String,
  content : String,
  options : WriteOptions,
) -> Unit = "writeFileSync"

///|
extern "js" fn write_exclusive_checked(
  write : (String, String, WriteOptions) -> Unit,
  path : String,
  content : String,
  options : WriteOptions,
) -> OpResult =
  #| function(write, path, content, options) {
  #|   try {
  #|     write(path, content, options);
  #|     return { ok: true, message: "" };
  #|   } catch (error) {
  #|     return { ok: false, message: String((error && error.message) || error) };
  #|   }
  #| }

///|
extern "js" fn process_id() -> Int32 =
  #| () => globalThis.process.pid

///|
extern "js" fn random_suffix() -> Int32 =
  #| () => Math.floor(Math.random() * 1000000000)

///|
extern "js" fn set_exit_code(code : Int32) -> Unit =
  #| (code) => {
  #|   globalThis.process.exitCode = code;
  #| }

///|
fn read_text(path : String) -> Result[String, String] {
  Ok(@fs.read_file_to_string(path)) catch {
    _ => Err("cannot read \{path}")
  }
}

///|
fn exists(path : String) -> Bool {
  @fs.path_exists(path)
}

///|
fn remove_quiet(path : String) -> Unit {
  @fs.remove_file(path) catch {
    _ => ()
  }
}

///|
/// Load and validate a session file.
pub fn load(path : String) -> Result[@sessionfile.SessionFile, String] {
  if !exists(path) {
    return Err("session file not found: \{path}")
  }
  let size = size_checked(stat_sync, path)
  if size < 0 {
    return Err("cannot read \{path}")
  }
  if size > @sessionfile.MAX_FILE_BYTES {
    return Err(
      "session file is \{size} bytes, above the application limit of \{@sessionfile.MAX_FILE_BYTES}",
    )
  }
  match read_text(path) {
    Err(error) => Err(error)
    Ok(text) =>
      match @sessionfile.decode(text) {
        Ok(loaded) => Ok(loaded)
        Err(error) => Err("session rejected: \{error.message()}")
      }
  }
}

///|
/// Write a new session at `path`. Refuses to overwrite an existing file, so a
/// mistyped path cannot destroy an unrelated investigation.
pub fn create(
  path : String,
  session : @session.Session,
) -> Result[Int32, String] {
  if exists(path) {
    return Err("session already exists: \{path}")
  }
  write_atomically(path, session, 1)
}

///|
/// Replace an existing session after checking that the file on disk is still the
/// revision this process loaded. The check is optimistic, not a lock: it turns a
/// silent lost update into a visible error, and the caller must reload to
/// continue.
pub fn update(
  path : String,
  session : @session.Session,
  expected_revision : Int32,
) -> Result[Int32, String] {
  if !exists(path) {
    return Err("session file disappeared: \{path}")
  }
  match load(path) {
    Err(error) => Err(error)
    Ok(current) =>
      if current.revision != expected_revision {
        Err(
          "session changed on disk (revision \{current.revision}, loaded \{expected_revision}); reload before saving",
        )
      } else {
        write_atomically(path, session, expected_revision + 1)
      }
  }
}

///|
fn write_atomically(
  path : String,
  session : @session.Session,
  revision : Int32,
) -> Result[Int32, String] {
  if revision < 1 || revision > @sessionfile.MAX_REVISION {
    return Err(
      "revision \{revision} is outside 1..\{@sessionfile.MAX_REVISION}",
    )
  }
  let text = @sessionfile.encode(session, revision)
  if text.length() > @sessionfile.MAX_FILE_BYTES {
    return Err(
      "encoded session is \{text.length()} bytes, above the application limit of \{@sessionfile.MAX_FILE_BYTES}",
    )
  }
  // Never replace the target with a file this build cannot load again.
  match @sessionfile.decode(text) {
    Err(error) =>
      return Err(
        "refusing to save a session that would not reload: \{error.message()}",
      )
    Ok(_) => ()
  }
  match write_temp(path, text) {
    Err(error) => Err(error)
    Ok(temp) => {
      let renamed = rename_checked(rename_sync, temp, path)
      if renamed.ok() {
        Ok(revision)
      } else {
        // The previous file is still in place; drop only our own copy.
        remove_quiet(temp)
        Err("cannot replace \{path}: \{renamed.message()}")
      }
    }
  }
}

///|
/// Create a temporary file next to the target with an exclusive create flag.
///
/// The name carries the process id and a random suffix, and `wx` refuses to
/// truncate an existing file: a leftover `.tmp`, an unrelated file or a
/// directory with a similar name is never overwritten. Only the exact file
/// created here is removed on failure.
fn write_temp(path : String, text : String) -> Result[String, String] {
  let mut attempt = 0
  while attempt < 4 {
    let temp = "\{path}.tmp.\{process_id()}.\{random_suffix()}"
    let result = write_exclusive_checked(
      write_file_sync,
      temp,
      text,
      exclusive_options(),
    )
    if result.ok() {
      return Ok(temp)
    }
    if !result.message().contains("EEXIST") {
      return Err(
        "cannot create a temporary file next to \{path}: \{result.message()}",
      )
    }
    attempt = attempt + 1
  }
  Err("cannot create a unique temporary file next to \{path}")
}
