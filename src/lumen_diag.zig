pub const CompileError = error{ ParseError, OutOfMemory };

/// A compile-time diagnostic, located in the .ts source. `extra` carries any
/// further independent diagnostics collected in the same run (the checker
/// continues past a failed statement, capped, so one compile can report
/// several errors).
pub const Diag = struct { line: u32 = 0, col: u32 = 0, msg: []const u8 = "syntax error", extra: []const Diag = &.{} };
