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
} derive(Debug, Eq)

///|
/// A struct carrying `#cairn.table`, lowered into everything the emitter needs.
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
} derive(Debug, Eq)

///|
pub(all) suberror EntityError {
  /// A `#cairn.table` was found on something that is not a record struct.
  NotARecord(type_name~ : String)
  /// `#cairn.table` needs a table name and no default is safe to invent.
  MissingTable(type_name~ : String)
  /// More than one field claimed `#cairn.id`.
  DuplicatePrimaryKey(type_name~ : String)
} derive(Debug)

///|
/// Collect every `#cairn.table` declaration in a parsed file.
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
/// Find the `#cairn.table` attribute among a declaration's attributes.
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
          "column" => if parsed.arg("name") is Some(n) { column = n }
          // TODO: index / unique / constraint / foreign_key live here once the
          // runtime can represent them. Unknown names are ignored on purpose so
          // that adding an attribute does not break older generators.
          _ => ()
        }
      }
    }
    specs.push({ name, ty: render_type(f.ty), column, is_primary })
  }
  { type_name, table, tbl, cols_name, fields: specs }
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
/// entity field type, so the round trip has to be faithful for the types cairn
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
