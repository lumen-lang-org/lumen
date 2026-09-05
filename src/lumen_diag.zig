pub const CompileError = error{ ParseError, OutOfMemory };

/// A compile-time diagnostic, located in the .ts source. `extra` carries any
/// further independent diagnostics collected in the same run (the checker
/// continues past a failed statement, capped, so one compile can report
/// several errors).
pub const Diag = struct { line: u32 = 0, col: u32 = 0, msg: []const u8 = "syntax error", extra: []const Diag = &.{} };

/// Origin of one line of a merged (import-inlined) source: the file the user
/// wrote and the line within it.
pub const LineOrigin = struct { file: []const u8, line: u32 };

/// One import edge of the source module graph, by the same file spellings
/// `LineOrigin` uses: `from` inlined `to` (an `import` or a re-export). The
/// node target rebuilds the graph from these (spec 504).
pub const ModuleEdge = struct { from: []const u8, to: []const u8 };

/// Where one source module's JavaScript lands: `file` as `LineOrigin` spells
/// it, `out` the path under the output's `modules/` directory.
pub const ModulePath = struct { file: []const u8, out: []const u8 };

/// A `// @link-node <module.mjs>` pragma on the Node target (spec 507):
/// `file` is the source file that wrote the pragma (as `LineOrigin` spells
/// it), `disk_path` is the shim's resolved location for the compiler to read
/// and copy, and `out` is where the copy lands under the output's `modules/`
/// directory (`link/<basename>`), which the JS emitter also uses to compute
/// the import specifier.
pub const LinkNodeModule = struct { file: []const u8, disk_path: []const u8, out: []const u8 };
