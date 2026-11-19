///| FaultTrail command line: a manual investigation session over an explicit
/// oldest-first commit list.
///
/// The tool does not read a Git repository, does not run a test command and does
/// not know what the commits contain. It records what the operator observed and
/// answers with the evidence-compatible candidates plus one next step.
///
/// Exit codes:
///   0  command completed; for `next`, a suggestion or a localisation
///   1  input, format, IO, or invalid operation (nothing was written on error)
///   2  usage error
///   3  insufficient evidence (no good or no bad endpoint yet)
///   4  ambiguous candidates (nothing left that may be probed)
///   5  contradictory evidence
///   6  a budget was exhausted
///
/// `explain` reports state and exits 0 when the file was read; use `next` for
/// the state-dependent code.

///|
const EXIT_OK : Int32 = 0

///|
const EXIT_INPUT : Int32 = 1

///|
const EXIT_USAGE : Int32 = 2

///|
const EXIT_INSUFFICIENT : Int32 = 3

///|
const EXIT_AMBIGUOUS : Int32 = 4

///|
const EXIT_CONFLICT : Int32 = 5

///|
const EXIT_BUDGET : Int32 = 6

///|
fn usage() -> Unit {
  println(
    "faulttrail - replayable regression localisation over a linear commit list",
  )
  println("")
  println("usage:")
  println("  faulttrail start   --sequence <ids-file> --session <session-file>")
  println(
    "                     [--attempt-limit N] [--max-observations N] [--max-steps N]",
  )
  println("  faulttrail record  --session <session-file> --commit <id>")
  println(
    "                     --probe passed|failed|build-failed|timed-out|skipped|undetermined",
  )
  println("                     [--retry]")
  println("  faulttrail retract --session <session-file> --observation <id>")
  println("  faulttrail next    --session <session-file>")
  println("  faulttrail explain --session <session-file>")
  println("  faulttrail replay  --session <session-file>")
  println("  faulttrail help")
  println("")
  println("The ids file lists commit identifiers oldest first, one per line;")
  println("blank lines and lines starting with # are ignored.")
  println(
    "The session file is written next to itself through a temporary file,",
  )
  println("so a failed save leaves the previous session intact.")
  println("")
  println("exit codes: 0 ok, 1 input/io, 2 usage, 3 insufficient, 4 ambiguous,")
  println(
    "            5 conflict, 6 budget (explain returns 0 once the file reads)",
  )
}

///|
priv struct Parsed {
  values : Map[String, String]
  flags : Map[String, Bool]
}

///|
fn contains(items : Array[String], key : String) -> Bool {
  for item in items {
    if item == key {
      return true
    }
  }
  false
}

///|
fn parse_options(
  args : Array[String],
  value_keys : Array[String],
  flag_keys : Array[String],
) -> Result[Parsed, String] {
  let values : Map[String, String] = Map([])
  let flags : Map[String, Bool] = Map([])
  let mut i = 0
  while i < args.length() {
    let token = args[i]
    if token.length() < 3 || token[:2].to_owned() != "--" {
      return Err("unexpected argument: \{token}")
    }
    let name = token[2:].to_owned()
    if contains(value_keys, name) {
      if i + 1 >= args.length() {
        return Err("option --\{name} needs a value")
      }
      values.set(name, args[i + 1])
      i = i + 2
    } else if contains(flag_keys, name) {
      flags.set(name, true)
      i = i + 1
    } else {
      return Err("unknown option: --\{name}")
    }
  }
  Ok({ values, flags, })
}

///|
fn required(parsed : Parsed, key : String) -> Result[String, String] {
  match parsed.values.get(key) {
    Some(value) => Ok(value)
    None => Err("missing required option --\{key}")
  }
}

///|
fn optional_int(
  parsed : Parsed,
  key : String,
  fallback : Int32,
) -> Result[Int32, String] {
  match parsed.values.get(key) {
    None => Ok(fallback)
    Some(text) =>
      match @sessionfile.parse_bounded_int(text, key) {
        Ok(value) => Ok(value)
        Err(_) => Err("option --\{key} is not a bounded integer: \{text}")
      }
  }
}

///|
/// Short form used only in command output; the session keeps full identifiers.
fn short(id : String) -> String {
  if id.length() <= 12 {
    id
  } else {
    id[:12].to_owned()
  }
}

///|
fn strip_trailing_cr(text : String) -> String {
  match text.rev_find("\r") {
    Some(index) =>
      if index == text.length() - 1 {
        text[:index].to_owned()
      } else {
        text
      }
    None => text
  }
}

///|
fn read_ids(path : String) -> Result[Array[String], String] {
  if !exists(path) {
    return Err("commit list not found: \{path}")
  }
  let size = size_checked(stat_sync, path)
  if size < 0 {
    return Err("cannot read \{path}")
  }
  if size > @sessionfile.MAX_FILE_BYTES {
    return Err(
      "commit list is \{size} bytes, above the application limit of \{@sessionfile.MAX_FILE_BYTES}",
    )
  }
  let text = match read_text(path) {
    Err(error) => return Err(error)
    Ok(text) => text
  }
  let ids : Array[String] = []
  for raw in text.split("\n") {
    // Both helpers avoid indexing past a surrogate: the identifier may be
    // invalid, but this reader must classify it, not crash on it.
    let line = strip_trailing_cr(raw.to_owned())
    if line.length() > 0 {
      let comment = match line.get_char(0) {
        Some('#') => true
        _ => false
      }
      if !comment {
        ids.push(line)
      }
    }
  }
  Ok(ids)
}

///|
fn record_error_exit(error : @engine.RecordError) -> Int32 {
  match error {
    @engine.ObservationsExhausted(_) => EXIT_BUDGET
    _ => EXIT_INPUT
  }
}

///|
fn cmd_start(args : Array[String]) -> Int32 {
  let parsed = match
    parse_options(
      args,
      [
        "sequence", "session", "attempt-limit", "max-observations", "max-steps",
        "repo", "from", "to",
      ],
      [],
    ) {
    Err(error) => {
      println("error: \{error}")
      return EXIT_USAGE
    }
    Ok(parsed) => parsed
  }
  let session_path = match required(parsed, "session") {
    Err(error) => {
      println("error: \{error}")
      return EXIT_USAGE
    }
    Ok(value) => value
  }
  let attempt_limit = match optional_int(parsed, "attempt-limit", 1) {
    Err(error) => {
      println("error: \{error}")
      return EXIT_USAGE
    }
    Ok(value) => value
  }
  let defaults = @engine.Limits::default()
  let max_observations = match
    optional_int(parsed, "max-observations", defaults.max_observations) {
    Err(error) => {
      println("error: \{error}")
      return EXIT_USAGE
    }
    Ok(value) => value
  }
  let max_steps = match optional_int(parsed, "max-steps", defaults.max_steps) {
    Err(error) => {
      println("error: \{error}")
      return EXIT_USAGE
    }
    Ok(value) => value
  }
  // The command must not accept a value the file contract will reject later:
  // check every bound before anything is written.
  if attempt_limit < 1 || attempt_limit > @sessionfile.MAX_ATTEMPT_LIMIT {
    println(
      "error: --attempt-limit must be in 1..\{@sessionfile.MAX_ATTEMPT_LIMIT}, got \{attempt_limit}",
    )
    return EXIT_USAGE
  }
  if max_observations < 1 ||
    max_observations > @sessionfile.MAX_OBSERVATIONS_LIMIT {
    println(
      "error: --max-observations must be in 1..\{@sessionfile.MAX_OBSERVATIONS_LIMIT}, got \{max_observations}",
    )
    return EXIT_USAGE
  }
  if max_steps < 1 || max_steps > @sessionfile.MAX_STEPS_LIMIT {
    println(
      "error: --max-steps must be in 1..\{@sessionfile.MAX_STEPS_LIMIT}, got \{max_steps}",
    )
    return EXIT_USAGE
  }
  // One source per investigation: an explicit commit list, or a read-only Git
  // first-parent import. Mixing them would make the file's provenance ambiguous.
  let sequence_path = parsed.values.get("sequence")
  let from_repo = parsed.values.get("repo")
  let from_rev = parsed.values.get("from")
  let to_rev = parsed.values.get("to")
  let git_mode = from_repo is Some(_) ||
    from_rev is Some(_) ||
    to_rev is Some(_)
  if sequence_path is Some(_) && git_mode {
    println("error: use either --sequence or --repo/--from/--to, not both")
    return EXIT_USAGE
  }
  if sequence_path is None && !git_mode {
    println("error: missing --sequence, or --repo with --from and --to")
    return EXIT_USAGE
  }
  let ids : Array[String] = if git_mode {
    let repo = match required(parsed, "repo") {
      Err(error) => {
        println("error: \{error}")
        return EXIT_USAGE
      }
      Ok(value) => value
    }
    let from = match required(parsed, "from") {
      Err(error) => {
        println("error: \{error}")
        return EXIT_USAGE
      }
      Ok(value) => value
    }
    let to = match required(parsed, "to") {
      Err(error) => {
        println("error: \{error}")
        return EXIT_USAGE
      }
      Ok(value) => value
    }
    match @gitio.import_range(repo, from, to, @sessionfile.MAX_SEQUENCE) {
      Err(error) => {
        println("error: \{error}")
        return EXIT_INPUT
      }
      Ok(range) => {
        let last = range.ids.length() - 1
        println(
          "imported: \{range.ids.length()} first-parent commits (\{short(range.from_id)}..\{short(range.to_id)})",
        )
        println("from: \{range.from_id} (position 0)")
        println("to:   \{range.to_id} (position \{last})")
        println(
          "hint: faulttrail record --session \{session_path} --commit \{range.from_id} --probe passed",
        )
        println(
          "hint: faulttrail record --session \{session_path} --commit \{range.to_id} --probe failed",
        )
        range.ids
      }
    }
  } else {
    let path = match sequence_path {
      Some(path) => path
      None => ""
    }
    match read_ids(path) {
      Err(error) => {
        println("error: \{error}")
        return EXIT_INPUT
      }
      Ok(ids) => ids
    }
  }
  let sequence = match
    @version.Sequence::from_ids(ids, max_commits=@sessionfile.MAX_SEQUENCE) {
    Err(error) => {
      println("error: \{error.message()}")
      return EXIT_INPUT
    }
    Ok(sequence) => sequence
  }
  let session = match
    @session.Session::start(
      sequence,
      limits=@engine.Limits::new(max_observations, max_steps),
      attempt_limit~,
    ) {
    Err(report) => {
      println("error: \{report.code}: \{report.detail}")
      return EXIT_INPUT
    }
    Ok(session) => session
  }
  let revision = match create(session_path, session) {
    Err(error) => {
      println("error: \{error}")
      return EXIT_INPUT
    }
    Ok(revision) => revision
  }
  println(
    "started: \{sequence.length()} commits, attempt-limit \{attempt_limit}, limits \{max_observations}/\{max_steps}",
  )
  println("session: \{session_path} (revision \{revision})")
  println("next: run `faulttrail record` with an observed good and bad commit")
  EXIT_OK
}

///|
fn cmd_record(args : Array[String]) -> Int32 {
  let parsed = match
    parse_options(args, ["session", "commit", "probe"], ["retry"]) {
    Err(error) => {
      println("error: \{error}")
      return EXIT_USAGE
    }
    Ok(parsed) => parsed
  }
  let session_path = match required(parsed, "session") {
    Err(error) => {
      println("error: \{error}")
      return EXIT_USAGE
    }
    Ok(value) => value
  }
  let commit = match required(parsed, "commit") {
    Err(error) => {
      println("error: \{error}")
      return EXIT_USAGE
    }
    Ok(value) => value
  }
  let probe_text = match required(parsed, "probe") {
    Err(error) => {
      println("error: \{error}")
      return EXIT_USAGE
    }
    Ok(value) => value
  }
  let probe = match @sessionfile.probe_from_token(probe_text) {
    Some(probe) => probe
    None => {
      println("error: unknown probe token: \{probe_text}")
      return EXIT_USAGE
    }
  }
  let file = match load(session_path) {
    Err(error) => {
      println("error: \{error}")
      return EXIT_INPUT
    }
    Ok(file) => file
  }
  let may_retry = match parsed.flags.get("retry") {
    Some(_) => true
    None => false
  }
  let observation = match
    file.session.observe_commit(commit, probe, may_retry~) {
    Err(error) => {
      println("error: \{error.message()}")
      return record_error_exit(error)
    }
    Ok(observation) => observation
  }
  let revision = match update(session_path, file.session, file.revision) {
    Err(error) => {
      println("error: \{error}")
      return EXIT_INPUT
    }
    Ok(revision) => revision
  }
  println(
    "recorded: #\{observation.id} \{probe_text} \{commit} (position \{observation.index})",
  )
  println("session: \{session_path} (revision \{revision})")
  EXIT_OK
}

///|
fn cmd_retract(args : Array[String]) -> Int32 {
  let parsed = match parse_options(args, ["session", "observation"], []) {
    Err(error) => {
      println("error: \{error}")
      return EXIT_USAGE
    }
    Ok(parsed) => parsed
  }
  let session_path = match required(parsed, "session") {
    Err(error) => {
      println("error: \{error}")
      return EXIT_USAGE
    }
    Ok(value) => value
  }
  let observation_text = match required(parsed, "observation") {
    Err(error) => {
      println("error: \{error}")
      return EXIT_USAGE
    }
    Ok(value) => value
  }
  let obs_id = match
    @sessionfile.parse_bounded_int(observation_text, "observation") {
    Ok(value) => value
    Err(_) => {
      println(
        "error: option --observation is not a bounded integer: \{observation_text}",
      )
      return EXIT_USAGE
    }
  }
  let file = match load(session_path) {
    Err(error) => {
      println("error: \{error}")
      return EXIT_INPUT
    }
    Ok(file) => file
  }
  match file.session.retract(obs_id) {
    Err(error) =>
      match error {
        @engine.NoSuchObservation(id) => {
          println("error: no observation #\{id} in this session")
          return EXIT_INPUT
        }
        @engine.AlreadyRetracted(id) => {
          println("error: observation #\{id} was already retracted")
          return EXIT_INPUT
        }
      }
    Ok(_) => ()
  }
  let revision = match update(session_path, file.session, file.revision) {
    Err(error) => {
      println("error: \{error}")
      return EXIT_INPUT
    }
    Ok(revision) => revision
  }
  println("retracted: #\{obs_id}")
  println("session: \{session_path} (revision \{revision})")
  EXIT_OK
}

///|
fn cmd_next(args : Array[String]) -> Int32 {
  let parsed = match parse_options(args, ["session"], []) {
    Err(error) => {
      println("error: \{error}")
      return EXIT_USAGE
    }
    Ok(parsed) => parsed
  }
  let session_path = match required(parsed, "session") {
    Err(error) => {
      println("error: \{error}")
      return EXIT_USAGE
    }
    Ok(value) => value
  }
  let file = match load(session_path) {
    Err(error) => {
      println("error: \{error}")
      return EXIT_INPUT
    }
    Ok(file) => file
  }
  let outcome = file.session.outcome()
  print_outcome(outcome)
  outcome_exit(outcome)
}

///|
fn cmd_explain(args : Array[String]) -> Int32 {
  let parsed = match parse_options(args, ["session"], []) {
    Err(error) => {
      println("error: \{error}")
      return EXIT_USAGE
    }
    Ok(parsed) => parsed
  }
  let session_path = match required(parsed, "session") {
    Err(error) => {
      println("error: \{error}")
      return EXIT_USAGE
    }
    Ok(value) => value
  }
  let file = match load(session_path) {
    Err(error) => {
      println("error: \{error}")
      return EXIT_INPUT
    }
    Ok(file) => file
  }
  print_state(session_path, file)
  EXIT_OK
}

///|
fn cmd_replay(args : Array[String]) -> Int32 {
  let parsed = match parse_options(args, ["session"], []) {
    Err(error) => {
      println("error: \{error}")
      return EXIT_USAGE
    }
    Ok(parsed) => parsed
  }
  let session_path = match required(parsed, "session") {
    Err(error) => {
      println("error: \{error}")
      return EXIT_USAGE
    }
    Ok(value) => value
  }
  let file = match load(session_path) {
    Err(error) => {
      println("error: \{error}")
      return EXIT_INPUT
    }
    Ok(file) => file
  }
  let rebuilt = match
    @session.Session::replay(
      file.session.sequence(),
      file.session.events(),
      limits=file.session.limits(),
      attempt_limit=file.session.attempt_limit(),
    ) {
    Err(error) => {
      println("replay: failed - \{error.message()}")
      return EXIT_INPUT
    }
    Ok(session) => session
  }
  let same_outcome = rebuilt.outcome() == file.session.outcome()
  let same_events = rebuilt.events() == file.session.events()
  let same_candidates = rebuilt.candidate_span() ==
    file.session.candidate_span()
  if same_outcome && same_events && same_candidates {
    let span = match rebuilt.candidate_span() {
      Some(span) => span_text(span)
      None => "none"
    }
    println(
      "replay: ok (\{rebuilt.events().length()} events, candidates \{span}, outcome \{outcome_name(rebuilt.outcome())})",
    )
    EXIT_OK
  } else {
    println("replay: mismatch between the stored session and a fresh replay")
    EXIT_INPUT
  }
}

///|
fn dispatch(command : String, args : Array[String]) -> Int32 {
  match command {
    "start" => cmd_start(args)
    "record" => cmd_record(args)
    "retract" => cmd_retract(args)
    "next" => cmd_next(args)
    "explain" => cmd_explain(args)
    "replay" => cmd_replay(args)
    "help" | "--help" | "-h" => {
      usage()
      EXIT_OK
    }
    _ => {
      println("error: unknown command: \{command}")
      usage()
      EXIT_USAGE
    }
  }
}

///|
fn main {
  let args = @env.args()
  // On the JS backend the runtime passes its own program and script paths first.
  let code = if args.length() <= 2 {
    usage()
    EXIT_USAGE
  } else {
    let rest : Array[String] = []
    let mut i = 3
    while i < args.length() {
      rest.push(args[i])
      i = i + 1
    }
    dispatch(args[2], rest)
  }
  set_exit_code(code)
}
