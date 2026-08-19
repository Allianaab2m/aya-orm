///|
/// The entity is the only hand-written schema definition; `entities.g.mbt` is
/// produced from it by `cairn-gen` during pre-build.
///
/// `pub(all)` matters: callers outside this package build `User` values to
/// hand to `insert`, and a plain `pub` struct is read-only to them.
#cairn.table(name="users", alias="u")
pub(all) struct User {
  #cairn.id
  id : Int
  name : String
  age : Int
  deleted_at : String?
} derive(Debug, Eq)
