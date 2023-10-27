const std = @import("std");

pub fn addModule(b: *std.Build, comptime Module: type) void
{
    if (!_initialized)
    {
        _init(b);
    }

    const info = _ModuleInfo{
        .name = Module.name,
        .deps = Module.deps,
        .cFiles = Module.cFiles};

    _modules.putNoClobber(info.name, info) catch @panic("");
}

pub fn buildTests(moduleName: []const u8) void
{
    if (!_initialized) @panic("");

    const info = _modules.getPtr(moduleName) orelse @panic("");

    const tests = _b.addTest(.{
        .name = _createTestsName(info.name),
        .root_source_file = std.Build.LazyPath{.path = _createSourcePath(moduleName)},
        .target = _target,
        .optimize = _optimize});

    // Strip debug symbols from ReleaseFast build
    if (tests.optimize == .ReleaseFast)
    {
        tests.strip = true;
    }

    _linkDeps(tests, info.deps);

    _linkCFiles(tests, info.cFiles, info.name);

    const installTests = _b.addInstallArtifact(tests, .{});

    // Add step to build tests, i.e. `zig build tests`
    const testsStep = _b.step("tests", "Build unit tests");
    testsStep.dependOn(&installTests.step);
}

pub fn buildExe(source: []const u8, deps: []const []const u8, cFiles: []const []const u8) void
{
    if (!_initialized) @panic("");

    const exe = _b.addExecutable(.{
        .name = std.fs.path.stem(source),
        .root_source_file = .{ .path = source },
        .target = _target,
        .optimize = _optimize,
        .main_pkg_path = std.build.LazyPath{.path = "."}});

    // Strip debug symbols from ReleaseFast build
    if (_optimize == .ReleaseFast)
    {
        exe.strip = true;
    }

    _linkDeps(exe, deps);

    _linkCFiles(exe, cFiles, null);

    // Install exe on default `zig build`
    _b.installArtifact(exe);
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

pub const _ModuleInfo = struct
{
    name: []const u8,
    deps: []const []const u8,
    cFiles: []const []const u8
};

const _debugCFlags = [_][]const u8{"-O0", "-g"};
const _releaseCFlags = [_][]const u8{"-O2"};

var _initialized: bool = false;
var _b: *std.Build = undefined;
var _target: std.zig.CrossTarget = undefined;
var _optimize: std.builtin.OptimizeMode = undefined;
var _modules: std.StringHashMap(_ModuleInfo) = undefined;

fn _init(b: *std.Build) void
{
    _b = b;

    _target = _b.standardTargetOptions(.{});
    _optimize = _b.standardOptimizeOption(.{});

    _modules = std.StringHashMap(_ModuleInfo).init(_b.allocator);

    _initialized = true;
}

fn _linkDeps(exe: *std.Build.Step.Compile, deps: []const []const u8) void
{
    for (deps) |dep|
    {
        const depModule: *_ModuleInfo = _modules.getPtr(dep) orelse @panic("");

        // Don't link same dependency twice
        if (!exe.modules.contains(depModule.name))
        {
            // Link subdependencies recursively
            _linkDeps(exe, depModule.deps);

            _linkCFiles(exe, depModule.cFiles, depModule.name);
        }
    }
}

fn _linkCFiles(exe: *std.Build.Step.Compile, cFiles: []const []const u8, module: ?[]const u8) void
{
    if (cFiles.len > 0)
    {
       // Link with libc if has any C source files
        exe.linkSystemLibrary("c");

        // Add C source files
        for (cFiles) |cFile|
        {
            exe.addCSourceFile(std.build.CompileStep.CSourceFile{
                .file = std.build.LazyPath{.path = if (module) |m| _createCFilePath(m, cFile) else cFile},
                .flags = if (_optimize == std.builtin.OptimizeMode.Debug) &_debugCFlags else &_releaseCFlags});
        }
    }
}

fn _createTestsName(name: []const u8) []const u8
{
    // Intentionally leaking memory
    return std.mem.concat(_b.allocator, u8, &.{name, "-tests"}) catch unreachable;
}

fn _createSourcePath(name: []const u8) []const u8
{
    // Intentionally leaking memory
    return std.mem.concat(_b.allocator, u8, &.{"modules/", name, "/", name, ".zig"}) catch unreachable;
}

fn _createCFilePath(module: []const u8, cFile: []const u8) []const u8
{
    // Intentionally leaking memory
    return std.mem.concat(_b.allocator, u8, &.{"modules/", module, "/", cFile}) catch unreachable;
}
