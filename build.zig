const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "lumen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lumen.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // The canonical ambient declarations live at the repo root (`/lumen.d.ts`)
    // so editors/tsc pick them up. `lumen init` embeds them via this anonymous
    // import, keeping a single source of truth (the file is outside `src/`, so a
    // bare `@embedFile("../lumen.d.ts")` is rejected by the package boundary).
    exe.root_module.addAnonymousImport("lumen.d.ts", .{
        .root_source_file = b.path("lumen.d.ts"),
    });
    b.installArtifact(exe);

    const conformance_runner = b.addExecutable(.{
        .name = "lumen-conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/lumen_conformance.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the Lumen compiler");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run compiler tests");
    test_step.dependOn(&run_exe_tests.step);

    // Tests in a module the root does not pull into the test build are never
    // run, and a suite that silently does not run is worse than none: sixteen
    // of the compiler's twenty-two tests were in that state. Each file with
    // tests of its own is compiled and run explicitly.
    const test_roots = [_][]const u8{
        "src/lumen_lexer.zig",
        "src/lumen_describe.zig",
        "src/lumen_decorator.zig",
        "src/regex_rt.zig",
    };
    for (test_roots) |root| {
        const unit = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(root),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(unit).step);
    }

    const fmt_targets = [_][]const u8{
        "build.zig",
        "src/lumen.zig",
        "src/lumen_ast.zig",
        "src/lumen_check.zig",
        "src/lumen_check_stdlib.zig",
        "src/lumen_check_generics.zig",
        "src/lumen_check_class.zig",
        "src/lumen_check_stmt.zig",
        "src/lumen_check_assign.zig",
        "src/lumen_check_expr.zig",
        "src/lumen_check_stdlib.zig",
        "src/lumen_decorator.zig",
        "src/lumen_describe.zig",
        "src/lumen_diag.zig",
        "src/lumen_lexer.zig",
        "src/lumen_types.zig",
        "src/lumen_compiler.zig",
        "src/lumen_parser.zig",
        "src/lumen_parser_expr.zig",
        "src/lumen_parser_decl.zig",
        "src/lumen_opt.zig",
        "src/lumen_emit.zig",
        "src/lumen_emit_analysis.zig",
        "src/lumen_emit_array_string.zig",
        "src/lumen_emit_class.zig",
        "src/lumen_emit_stmt.zig",
        "src/regex_rt.zig",
        "src/regex_specialize.zig",
        "tools/lumen_conformance.zig",
    };

    const fmt = b.addSystemCommand(&[_][]const u8{ "zig", "fmt" });
    fmt.addArgs(&fmt_targets);
    const fmt_step = b.step("fmt", "Format compiler sources with zig fmt");
    fmt_step.dependOn(&fmt.step);

    const fmt_check = b.addSystemCommand(&[_][]const u8{ "zig", "fmt", "--check" });
    fmt_check.addArgs(&fmt_targets);
    const fmt_check_step = b.step("fmt-check", "Verify compiler source formatting");
    fmt_check_step.dependOn(&fmt_check.step);

    const lint_step = b.step("lint", "Run compiler lint checks");
    lint_step.dependOn(&fmt_check.step);

    const conformance_cmd = b.addRunArtifact(conformance_runner);
    conformance_cmd.step.dependOn(b.getInstallStep());
    conformance_cmd.addArg("specs/001-typescript-to-zig-native/conformance/manifest.json");
    conformance_cmd.addArg("zig-out/bin/lumen");

    const conformance_cmd_002 = b.addRunArtifact(conformance_runner);
    conformance_cmd_002.step.dependOn(b.getInstallStep());
    conformance_cmd_002.addArg("specs/002-numeric-literals-lexer/conformance/manifest.json");
    conformance_cmd_002.addArg("zig-out/bin/lumen");

    const conformance_cmd_003 = b.addRunArtifact(conformance_runner);
    conformance_cmd_003.step.dependOn(b.getInstallStep());
    conformance_cmd_003.addArg("specs/003-iteration-enums-ops/conformance/manifest.json");
    conformance_cmd_003.addArg("zig-out/bin/lumen");

    const conformance_cmd_004 = b.addRunArtifact(conformance_runner);
    conformance_cmd_004.step.dependOn(b.getInstallStep());
    conformance_cmd_004.addArg("specs/004-nullability/conformance/manifest.json");
    conformance_cmd_004.addArg("zig-out/bin/lumen");

    const conformance_cmd_005 = b.addRunArtifact(conformance_runner);
    conformance_cmd_005.step.dependOn(b.getInstallStep());
    conformance_cmd_005.addArg("specs/005-unions-destructuring-templates/conformance/manifest.json");
    conformance_cmd_005.addArg("zig-out/bin/lumen");

    const conformance_cmd_006 = b.addRunArtifact(conformance_runner);
    conformance_cmd_006.step.dependOn(b.getInstallStep());
    conformance_cmd_006.addArg("specs/006-functions-closures/conformance/manifest.json");
    conformance_cmd_006.addArg("zig-out/bin/lumen");

    const conformance_cmd_007 = b.addRunArtifact(conformance_runner);
    conformance_cmd_007.step.dependOn(b.getInstallStep());
    conformance_cmd_007.addArg("specs/007-defer/conformance/manifest.json");
    conformance_cmd_007.addArg("zig-out/bin/lumen");

    const conformance_cmd_008 = b.addRunArtifact(conformance_runner);
    conformance_cmd_008.step.dependOn(b.getInstallStep());
    conformance_cmd_008.addArg("specs/008-test/conformance/manifest.json");
    conformance_cmd_008.addArg("zig-out/bin/lumen");

    const conformance_cmd_009 = b.addRunArtifact(conformance_runner);
    conformance_cmd_009.step.dependOn(b.getInstallStep());
    conformance_cmd_009.addArg("specs/009-ffi/conformance/manifest.json");
    conformance_cmd_009.addArg("zig-out/bin/lumen");

    const conformance_cmd_010 = b.addRunArtifact(conformance_runner);
    conformance_cmd_010.step.dependOn(b.getInstallStep());
    conformance_cmd_010.addArg("specs/010-classes/conformance/manifest.json");
    conformance_cmd_010.addArg("zig-out/bin/lumen");

    const conformance_cmd_013 = b.addRunArtifact(conformance_runner);
    conformance_cmd_013.step.dependOn(b.getInstallStep());
    conformance_cmd_013.addArg("specs/013-array-methods/conformance/manifest.json");
    conformance_cmd_013.addArg("zig-out/bin/lumen");

    const conformance_cmd_014 = b.addRunArtifact(conformance_runner);
    conformance_cmd_014.step.dependOn(b.getInstallStep());
    conformance_cmd_014.addArg("specs/014-string-methods/conformance/manifest.json");
    conformance_cmd_014.addArg("zig-out/bin/lumen");

    const conformance_cmd_015 = b.addRunArtifact(conformance_runner);
    conformance_cmd_015.step.dependOn(b.getInstallStep());
    conformance_cmd_015.addArg("specs/015-multi-symbol-modules/conformance/manifest.json");
    conformance_cmd_015.addArg("zig-out/bin/lumen");

    const conformance_cmd_016 = b.addRunArtifact(conformance_runner);
    conformance_cmd_016.step.dependOn(b.getInstallStep());
    conformance_cmd_016.addArg("specs/016-generics/conformance/manifest.json");
    conformance_cmd_016.addArg("zig-out/bin/lumen");

    const conformance_cmd_017 = b.addRunArtifact(conformance_runner);
    conformance_cmd_017.step.dependOn(b.getInstallStep());
    conformance_cmd_017.addArg("specs/017-type-aliases-unions/conformance/manifest.json");
    conformance_cmd_017.addArg("zig-out/bin/lumen");

    const conformance_cmd_018 = b.addRunArtifact(conformance_runner);
    conformance_cmd_018.step.dependOn(b.getInstallStep());
    conformance_cmd_018.addArg("specs/018-class-inheritance-members/conformance/manifest.json");
    conformance_cmd_018.addArg("zig-out/bin/lumen");

    const conformance_cmd_019 = b.addRunArtifact(conformance_runner);
    conformance_cmd_019.step.dependOn(b.getInstallStep());
    conformance_cmd_019.addArg("specs/019-error-handling/conformance/manifest.json");
    conformance_cmd_019.addArg("zig-out/bin/lumen");

    const conformance_cmd_020 = b.addRunArtifact(conformance_runner);
    conformance_cmd_020.step.dependOn(b.getInstallStep());
    conformance_cmd_020.addArg("specs/020-map-set-tuples/conformance/manifest.json");
    conformance_cmd_020.addArg("zig-out/bin/lumen");

    const conformance_cmd_021 = b.addRunArtifact(conformance_runner);
    conformance_cmd_021.step.dependOn(b.getInstallStep());
    conformance_cmd_021.addArg("specs/021-spread-rest-defaults/conformance/manifest.json");
    conformance_cmd_021.addArg("zig-out/bin/lumen");

    const conformance_cmd_022 = b.addRunArtifact(conformance_runner);
    conformance_cmd_022.step.dependOn(b.getInstallStep());
    conformance_cmd_022.addArg("specs/022-async-await/conformance/manifest.json");
    conformance_cmd_022.addArg("zig-out/bin/lumen");

    const conformance_cmd_023 = b.addRunArtifact(conformance_runner);
    conformance_cmd_023.step.dependOn(b.getInstallStep());
    conformance_cmd_023.addArg("specs/023-ffi-strings/conformance/manifest.json");
    conformance_cmd_023.addArg("zig-out/bin/lumen");

    const conformance_cmd_024 = b.addRunArtifact(conformance_runner);
    conformance_cmd_024.step.dependOn(b.getInstallStep());
    conformance_cmd_024.addArg("specs/024-ref-params/conformance/manifest.json");
    conformance_cmd_024.addArg("zig-out/bin/lumen");

    const conformance_cmd_025 = b.addRunArtifact(conformance_runner);
    conformance_cmd_025.step.dependOn(b.getInstallStep());
    conformance_cmd_025.addArg("specs/025-declare-ffi/conformance/manifest.json");
    conformance_cmd_025.addArg("zig-out/bin/lumen");

    const conformance_cmd_027 = b.addRunArtifact(conformance_runner);
    conformance_cmd_027.step.dependOn(b.getInstallStep());
    conformance_cmd_027.addArg("specs/027-using-disposables/conformance/manifest.json");
    conformance_cmd_027.addArg("zig-out/bin/lumen");

    const conformance_cmd_028 = b.addRunArtifact(conformance_runner);
    conformance_cmd_028.step.dependOn(b.getInstallStep());
    conformance_cmd_028.addArg("specs/028-test-fn/conformance/manifest.json");
    conformance_cmd_028.addArg("zig-out/bin/lumen");

    const conformance_cmd_449 = b.addRunArtifact(conformance_runner);
    conformance_cmd_449.step.dependOn(b.getInstallStep());
    conformance_cmd_449.addArg("specs/449-module-level-bindings-in-tests/conformance/manifest.json");
    conformance_cmd_449.addArg("zig-out/bin/lumen");

    const conformance_cmd_450 = b.addRunArtifact(conformance_runner);
    conformance_cmd_450.step.dependOn(b.getInstallStep());
    conformance_cmd_450.addArg("specs/450-persistent-subprocess/conformance/manifest.json");
    conformance_cmd_450.addArg("zig-out/bin/lumen");

    const conformance_cmd_451 = b.addRunArtifact(conformance_runner);
    conformance_cmd_451.step.dependOn(b.getInstallStep());
    conformance_cmd_451.addArg("specs/451-exported-types-and-module-scoped-imports/conformance/manifest.json");
    conformance_cmd_451.addArg("zig-out/bin/lumen");

    const conformance_cmd_455 = b.addRunArtifact(conformance_runner);
    conformance_cmd_455.step.dependOn(b.getInstallStep());
    conformance_cmd_455.addArg("specs/455-decorators/conformance/manifest.json");
    conformance_cmd_455.addArg("zig-out/bin/lumen");

    const conformance_cmd_459h = b.addRunArtifact(conformance_runner);
    conformance_cmd_459h.step.dependOn(b.getInstallStep());
    conformance_cmd_459h.addArg("specs/459-http-request-headers/conformance/manifest.json");
    conformance_cmd_459h.addArg("zig-out/bin/lumen");

    const conformance_cmd_459 = b.addRunArtifact(conformance_runner);
    conformance_cmd_459.step.dependOn(b.getInstallStep());
    conformance_cmd_459.addArg("specs/459-method-descriptions/conformance/manifest.json");
    conformance_cmd_459.addArg("zig-out/bin/lumen");
    const conformance_cmd_456 = b.addRunArtifact(conformance_runner);
    conformance_cmd_456.step.dependOn(b.getInstallStep());
    conformance_cmd_456.addArg("specs/456-json-for-classes/conformance/manifest.json");
    conformance_cmd_456.addArg("zig-out/bin/lumen");

    const conformance_cmd_461 = b.addRunArtifact(conformance_runner);
    conformance_cmd_461.step.dependOn(b.getInstallStep());
    conformance_cmd_461.addArg("specs/461-parameter-shadowing/conformance/manifest.json");
    conformance_cmd_461.addArg("zig-out/bin/lumen");

    const conformance_cmd_453 = b.addRunArtifact(conformance_runner);
    conformance_cmd_453.step.dependOn(b.getInstallStep());
    conformance_cmd_453.addArg("specs/453-ref-for-value-types/conformance/manifest.json");
    conformance_cmd_453.addArg("zig-out/bin/lumen");

    const conformance_cmd_464 = b.addRunArtifact(conformance_runner);
    conformance_cmd_464.step.dependOn(b.getInstallStep());
    conformance_cmd_464.addArg("specs/464-generated-temporaries/conformance/manifest.json");
    conformance_cmd_464.addArg("zig-out/bin/lumen");

    const conformance_cmd_458 = b.addRunArtifact(conformance_runner);
    conformance_cmd_458.step.dependOn(b.getInstallStep());
    conformance_cmd_458.addArg("specs/458-embed-file/conformance/manifest.json");
    conformance_cmd_458.addArg("zig-out/bin/lumen");

    const conformance_cmd_452 = b.addRunArtifact(conformance_runner);
    conformance_cmd_452.step.dependOn(b.getInstallStep());
    conformance_cmd_452.addArg("specs/452-streaming-http/conformance/manifest.json");
    conformance_cmd_452.addArg("zig-out/bin/lumen");

    const conformance_cmd_467 = b.addRunArtifact(conformance_runner);
    conformance_cmd_467.step.dependOn(b.getInstallStep());
    conformance_cmd_467.addArg("specs/467-crypto-aead/conformance/manifest.json");
    conformance_cmd_467.addArg("zig-out/bin/lumen");

    const conformance_cmd_468 = b.addRunArtifact(conformance_runner);
    conformance_cmd_468.step.dependOn(b.getInstallStep());
    conformance_cmd_468.addArg("specs/468-thread-safe-arena/conformance/manifest.json");
    conformance_cmd_468.addArg("zig-out/bin/lumen");

    const conformance_cmd_474 = b.addRunArtifact(conformance_runner);
    conformance_cmd_474.step.dependOn(b.getInstallStep());
    conformance_cmd_474.addArg("specs/474-sha1-for-websocket/conformance/manifest.json");
    conformance_cmd_474.addArg("zig-out/bin/lumen");

    const conformance_cmd_475 = b.addRunArtifact(conformance_runner);
    conformance_cmd_475.step.dependOn(b.getInstallStep());
    conformance_cmd_475.addArg("specs/475-process-sleep/conformance/manifest.json");
    conformance_cmd_475.addArg("zig-out/bin/lumen");

    const conformance_cmd_476 = b.addRunArtifact(conformance_runner);
    conformance_cmd_476.step.dependOn(b.getInstallStep());
    conformance_cmd_476.addArg("specs/476-exported-name-collisions/conformance/manifest.json");
    conformance_cmd_476.addArg("zig-out/bin/lumen");

    const conformance_step = b.step("conformance", "Run Lumen manifest conformance cases");
    conformance_step.dependOn(&conformance_cmd.step);
    conformance_step.dependOn(&conformance_cmd_010.step);
    conformance_step.dependOn(&conformance_cmd_013.step);
    conformance_step.dependOn(&conformance_cmd_014.step);
    conformance_step.dependOn(&conformance_cmd_015.step);
    conformance_step.dependOn(&conformance_cmd_016.step);
    conformance_step.dependOn(&conformance_cmd_017.step);
    conformance_step.dependOn(&conformance_cmd_018.step);
    conformance_step.dependOn(&conformance_cmd_019.step);
    conformance_step.dependOn(&conformance_cmd_020.step);
    conformance_step.dependOn(&conformance_cmd_021.step);
    conformance_step.dependOn(&conformance_cmd_022.step);
    conformance_step.dependOn(&conformance_cmd_023.step);
    conformance_step.dependOn(&conformance_cmd_024.step);
    conformance_step.dependOn(&conformance_cmd_025.step);
    conformance_step.dependOn(&conformance_cmd_027.step);
    conformance_step.dependOn(&conformance_cmd_028.step);
    conformance_step.dependOn(&conformance_cmd_002.step);
    conformance_step.dependOn(&conformance_cmd_003.step);
    conformance_step.dependOn(&conformance_cmd_004.step);
    conformance_step.dependOn(&conformance_cmd_005.step);
    conformance_step.dependOn(&conformance_cmd_006.step);
    conformance_step.dependOn(&conformance_cmd_007.step);
    conformance_step.dependOn(&conformance_cmd_008.step);
    conformance_step.dependOn(&conformance_cmd_009.step);
    conformance_step.dependOn(&conformance_cmd_449.step);
    conformance_step.dependOn(&conformance_cmd_450.step);
    conformance_step.dependOn(&conformance_cmd_451.step);
    conformance_step.dependOn(&conformance_cmd_452.step);
    conformance_step.dependOn(&conformance_cmd_453.step);
    conformance_step.dependOn(&conformance_cmd_455.step);
    conformance_step.dependOn(&conformance_cmd_459.step);
    conformance_step.dependOn(&conformance_cmd_459h.step);
    conformance_step.dependOn(&conformance_cmd_456.step);
    conformance_step.dependOn(&conformance_cmd_461.step);
    conformance_step.dependOn(&conformance_cmd_458.step);
    conformance_step.dependOn(&conformance_cmd_464.step);
    conformance_step.dependOn(&conformance_cmd_467.step);
    conformance_step.dependOn(&conformance_cmd_468.step);
    conformance_step.dependOn(&conformance_cmd_474.step);
    conformance_step.dependOn(&conformance_cmd_475.step);
    conformance_step.dependOn(&conformance_cmd_476.step);
}
