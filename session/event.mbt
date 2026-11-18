///| Session model: the append-only event log, and the snapshot that binds it to
/// a commit sequence and a semantic version.
///
/// The log is the source of truth. `Session` is a fold over it, and
/// `Session::restore` is the same fold starting from an empty engine, so a saved
/// investigation can be replayed without keeping any derived state on disk.

///|
/// Semantic version of the inference rules. A snapshot made under different
/// rules is refused instead of being reinterpreted.
pub const SEMANTIC_VERSION : Int32 = 1

///|
/// One entry of the append-only log.
///
/// A correction is a `Retracted` entry, never an in-place edit: the original
/// record keeps its identifier and stays visible in the log.
pub(all) enum Event {
  Recorded(@engine.Observation)
  Retracted(Int32)
} derive(Eq, Debug)

///|
/// Everything needed to rebuild a session, apart from the sequence itself.
///
/// The fields are private. A snapshot is a value that can only be produced by a
/// session, read through accessors that copy the log, and handed back to
/// `Session::restore`; no caller can reach in and change what will be replayed.
pub struct Snapshot {
  priv semantic_version : Int32
  priv digest : String
  priv commit_count : Int32
  priv attempt_limit : Int32
  priv limits : @engine.Limits
  priv events : Array[Event]
} derive(Eq, Debug)

///|
pub fn Snapshot::semantic_version(self : Snapshot) -> Int32 {
  self.semantic_version
}

///|
pub fn Snapshot::digest(self : Snapshot) -> String {
  self.digest
}

///|
pub fn Snapshot::commit_count(self : Snapshot) -> Int32 {
  self.commit_count
}

///|
pub fn Snapshot::attempt_limit(self : Snapshot) -> Int32 {
  self.attempt_limit
}

///|
pub fn Snapshot::limits(self : Snapshot) -> @engine.Limits {
  self.limits
}

///|
/// Copy of the recorded events, in append order.
pub fn Snapshot::events(self : Snapshot) -> Array[Event] {
  self.events.copy()
}

///|
pub(all) enum RestoreError {
  VersionMismatch(Int32, Int32)
  SequenceMismatch(String)
  ReplayRejected(Int32, String)
} derive(Eq, Debug)

///|
pub fn RestoreError::message(self : RestoreError) -> String {
  match self {
    VersionMismatch(found, expected) =>
      "snapshot uses semantic version \{found}, this build implements \{expected}"
    SequenceMismatch(detail) =>
      "snapshot does not belong to this sequence: \{detail}"
    ReplayRejected(event_index, detail) =>
      "event \{event_index} could not be replayed: \{detail}"
  }
}
