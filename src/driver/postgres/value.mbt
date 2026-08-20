// The two conversions between aya's `SqlValue` and the wire.
//
// They are not symmetric, and that asymmetry is the whole content of this file.
// Going out, the *server* decides what type a placeholder has: it infers it
// from where the parameter sits in the statement, and the client then asks
// whether our value can be encoded as that type. So the outgoing direction is
// "here is a value, fit it to the type you were given". Coming back, the row
// description names the type of every column, so the incoming direction is
// "here is a type, produce the matching `SqlValue`".

///|
/// PostgreSQL type OIDs, as far as aya's `SqlValue` reaches.
///
/// Spelled out rather than imported: the client keeps its own copies private,
/// and these five numbers are fixed by PostgreSQL's catalog, not by the client.
const BOOL_OID : UInt = 16

///|
const BYTEA_OID : UInt = 17

///|
const NAME_OID : UInt = 19

///|
const INT8_OID : UInt = 20

///|
const INT2_OID : UInt = 21

///|
const INT4_OID : UInt = 23

///|
const TEXT_OID : UInt = 25

///|
const JSON_OID : UInt = 114

///|
const FLOAT4_OID : UInt = 700

///|
const FLOAT8_OID : UInt = 701

///|
const VARCHAR_OID : UInt = 1043

///|
const JSONB_OID : UInt = 3802

///|
/// A bound parameter.
///
/// The client ships `ToSql` for each MoonBit scalar, but each of those is
/// pinned to one PostgreSQL type — `Int` encodes `int2`/`int4` and `Int64`
/// encodes `int8`. aya erased that distinction upstream: every integer is a
/// `VInt(Int64)` by the time it reaches a driver. So the wrapper exists to put
/// the distinction back, choosing the encoding from the type the server
/// inferred rather than from how wide the MoonBit value happens to be.
pub(all) struct Param(@sql.SqlValue) derive(Eq, Debug)

///|
/// Wrap aya's parameter list for the client.
pub fn params(values : Array[@sql.SqlValue]) -> Array[&@client.ToSql] {
  values.map(v => Param(v) as &@client.ToSql)
}

///|
/// A `NULL` fits any column; anything else has to match what the server
/// inferred, and the scalar impls already know their own types.
pub impl @client.ToSql for Param with fn accepts(self, type_) {
  match self.0 {
    VNull => true
    VInt(_) =>
      match type_.oid {
        INT2_OID | INT4_OID | INT8_OID => true
        _ => false
      }
    VDouble(d) => @client.ToSql::accepts(d, type_)
    VText(s) => @client.ToSql::accepts(s, type_)
    VBool(b) => @client.ToSql::accepts(b, type_)
    VBytes(b) => @client.ToSql::accepts(b, type_)
  }
}

///|
pub impl @client.ToSql for Param with fn moonbit_type_name(self) {
  match self.0 {
    VNull => "SqlValue::VNull"
    VInt(_) => "SqlValue::VInt"
    VDouble(_) => "SqlValue::VDouble"
    VText(_) => "SqlValue::VText"
    VBool(_) => "SqlValue::VBool"
    VBytes(_) => "SqlValue::VBytes"
  }
}

///|
pub impl @client.ToSql for Param with fn to_sql(self, type_, buf) {
  match self.0 {
    VNull => @proto.IsNull::Yes
    // An `int8` column takes the value as it stands; a narrower one goes
    // through `Int`, which is what knows how to write `int2` and `int4`.
    VInt(n) =>
      if type_.oid == INT8_OID {
        @client.ToSql::to_sql(n, type_, buf)
      } else {
        @client.ToSql::to_sql(n.to_int(), type_, buf)
      }
    VDouble(d) => @client.ToSql::to_sql(d, type_, buf)
    VText(s) => @client.ToSql::to_sql(s, type_, buf)
    VBool(b) => @client.ToSql::to_sql(b, type_, buf)
    VBytes(b) => @client.ToSql::to_sql(b, type_, buf)
  }
}

///|
/// Read one column of a result row as the `SqlValue` its PostgreSQL type calls
/// for.
///
/// The column's own type decides, not the value: a driver has to hand aya's
/// decoders the shape they match on, and `SqlDecode for Int` only accepts
/// `VInt`. Types aya has no shape for are refused by name rather than
/// guessed at, because the guess would be a silent wrong answer inside an
/// otherwise type-safe path.
fn cell(
  row : @client.Row,
  index : Int,
  sql : String,
) -> @sql.SqlValue raise @sql.DbError {
  if row.get_raw(index) is None {
    return VNull
  }
  let type_ = row.columns[index].type_
  try {
    match type_.oid {
      BOOL_OID => {
        let b : Bool = row.get(index)
        VBool(b)
      }
      INT2_OID | INT4_OID => {
        let n : Int = row.get(index)
        VInt(n.to_int64())
      }
      INT8_OID => {
        let n : Int64 = row.get(index)
        VInt(n)
      }
      FLOAT4_OID | FLOAT8_OID => {
        let d : Double = row.get(index)
        VDouble(d)
      }
      BYTEA_OID => {
        let b : Bytes = row.get(index)
        VBytes(b)
      }
      JSON_OID | JSONB_OID => {
        let j : Json = row.get(index)
        VText(j.stringify())
      }
      _ =>
        if is_text(type_) {
          let s : String = row.get(index)
          VText(s)
        } else {
          raise @sql.QueryFailed(
            sql~,
            message="column \{index} has PostgreSQL type \"\{type_.name}\", which aya has no SqlValue for; cast it in the query, for example `\{row.columns[index].name}::text`",
          )
        }
    }
  } catch {
    e => raise as_db_error(sql, e)
  }
}

///|
/// The types the client will decode into a `String`.
///
/// Mirrors the client's own notion of a text type, including the ones it
/// recognises by name rather than by OID.
fn is_text(type_ : @client.Type) -> Bool {
  match type_.oid {
    NAME_OID | TEXT_OID | VARCHAR_OID => true
    _ =>
      match type_.name {
        "bpchar" | "citext" | "lquery" | "ltree" | "ltxtquery" | "unknown" =>
          true
        _ => false
      }
  }
}

///|
/// Restate a client failure as one of aya's.
///
/// `DbError` is the whole vocabulary a driver is allowed to fail in, so
/// everything the client can raise has to land in one of its four cases. The
/// split that matters to a caller is "the connection is gone" versus "this
/// statement did not work", and that is the split kept here.
fn as_db_error(sql : String, e : Error) -> @sql.DbError {
  match e {
    @client.Closed(m) | @client.Authentication(m) | @client.Ssl(m) =>
      @sql.ConnectionFailed(m)
    @client.Database(d) =>
      @sql.QueryFailed(
        sql~,
        message=match d.code {
          Some(code) => "\{code}: \{d.message}"
          None => d.message
        },
      )
    @client.WrongType(w) =>
      @sql.QueryFailed(
        sql~,
        message="cannot read PostgreSQL \"\{w.postgres_type.name}\" as \{w.moonbit_type}",
      )
    @client.Protocol(m)
    | @client.Encode(m)
    | @client.Decode(m)
    | @client.ColumnNotFound(m)
    | @client.RowCount(m)
    | @client.UnexpectedMessage(m) => @sql.QueryFailed(sql~, message=m)
    other =>
      @sql.QueryFailed(sql~, message="unexpected client failure: \{other}")
  }
}
