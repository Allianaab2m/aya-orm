///|
/// `cairn-kit` — the schema half of cairn.
///
/// Everything with a decision in it lives in the `kit`, `ddl` and `gen`
/// libraries; this file is the part that is allowed to touch the filesystem.
fn main {
  let argv = @env.args()[1:]
  run(argv) catch {
    e => {
      println("cairn-kit: \{e}")
      @sys.exit(1)
    }
  }
}

///|
const USAGE =
  #|cairn-kit — DDL and migrations for cairn entities
  #|
  #|usage:
  #|  cairn-kit generate [--name <slug>]   diff the schema and write a migration
  #|  cairn-kit status                     show what generate would write
  #|  cairn-kit ddl                        print CREATE statements for the whole schema
  #|  cairn-kit codegen [<file> -o <out>]  (re)generate the .g.mbt companions
  #|  cairn-kit init                       write cairn.json and the migrations directory
  #|
  #|options:
  #|  --config <path>    config file (default: cairn.json)
  #|  --schema <path>    file or directory to scan; repeatable, overrides the config
  #|  --out <dir>        migrations directory, overrides the config
  #|  --dialect <name>   sqlite | postgres, overrides the config
  #|

///|
/// Flags collected from the command line, before the config is consulted.
struct Options {
  mut config : String?
  schema : Array[String]
  mut out : String?
  mut dialect : String?
  mut name : String?
  mut output : String?
  positional : Array[String]
}

///|
pub(all) suberror CliError {
  /// An option was given without its value.
  MissingValue(flag~ : String)
  /// An option this command does not have.
  UnknownFlag(flag~ : String)
  /// A subcommand this tool does not have.
  UnknownCommand(name~ : String)
  /// Arguments that do not go together.
  BadUsage(reason~ : String)
  /// A file the command needs is not there.
  NotFound(path~ : String)
}

///|
pub impl Show for CliError with fn output(self, logger) {
  logger.write_string(
    match self {
      MissingValue(flag~) => "`\{flag}` needs a value"
      UnknownFlag(flag~) => "unknown option `\{flag}`"
      UnknownCommand(name~) => "unknown command `\{name}`"
      BadUsage(reason~) => reason
      NotFound(path~) => "\{path}: no such file"
    },
  )
}

///|
fn run(argv : ArrayView[String]) -> Unit raise Error {
  guard argv.length() > 0 else {
    println(USAGE)
    return
  }
  let command = argv[0]
  if command == "help" || command == "--help" || command == "-h" {
    println(USAGE)
    return
  }
  let opts = parse_options(argv[1:])
  let config = load_config(opts)
  match command {
    "generate" => generate(config, opts)
    "status" => status(config, opts)
    "ddl" => print_ddl(config, opts)
    "codegen" => codegen(config, opts)
    "init" => scaffold(config)
    _ => raise UnknownCommand(name=command)
  }
}

///|
fn parse_options(argv : ArrayView[String]) -> Options raise CliError {
  let opts = {
    config: None,
    schema: [],
    out: None,
    dialect: None,
    name: None,
    output: None,
    positional: [],
  }
  let mut i = 0
  fn value(flag : String) -> String raise CliError {
    guard i + 1 < argv.length() else { raise MissingValue(flag~) }
    i = i + 1
    argv[i]
  }

  while i < argv.length() {
    let arg = argv[i]
    match arg {
      "--config" => opts.config = Some(value(arg))
      "--schema" => opts.schema.push(value(arg))
      "--out" => opts.out = Some(value(arg))
      "--dialect" => opts.dialect = Some(value(arg))
      "--name" => opts.name = Some(value(arg))
      "-o" | "--output" => opts.output = Some(value(arg))
      _ =>
        if arg.has_prefix("-") {
          raise UnknownFlag(flag=arg)
        } else {
          opts.positional.push(arg)
        }
    }
    i = i + 1
  }
  opts
}

///|
/// Read the config file, then let the flags override it.
///
/// A missing `cairn.json` is not an error unless it was asked for by name: a
/// single-package project can run the tool with flags alone.
fn load_config(opts : Options) -> @kit.Config raise Error {
  let path = opts.config.unwrap_or(@kit.CONFIG_FILE)
  let base = if @fs.path_exists(path) {
    @kit.Config::from_json_string(@fs.read_file_to_string(path))
  } else if opts.config is Some(_) {
    raise NotFound(path~)
  } else {
    @kit.Config::new()
  }
  {
    dialect: match opts.dialect {
      Some(d) => @ddl.dialect_of_name(d)
      None => base.dialect
    },
    schema: if opts.schema.is_empty() {
      base.schema
    } else {
      opts.schema
    },
    out: opts.out.unwrap_or(base.out),
  }
}

///|
/// Write the next migration, its snapshot, and the journal entry that ties
/// them together.
fn generate(config : @kit.Config, opts : Options) -> Unit raise Error {
  let journal = read_journal(config)
  let previous = read_previous_snapshot(config, journal)
  let next = @kit.snapshot_of_sources(
    read_schema(config),
    dialect=config.dialect,
  )
  let plan = @kit.plan(
    journal~,
    previous~,
    next~,
    now=@env.now().reinterpret_as_int64(),
    name?=opts.name,
  )
  match plan.migration {
    None => println("cairn-kit: no schema changes")
    Some(migration) => {
      ensure_dir(config.out)
      ensure_dir(config.meta_dir())
      // The journal is written last: if anything above fails, the directory
      // still describes a consistent history rather than claiming a migration
      // whose file never landed.
      @fs.write_string_to_file(
        config.migration_path(migration.tag),
        migration.sql,
      )
      @fs.write_string_to_file(
        config.snapshot_path(migration.idx),
        migration.snapshot,
      )
      @fs.write_string_to_file(
        config.journal_path(),
        plan.journal.to_json_string(),
      )
      println(@kit.describe(plan.changes))
      println("cairn-kit: wrote \{config.migration_path(migration.tag)}")
    }
  }
}

///|
/// The same diff as `generate`, without writing anything.
fn status(config : @kit.Config, _opts : Options) -> Unit raise Error {
  let journal = read_journal(config)
  let previous = read_previous_snapshot(config, journal)
  let next = @kit.snapshot_of_sources(
    read_schema(config),
    dialect=config.dialect,
  )
  let changes = @ddl.diff(previous, next)
  println(@kit.describe(changes))
  if !changes.is_empty() {
    println("run `cairn-kit generate` to write the migration")
  }
}

///|
/// The whole schema as `CREATE TABLE` statements, for a fresh database.
fn print_ddl(config : @kit.Config, _opts : Options) -> Unit raise Error {
  let next = @kit.snapshot_of_sources(
    read_schema(config),
    dialect=config.dialect,
  )
  println(
    @ddl.migration_sql(
      @ddl.statements(@ddl.Snapshot::empty(config.dialect), next),
    ).trim_end(chars="\n"),
  )
}

///|
/// Regenerate the `.g.mbt` companion of every schema file.
///
/// With an explicit input the output must be named too: writing next to a file
/// the user pointed at by hand is the kind of surprise a generator should not
/// spring.
fn codegen(config : @kit.Config, opts : Options) -> Unit raise Error {
  match (opts.positional, opts.output) {
    ([], None) => {
      let mut count = 0
      for source in read_schema(config) {
        let (path, text) = source
        // A file with no entities gets no companion: an empty generated file
        // beside every source is noise, and deleting one by hand should not
        // make it come back.
        let specs = @gen.entities_of(text, name=path)
        if specs.is_empty() {
          continue
        }
        @fs.write_string_to_file(companion_path(path), @gen.emit_file(specs))
        count = count + 1
      }
      println("cairn-kit: generated \{count} file(s)")
    }
    ([input], Some(output)) => {
      let source = @fs.read_file_to_string(input)
      @fs.write_string_to_file(output, @gen.generate(source, name=input))
    }
    ([_], None) => raise BadUsage(reason="`codegen <file>` needs `-o <output>`")
    _ => raise BadUsage(reason="`codegen` takes at most one input file")
  }
}

///|
/// Write a config file and an empty migrations directory.
fn scaffold(config : @kit.Config) -> Unit raise Error {
  if !@fs.path_exists(@kit.CONFIG_FILE) {
    @fs.write_string_to_file(@kit.CONFIG_FILE, config.to_json_string())
    println("cairn-kit: wrote \{@kit.CONFIG_FILE}")
  }
  ensure_dir(config.out)
  ensure_dir(config.meta_dir())
  if !@fs.path_exists(config.journal_path()) {
    @fs.write_string_to_file(
      config.journal_path(),
      @kit.Journal::new(config.dialect).to_json_string(),
    )
    println("cairn-kit: wrote \{config.journal_path()}")
  }
}

///|
/// `.../accounts.mbt` -> `.../accounts.g.mbt`
fn companion_path(path : String) -> String {
  if path.has_suffix(".mbt") {
    path[:path.length() - 4].to_owned() + ".g.mbt"
  } else {
    path + ".g.mbt"
  }
}

///|
/// Read the journal, defaulting to an empty history.
fn read_journal(config : @kit.Config) -> @kit.Journal raise Error {
  let path = config.journal_path()
  guard @fs.path_exists(path) else { return @kit.Journal::new(config.dialect) }
  let journal = @kit.Journal::from_json_string(@fs.read_file_to_string(path))
  guard journal.dialect == config.dialect else {
    raise @kit.DialectMismatch(
      journal=@ddl.dialect_name(journal.dialect),
      config=@ddl.dialect_name(config.dialect),
    )
  }
  journal
}

///|
/// The snapshot the last migration left behind.
fn read_previous_snapshot(
  config : @kit.Config,
  journal : @kit.Journal,
) -> @ddl.Snapshot raise Error {
  match journal.last() {
    None => @ddl.Snapshot::empty(config.dialect)
    Some(entry) => {
      let path = config.snapshot_path(entry.idx)
      guard @fs.path_exists(path) else {
        raise @ddl.BadSnapshot(
          reason="\{path} is missing, but the journal lists `\{entry.tag}`",
        )
      }
      @ddl.Snapshot::from_json_string(@fs.read_file_to_string(path))
    }
  }
}

///|
/// Every entity source the config points at, as `(path, contents)`.
fn read_schema(config : @kit.Config) -> Array[(String, String)] raise Error {
  let sources = []
  for path in config.schema {
    guard @fs.path_exists(path) else { raise NotFound(path~) }
    if @fs.is_dir(path) {
      collect_dir(path, sources)
    } else {
      sources.push((path, @fs.read_file_to_string(path)))
    }
  }
  sources.sort_by_key(s => s.0)
  sources
}

///|
/// Walk a directory for entity sources.
///
/// Generated files and test files are skipped: regenerating from a `.g.mbt`
/// would double every table, and a test file has no business defining schema.
fn collect_dir(
  dir : String,
  into : Array[(String, String)],
) -> Unit raise Error {
  for entry in @fs.read_dir(dir) {
    let path = dir + "/" + entry
    if @fs.is_dir(path) {
      collect_dir(path, into)
    } else if is_entity_source(entry) {
      into.push((path, @fs.read_file_to_string(path)))
    }
  }
}

///|
fn is_entity_source(name : String) -> Bool {
  name.has_suffix(".mbt") &&
  !name.has_suffix(".g.mbt") &&
  !name.has_suffix("_test.mbt") &&
  !name.has_suffix("_wbtest.mbt")
}

///|
/// Create a directory and every parent it needs.
fn ensure_dir(path : String) -> Unit raise Error {
  guard !@fs.path_exists(path) else { return }
  match path.rev_split_once("/") {
    Some((parent, _)) => ensure_dir(parent.to_owned())
    None => ()
  }
  @fs.create_dir(path)
}
