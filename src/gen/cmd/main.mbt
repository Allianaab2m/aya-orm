///|
/// `cairn-gen <input.mbt> -o <output.g.mbt>`
///
/// Kept deliberately thin: the parse/lower/emit pipeline lives in the `gen`
/// library so it can be tested without touching the filesystem.
fn main {
  // `get_cli_args` puts the program path in slot 0.
  let argv = @env.args()[1:]
  match parse_argv(argv) {
    None => {
      println("usage: cairn-gen <input.mbt> -o <output.g.mbt>")
      @sys.exit(2)
    }
    Some((input, output)) =>
      try {
        let source = @fs.read_file_to_string(input)
        @fs.write_string_to_file(output, @gen.generate(source, name=input))
      } catch {
        e => {
          println("cairn-gen: \{input}: \{e}")
          @sys.exit(1)
        }
      }
  }
}

///|
/// Accept `<input> -o <output>` in either order of the flag and its value.
fn parse_argv(argv : ArrayView[String]) -> (String, String)? {
  let positional = []
  let mut output = None
  let mut i = 0
  while i < argv.length() {
    if argv[i] == "-o" || argv[i] == "--output" {
      if i + 1 >= argv.length() {
        return None
      }
      output = Some(argv[i + 1])
      i = i + 2
    } else {
      positional.push(argv[i])
      i = i + 1
    }
  }
  match (positional, output) {
    ([input], Some(out)) => Some((input, out))
    _ => None
  }
}
