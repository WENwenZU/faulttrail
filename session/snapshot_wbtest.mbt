///| White-box tests for state that is deliberately unreachable from outside the
/// package.
///
/// `Snapshot` has no public constructor on purpose: a host must not be able to
/// fabricate a snapshot that `restore` would accept. The version check still
/// exists as a defensive gate, and this test reaches it from inside the package
/// instead of widening the public API for testing.

///|
test "restore refuses a snapshot from another semantic version" {
  let sequence = @version.Sequence::from_ids(["v0", "v1"]).unwrap()
  let session = Session::start(sequence).unwrap()
  let _ = session.observe(0, @engine.Passed)
  let current = session.snapshot()
  let foreign : Snapshot = {
    semantic_version: SEMANTIC_VERSION + 1,
    digest: current.digest(),
    commit_count: current.commit_count(),
    attempt_limit: current.attempt_limit(),
    limits: current.limits(),
    events: current.events(),
  }
  match Session::restore(foreign, sequence) {
    Err(VersionMismatch(found, expected)) => {
      assert_eq(found, SEMANTIC_VERSION + 1)
      assert_eq(expected, SEMANTIC_VERSION)
    }
    _ => assert_true(false)
  }
}
