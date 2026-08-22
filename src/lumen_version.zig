//! The version `lumen --version` reports.
//!
//! The release workflow overwrites this whole file with the tag before
//! building each archive (see .github/workflows/release.yml), the same way
//! it stamps every other target. A working-tree build never gets that
//! overwrite, so it keeps reporting the dev string below, which is what
//! makes a dev build distinguishable from a release: a real release never
//! reports "dev".
pub const lumen_version = "0.1.0-dev";
