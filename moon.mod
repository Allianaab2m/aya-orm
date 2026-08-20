// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "Allianaab2m/cairn"

version = "0.1.0"

readme = "README.md"

repository = ""

license = "Apache-2.0"

keywords = [ ]

// `native` is the only target the whole dependency graph builds on:
// `moonbit-community/sqlite3` is a native FFI package with no wasm stubs, and
// `moonbitlang/async`'s `raw_fd` package is native-only. `moon doc` checks every
// package in the graph regardless of each package's `supported_targets`, so any
// other preferred target makes `moon doc` fail inside `.mooncakes`.

preferred_target = "native"

description = "A thin, type-safe SQL toolkit for MoonBit"

source = "src"

import {
  "moonbitlang/parser@0.3.17",
  "moonbitlang/x@0.5.0",
  "moonbitlang/async@0.21.0",
  "moonbit-community/sqlite3@0.1.6",
  "moonbit-community/postgres@0.0.7",
}
