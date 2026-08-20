///|
/// Some PostgreSQL types are text but have no fixed OID, so the client
/// recognises them by name. A driver that only looked at OIDs would refuse a
/// `citext` column that the client would happily have decoded.
test "text columns are recognised by OID and by name" {
  assert_true(is_text(@client.Type::text()))
  assert_true(is_text(@client.Type::varchar()))
  assert_true(is_text(@client.Type::name_type()))
  assert_true(is_text(@client.Type::unknown(16385, name="citext")))
  assert_false(is_text(@client.Type::int4()))
  assert_false(is_text(@client.Type::unknown(16386, name="hstore")))
}

///|
suberror Unexpected {
  Unexpected(String)
}

///|
/// `DbError` is the whole vocabulary a driver may fail in, so the translation
/// has to be total: an error from somewhere the client did not anticipate
/// still has to come out as one of cairn's, not escape as itself.
test "an unrecognised failure still becomes a DbError" {
  debug_inspect(
    as_db_error("SELECT 1", Unexpected("socket vanished")),
    content=(
      #|QueryFailed(
      #|  sql="SELECT 1",
      #|  message="unexpected client failure: Allianaab2m/cairn/driver/postgres.Unexpected.Unexpected",
      #|)
    ),
  )
}
