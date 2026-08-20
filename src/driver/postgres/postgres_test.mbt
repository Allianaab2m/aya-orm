// What can be checked without a server is the translation either side of the
// wire, and that is where the driver's own judgement lives. The statements
// themselves are cairn's, and the protocol is the client's; neither is retested
// here.

///|
/// The integer width is the server's to choose, not the value's.
///
/// This is the reason `Param` exists at all: cairn only has `VInt(Int64)`, so
/// without it every integer would claim to be an `int8` and every `int4`
/// column would reject it.
test "an integer parameter fits any integer column" {
  let n = Param::Param(@sql.VInt(7))
  assert_true(@client.ToSql::accepts(n, @client.Type::int2()))
  assert_true(@client.ToSql::accepts(n, @client.Type::int4()))
  assert_true(@client.ToSql::accepts(n, @client.Type::int8()))
  assert_false(@client.ToSql::accepts(n, @client.Type::text()))
  assert_false(@client.ToSql::accepts(n, @client.Type::bool()))
}

///|
/// And the encoding follows the column, so the same value goes out two, four
/// or eight bytes wide.
test "an integer parameter is encoded at the column's width" {
  fn width(type_) raise {
    let buf = @buffer.Buffer::Buffer()
    let is_null = @client.ToSql::to_sql(Param::Param(@sql.VInt(7)), type_, buf)
    (is_null is Yes, buf.length())
  }

  debug_inspect(width(@client.Type::int2()), content="(false, 2)")
  debug_inspect(width(@client.Type::int4()), content="(false, 4)")
  debug_inspect(width(@client.Type::int8()), content="(false, 8)")
}

///|
/// A `NULL` has no type of its own, so it has to be accepted wherever it is
/// put. Nothing is written for it: the length prefix in front of the parameter
/// is what says NULL, which is what `Yes` reports back.
test "a null parameter fits any column and writes nothing" {
  let null = Param::Param(@sql.VNull)
  for
    type_ in [
      @client.Type::int4(),
      @client.Type::text(),
      @client.Type::bool(),
      @client.Type::timestamptz(),
    ] {
    assert_true(@client.ToSql::accepts(null, type_))
  }
  let buf = @buffer.Buffer::Buffer()
  let is_null = @client.ToSql::to_sql(null, @client.Type::text(), buf)
  debug_inspect((is_null is Yes, buf.length()), content="(true, 0)")
}

///|
/// The remaining scalars defer to the client's own impls, so they are as
/// narrow as those are: text is not silently acceptable as a date.
test "the other scalars keep the client's own type rules" {
  assert_true(
    @client.ToSql::accepts(
      Param::Param(@sql.VText("x")),
      @client.Type::varchar(),
    ),
  )
  assert_false(
    @client.ToSql::accepts(
      Param::Param(@sql.VText("2026-08-20")),
      @client.Type::date(),
    ),
  )
  assert_true(
    @client.ToSql::accepts(Param::Param(@sql.VBool(true)), @client.Type::bool()),
  )
  assert_true(
    @client.ToSql::accepts(
      Param::Param(@sql.VDouble(1.5)),
      @client.Type::float8(),
    ),
  )
  assert_true(
    @client.ToSql::accepts(
      Param::Param(@sql.VBytes(b"\x00")),
      @client.Type::bytea(),
    ),
  )
}

///|
/// cairn hands a driver one flat parameter list, and it comes back out in the
/// same order — the placeholders are numbered, so order is all that connects
/// the two.
test "the parameter list keeps its order" {
  let ps = params([@sql.VInt(1), @sql.VNull, @sql.VText("alice")])
  inspect(ps.length(), content="3")
  debug_inspect(
    ps.map(p => @client.ToSql::moonbit_type_name(p)),
    content=(
      #|["SqlValue::VInt", "SqlValue::VNull", "SqlValue::VText"]
    ),
  )
}

///|
/// The database defaults to the user's own, the way `psql` does.
test "config fills in the usual defaults" {
  let c = config(host="localhost", user="alliana")
  inspect(c.database, content="alliana")
  inspect(c.port, content="5432")
  inspect(c.application_name, content="cairn")
  inspect(
    config(host="localhost", user="alliana", database="cairn").database,
    content="cairn",
  )
}
