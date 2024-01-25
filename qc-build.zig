const std = @import("std");

pub fn init(b: *std.Build) void
{
    _init(b);
}

pub fn addModule(comptime Module: type) void
{
    if (!_initialized)
    {
        _error("Uninitialized", .{});
    }

    var info = _ModuleInfo{};

    inline for (comptime @typeInfo(Module).Struct.decls) |field|
    {
        if (comptime @hasDecl(Module, field.name)) @field(info, field.name) = @field(Module, field.name);
    }

    if (info.name.len == 0)
    {
        _error("Module file `{s}` is missing name", .{@typeName(Module)});
    }

    _modules.putNoClobber(info.name, info)
        catch _error("Duplicate module `{s}`", .{info.name});
}

pub fn buildTests(moduleName: []const u8) void
{
    if (!_initialized)
    {
        _error("Uninitialized", .{});
    }

    const info = _modules.getPtr(moduleName)
        orelse _error("Module `{s}` not found", .{moduleName});

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

    tests.addOptions("qc-build-options", _options);

    _linkDeps(tests, info.deps);

    _linkCFilesAndLibs(tests, info.cFiles, info.cLibs, info.name);

    const installTests = _b.addInstallArtifact(tests, .{});

    // Add step to build tests, i.e. `zig build tests`
    const testsStep = _b.step("tests", "Build unit tests");
    testsStep.dependOn(&installTests.step);
}

pub fn buildExe(source: []const u8, deps: []const []const u8, cFiles: []const []const u8, cLibs: []const []const u8) void
{
    if (!_initialized)
    {
        _error("Uninitialized", .{});
    }

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

    exe.addOptions("qc-build-options", _options);

    _linkDeps(exe, deps);

    _linkCFilesAndLibs(exe, cFiles, cLibs, null);

    // Install exe on default `zig build`
    _b.installArtifact(exe);
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

pub const _ModuleInfo = struct
{
    name: []const u8 = &.{},
    deps: []const []const u8 = &.{},
    cFiles: []const []const u8 = &.{},
    cLibs: []const []const u8 = &.{}
};

const _debugCFlags = [_][]const u8{"-O0", "-g"};
const _releaseCFlags = [_][]const u8{"-O2"};

var _initialized: bool = false;
var _b: *std.Build = undefined;
var _target: std.zig.CrossTarget = undefined;
var _optimize: std.builtin.OptimizeMode = undefined;
var _modules: std.StringHashMap(_ModuleInfo) = undefined;
var _options: *std.build.Step.Options = undefined;
var _errorBuffer: [1024]u8 = undefined;

fn _error(comptime fmt: []const u8, args: anytype) noreturn
{
    @panic(std.fmt.bufPrint(&_errorBuffer, fmt, args) catch unreachable);
}

fn _init(b: *std.Build) void
{
    if (_initialized)
    {
        _error("Already initialized", .{});
    }

    _b = b;

    _target = _b.standardTargetOptions(.{});
    _optimize = _b.standardOptimizeOption(.{});

    _modules = std.StringHashMap(_ModuleInfo).init(_b.allocator);

    // Init options
    _options = _b.addOptions();
    if (_optimize == .Debug or _optimize == .ReleaseSafe)
    {
        // Absolute path to the root project directory
        // Used so `assert` can print an absolute source path, amonst other things
        _options.addOption([]const u8, "rootDir", _b.build_root.path.?);
    }

    _initialized = true;
}

fn _linkDeps(exe: *std.Build.Step.Compile, deps: []const []const u8) void
{
    for (deps) |dep|
    {
        const depModule: *_ModuleInfo = _modules.getPtr(dep)
            orelse _error("Do not have dependency `{s}`", .{dep});

        // Don't link same dependency twice
        if (!exe.modules.contains(depModule.name))
        {
            // Link subdependencies recursively
            _linkDeps(exe, depModule.deps);

            _linkCFilesAndLibs(exe, depModule.cFiles, depModule.cLibs, depModule.name);
        }
    }
}

fn _linkCFilesAndLibs(exe: *std.Build.Step.Compile, cFiles: []const []const u8, cLibs: []const []const u8, module: ?[]const u8) void
{
    if (cFiles.len > 0 or cLibs.len > 0)
    {
        exe.linkLibC();

        // Explicitly link the shared library version of libc to force shared libc linkage
        // TODO: Remove once have ability to request shared linkage of libc directly
        exe.linkSystemLibrary(
            switch (_target.os_tag.?)
            {
                .windows => "msvcrt",
                else => @panic("") // TODO
            });

        // Add module root as include dir
        exe.addIncludePath(std.build.LazyPath{.path = _getModuleRootPath(module)});
    }

    // Add C source files
    for (cFiles) |file|
    {
        exe.addCSourceFile(std.build.CompileStep.CSourceFile{
            .file = std.build.LazyPath{.path = _getModuleFilePath(module, file)},
            .flags = if (_optimize == std.builtin.OptimizeMode.Debug) &_debugCFlags else &_releaseCFlags});
    }

    // Add C libs
    for (cLibs) |lib|
    {
        exe.addObjectFile(std.build.LazyPath{.path = _getModuleFilePath(module, lib)});
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

fn _getModuleRootPath(module_: ?[]const u8) []const u8
{
    if (module_) |module|
    {
        // Intentionally leaking memory
        return std.mem.concat(_b.allocator, u8, &.{"modules/", module}) catch unreachable;
    }
    else
    {
        return ".";
    }
}

fn _getModuleFilePath(module_: ?[]const u8, file: []const u8) []const u8
{
    if (module_) |module|
    {
        // Intentionally leaking memory
        return std.mem.concat(_b.allocator, u8, &.{"modules/", module, "/", file}) catch unreachable;
    }
    else
    {
        return file;
    }
}
