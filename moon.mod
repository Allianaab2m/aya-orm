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

name = "Allianaab2m/aya"

version = "0.1.0" // x-release-please-version

readme = "README.md"

repository = "https://github.com/Allianaab2m/aya-orm"

license = "Apache-2.0"

keywords = [ ]

// `native` is the only target the whole dependency graph builds on:
// `moonbitlang/async`'s `raw_fd` package is native-only, and aya's execution
// layer is async throughout. `moon doc` checks every package in the graph
// regardless of each package's `supported_targets`, so any other preferred
// target makes `moon doc` fail inside `.mooncakes`.

preferred_target = "native"

description = "A thin, type-safe SQL toolkit for MoonBit"

source = "src"

import {
  "moonbitlang/parser@0.3.17",
  "moonbitlang/x@0.5.0",
  "moonbitlang/async@0.21.0",
  "moonbit-community/sqlite3@0.2.0",
  "moonbit-community/postgres@0.0.7",
}
