///|
/// A foreign key declared on a column, e.g.
/// `#aya.column(references="accounts.id", on_delete="cascade")`.
pub struct RefSpec {
  /// Referenced table name (the database name, not the MoonBit type).
  table : String
  /// Referenced column name.
  column : String
  /// Referential action, already normalised to upper case, e.g. `CASCADE`.
  on_delete : String?
  on_update : String?
} derive(Debug, Eq)

///|
/// One column of an entity, in the order it was declared.
///
/// Declaration order is load-bearing: it fixes both the projection order and
/// the positional decoder, which is exactly the pairing a hand-written
/// `Selection` can get wrong.
pub struct FieldSpec {
  /// MoonBit field name, e.g. `deleted_at`.
  name : String
  /// MoonBit type rendered back to source, e.g. `String?`.
  ty : String
  /// Database column name. Defaults to `name`.
  column : String
  is_primary : Bool
  /// `true` when the declared MoonBit type is an `Option`.
  ///
  /// Nullability is read off the type rather than off an attribute: the type
  /// is what the decoder already believes, so letting an attribute contradict
  /// it would let the schema and the row type disagree silently.
  nullable : Bool
  /// SQL type text from `#aya.column(type="...")`.
  ///
  /// `None` means "infer from the MoonBit type", which only works for the
  /// types `SqlEncode` covers. A wrapper type has to say what it stores.
  sql_type : String?
  /// Raw SQL expression from `#aya.column(default="...")`, emitted verbatim
  /// after `DEFAULT`.
  default_sql : String?
  unique : Bool
  autoincrement : Bool
  references : RefSpec?
} derive(Debug, Eq)

///|
/// A secondary index declared on the entity with `#aya.index(...)`.
pub struct IndexSpec {
  name : String
  /// Database column names, in index order.
  columns : Array[String]
  unique : Bool
} derive(Debug, Eq)

///|
/// A struct carrying `#aya.table`, lowered into everything the emitter needs.
///
/// This describes the *row type*: the flat shape of one database row. A domain
/// type is a separate thing that the programmer maps to and from.
pub struct EntitySpec {
  /// MoonBit type name, e.g. `User`.
  type_name : String
  /// Table name in the database.
  table : String
  /// Table alias used when emitting SQL.
  tbl : String
  /// Name of the generated column-handle struct.
  cols_name : String
  fields : Array[FieldSpec]
  indexes : Array[IndexSpec]
} derive(Debug, Eq)

///|
pub(all) suberror EntityError {
  /// A `#aya.table` was found on something that is not a record struct.
  NotARecord(type_name~ : String)
  /// `#aya.table` needs a table name and no default is safe to invent.
  MissingTable(type_name~ : String)
  /// More than one field claimed `#aya.id`.
  DuplicatePrimaryKey(type_name~ : String)
  /// An attribute argument was present but not a value this generator accepts.
  InvalidArg(type_name~ : String, key~ : String, value~ : String)
  /// `#aya.index` named a field the struct does not have.
  UnknownIndexColumn(type_name~ : String, column~ : String)
  /// `#aya.index` without any column to index.
  EmptyIndex(type_name~ : String)
  /// An argument name the MoonBit toolchain cannot round-trip.
  ReservedArg(type_name~ : String, key~ : String, use_instead~ : String)
} derive(Debug)

///|
/// Collect every `#aya.table` declaration in a parsed file.
///
/// Declarations without the attribute are skipped, so an entity file may hold
/// ordinary MoonBit code alongside entities.
pub fn collect_entities(
  impls : @list.List[@syntax.Impl],
) -> Array[EntitySpec] raise Error {
  let specs = []
  for im in impls {
    if im is TopTypeDef(decl) {
      if entity_attr(decl.attrs) is Some(attr) {
        specs.push(lower_entity(decl, attr))
      }
    }
  }
  specs
}

///|
/// Find the `#aya.table` attribute among a declaration's attributes.
fn entity_attr(
  attrs : @list.List[@attribute.Attribute],
) -> Attr? raise AttrError {
  for a in attrs {
    if parse_attr(a.raw) is Some(parsed) && parsed.name == "table" {
      return Some(parsed)
    }
  }
  None
}

///|
/// Lower one annotated struct into an `EntitySpec`.
fn lower_entity(decl : @syntax.TypeDecl, attr : Attr) -> EntitySpec raise Error {
  let type_name = decl.tycon
  guard decl.components is Record(fields~) else { raise NotARecord(type_name~) }
  let table = match attr.arg("name") {
    Some(t) => t
    None => raise MissingTable(type_name~)
  }
  // The alias is what shows up in `FROM "users" AS u`, so a short default
  // beats a generated one that changes whenever the type is renamed.
  let tbl = attr.arg("alias").unwrap_or(default_alias(table))
  // Derived by suffix rather than by stripping anything from the type name:
  // guessing that `OrderRow` "means" `Order` would be magic. Override with
  // `cols="..."` when the default reads badly.
  let cols_name = attr.arg("cols").unwrap_or(type_name + "Cols")
  let specs = []
  let mut seen_primary = false
  for f in fields {
    let name = f.name.label
    let mut column = name
    let mut is_primary = false
    let mut sql_type = None
    let mut default_sql = None
    let mut unique = false
    let mut autoincrement = false
    let mut references = None
    for a in f.attrs {
      if parse_attr(a.raw) is Some(parsed) {
        match parsed.name {
          "id" => {
            if seen_primary {
              raise DuplicatePrimaryKey(type_name~)
            }
            seen_primary = true
            is_primary = true
          }
          "column" => {
            if parsed.arg("name") is Some(n) {
              column = n
            }
            // Not `type=`: `moon fmt` rewrites `#aya.column(type="...")`
            // into `##aya.column(...)`, which then fails to lex. Rejecting it
            // here costs one error message; accepting it costs a file that
            // stops compiling the next time someone formats it.
            if parsed.arg("type") is Some(_) {
              raise ReservedArg(type_name~, key="type", use_instead="sql_type")
            }
            sql_type = parsed.arg("sql_type")
            default_sql = parsed.arg("default")
            unique = attr_bool(parsed, "unique", type_name)
            autoincrement = attr_bool(parsed, "autoincrement", type_name)
            references = lower_ref(parsed, type_name)
          }
          // Unknown names are ignored on purpose so that adding an attribute
          // does not break older generators.
          _ => ()
        }
      }
    }
    specs.push({
      name,
      ty: render_type(f.ty),
      column,
      is_primary,
      nullable: f.ty is Option(_),
      sql_type,
      default_sql,
      unique,
      autoincrement,
      references,
    })
  }
  {
    type_name,
    table,
    tbl,
    cols_name,
    fields: specs,
    indexes: lower_indexes(decl.attrs, type_name, table, specs),
  }
}

///|
/// Read an attribute argument that must be `"true"` or `"false"`.
///
/// A typo like `unique="yes"` is rejected rather than read as `false`: a
/// silently dropped constraint is exactly the kind of drift a migration tool
/// exists to prevent.
fn attr_bool(
  attr : Attr,
  key : String,
  type_name : String,
) -> Bool raise EntityError {
  match attr.arg(key) {
    None => false
    Some(v) =>
      if v == "true" {
        true
      } else if v == "false" {
        false
      } else {
        raise InvalidArg(type_name~, key~, value=v)
      }
  }
}

///|
/// Lower `references="accounts.id"` plus its optional referential actions.
fn lower_ref(attr : Attr, type_name : String) -> RefSpec? raise EntityError {
  guard attr.arg("references") is Some(target) else { return None }
  guard target.split_once(".") is Some((table, column)) else {
    raise InvalidArg(type_name~, key="references", value=target)
  }
  guard !table.is_empty() && !column.is_empty() else {
    raise InvalidArg(type_name~, key="references", value=target)
  }
  Some({
    table: table.to_owned(),
    column: column.to_owned(),
    on_delete: ref_action(attr, "on_delete", type_name),
    on_update: ref_action(attr, "on_update", type_name),
  })
}

///|
/// Normalise a referential action, rejecting anything SQL does not define.
fn ref_action(
  attr : Attr,
  key : String,
  type_name : String,
) -> String? raise EntityError {
  guard attr.arg(key) is Some(raw) else { return None }
  let action = raw.trim().to_upper().to_owned()
  let known = ["CASCADE", "RESTRICT", "SET NULL", "SET DEFAULT", "NO ACTION"]
  if known.contains(action) {
    Some(action)
  } else {
    raise InvalidArg(type_name~, key~, value=raw)
  }
}

///|
/// Lower every `#aya.index(...)` on the declaration.
///
/// Columns are named by MoonBit field, not by database column, so renaming a
/// column with `#aya.column(name=...)` does not silently break its index.
fn lower_indexes(
  attrs : @list.List[@attribute.Attribute],
  type_name : String,
  table : String,
  fields : Array[FieldSpec],
) -> Array[IndexSpec] raise Error {
  let indexes = []
  for a in attrs {
    guard parse_attr(a.raw) is Some(parsed) && parsed.name == "index" else {
      continue
    }
    let columns = []
    for part in parsed.arg("columns").unwrap_or("").split(",") {
      let field = part.trim().to_owned()
      if field.is_empty() {
        continue
      }
      match fields.search_by(f => f.name == field) {
        Some(i) => columns.push(fields[i].column)
        None => raise UnknownIndexColumn(type_name~, column=field)
      }
    }
    if columns.is_empty() {
      raise EmptyIndex(type_name~)
    }
    indexes.push({
      name: parsed.arg("name").unwrap_or(default_index_name(table, columns)),
      columns,
      unique: attr_bool(parsed, "unique", type_name),
    })
  }
  indexes
}

///|
/// Derive an index name from what it indexes: `idx_users_email`.
fn default_index_name(table : String, columns : Array[String]) -> String {
  "idx_" + table + "_" + columns.join("_")
}

///|
/// Derive a table alias from a table name: `users` -> `u`.
fn default_alias(table : String) -> String {
  if table.is_empty() {
    "t"
  } else {
    table[:1].to_owned()
  }
}

///|
/// Render a parsed type back to MoonBit source text.
///
/// The emitter needs the type twice, once inside `Column[_]` and once as the
/// entity field type, so the round trip has to be faithful for the types aya
/// can actually store.
pub fn render_type(t : @syntax.Type) -> String {
  match t {
    Name(constr_id~, tys~, ..) => {
      let base = match constr_id.id {
        Ident(name~) => name
        Dot(pkg~, id~) => "@\{pkg}.\{id}"
      }
      if tys.is_empty() {
        base
      } else {
        base + "[" + tys.map(render_type).to_array().join(", ") + "]"
      }
    }
    Option(ty~, ..) => render_type(ty) + "?"
    Tuple(tys~, ..) => "(" + tys.map(render_type).to_array().join(", ") + ")"
    // Arrows, object types and `_` cannot be stored in a column, so leaving
    // them unrendered surfaces as a compile error in the generated file rather
    // than as a silently wrong column type.
    _ => "_"
  }
}

///|
pub impl Show for EntityError with fn output(self, logger) {
  logger.write_string(
    match self {
      NotARecord(type_name~) =>
        "`\{type_name}`: #aya.table only goes on a record struct"
      MissingTable(type_name~) =>
        "`\{type_name}`: #aya.table needs `name=\"...\"`"
      DuplicatePrimaryKey(type_name~) =>
        "`\{type_name}`: more than one field is marked #aya.id"
      InvalidArg(type_name~, key~, value~) =>
        "`\{type_name}`: `\{key}=\"\{value}\"` is not a value aya accepts"
      UnknownIndexColumn(type_name~, column~) =>
        "`\{type_name}`: #aya.index names `\{column}`, which is not a field"
      EmptyIndex(type_name~) => "`\{type_name}`: #aya.index has no columns"
      ReservedArg(type_name~, key~, use_instead~) =>
        "`\{type_name}`: `\{key}=` cannot be used in an attribute, because `moon fmt` rewrites it into something that will not lex; write `\{use_instead}=` instead"
    },
  )
}
