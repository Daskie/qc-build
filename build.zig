const std = @import("std");

pub const PackageInfo = struct
{
    name: []const u8,
    cFiles: []const []const u8 = &.{},
    deps: []const []const u8 = &.{}
};

pub fn init(b: *std.Build, localPackage: ?PackageInfo, depPackages: []const PackageInfo) void
{
    if (_initialized) @panic("");

    _b = b;

    _target = _b.standardTargetOptions(.{});
    _optimize = _b.standardOptimizeOption(.{});

    _packages = std.StringHashMap(_Package).init(_b.allocator);

    // Create modules and init package map
    for (depPackages) |*packageInfo|
    {
        const module = _b.createModule(std.Build.CreateModuleOptions{.source_file = std.Build.LazyPath{.path = _createSourcePath(packageInfo.name)}});
        _packages.putNoClobber(packageInfo.name, _Package{.info = packageInfo.*, .module = module}) catch @panic("");
    }
    if (localPackage) |*localPackageInfo|
    {
        const module = _b.createModule(std.Build.CreateModuleOptions{.source_file = std.Build.LazyPath{.path = _createLocalSourcePath(localPackageInfo.name)}});
        _packages.putNoClobber(localPackageInfo.name, _Package{.info = localPackageInfo.*, .module = module}) catch @panic("");
        _localPackage = _packages.getPtr(localPackageInfo.name) orelse @panic("");
    }

    // Link module dependencies
    var it = _packages.valueIterator();
    while (it.next()) |package|
    {
        const depender: *std.Build.Module = (_packages.get(package.info.name) orelse @panic("")).module;

        for (package.info.deps) |dep|
        {
            const dependee: *std.Build.Module = (_packages.get(dep) orelse @panic("")).module;
            depender.dependencies.put(dep, dependee) catch unreachable;
        }
    }

    _initialized = true;
}

pub fn buildPackageTests() void
{
    if (!_initialized) @panic("");
    if (_localPackage == null) @panic("");

    _buildTests(_localPackage.?.info.name, _createLocalSourcePath(_localPackage.?.info.name), _localPackage.?.info.deps, _localPackage.?.info.cFiles);
}

pub fn buildExe(source: []const u8, deps: []const []const u8, cFiles: []const []const u8) void
{
    if (!_initialized) @panic("");

    _buildExe(std.fs.path.stem(source), source, deps, cFiles);
}

pub fn buildExeAndTests(source: []const u8, deps: []const []const u8, cFiles: []const []const u8) void
{
    if (!_initialized) @panic("");

    const name = std.fs.path.stem(source);
    _buildExe(name, source, deps, cFiles);
    _buildTests(name, source, deps, cFiles);
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

const _Package = struct
{
    info: PackageInfo,
    module: *std.Build.Module
};

const _debugCFlags = [_][]const u8{"-O0", "-g"};
const _releaseCFlags = [_][]const u8{"-O2"};

var _initialized: bool = false;
var _b: *std.Build = undefined;
var _target: std.zig.CrossTarget = undefined;
var _optimize: std.builtin.OptimizeMode = undefined;
var _localPackage: ?*_Package = null;
var _packages: std.StringHashMap(_Package) = undefined;

fn _buildExe(name: []const u8, source: []const u8, deps: []const []const u8, cFiles: []const []const u8) void
{
    // Setup executable
    {
        const exe = _b.addExecutable(.{
            .name = name,
            .root_source_file = .{ .path = source },
            .target = _target,
            .optimize = _optimize});

        // Strip debug symbols from ReleaseFast build
        if (_optimize == .ReleaseFast)
        {
            exe.strip = true;
        }

        _linkDepPackages(exe, deps);

        _linkCFiles(exe, cFiles, null);

        // Install exe on default `zig build`
        _b.installArtifact(exe);
    }
}

fn _buildTests(name: []const u8, source: []const u8, deps: []const []const u8, cFiles: []const []const u8) void
{
    const tests = _b.addTest(.{
        .name = _createTestsName(name),
        .root_source_file = std.Build.LazyPath{.path = source},
        .target = _target,
        .optimize = _optimize});

    // Strip debug symbols from ReleaseFast build
    if (tests.optimize == .ReleaseFast)
    {
        tests.strip = true;
    }

    _linkDepPackages(tests, deps);

    _linkCFiles(tests, cFiles, null);

    const installTests = _b.addInstallArtifact(tests, .{});

    // Add step to build tests, i.e. `zig build tests`
    const testsStep = _b.step("tests", "Build unit tests");
    testsStep.dependOn(&installTests.step);
}

fn _linkDepPackages(exe: *std.Build.Step.Compile, deps: []const []const u8) void
{
    for (deps) |dep|
    {
        const depPackage: *_Package = _packages.getPtr(dep) orelse @panic("");

        // Don't link same dependency twice
        if (!exe.modules.contains(depPackage.info.name))
        {
            // Link subdependencies recursively
            _linkDepPackages(exe, depPackage.info.deps);

            exe.addModule(depPackage.info.name, depPackage.module);

            _linkCFiles(exe, depPackage.info.cFiles, depPackage.info.name);
        }
    }
}

fn _linkCFiles(exe: *std.Build.Step.Compile, cFiles: []const []const u8, depName: ?[]const u8) void
{
    if (cFiles.len > 0)
    {
       // Link with libc if has any C source files
        exe.linkSystemLibrary("c");

        // Add C source files
        for (cFiles) |cFile|
        {
            exe.addCSourceFile(std.build.CompileStep.CSourceFile{
                .file = std.build.LazyPath{.path = _createCFilePath(depName, cFile)},
                .flags = if (_optimize == std.builtin.OptimizeMode.Debug) &_debugCFlags else &_releaseCFlags});
        }
    }
}

fn _createTestsName(name: []const u8) []const u8
{
    // Intentionally leaking memory
    return std.mem.concat(_b.allocator, u8, &.{name, "-tests"}) catch unreachable;
}

fn _createLocalSourcePath(name: []const u8) []const u8
{
    // Intentionally leaking memory
    return std.mem.concat(_b.allocator, u8, &.{"src/", name, ".zig"}) catch unreachable;
}

fn _createSourcePath(name: []const u8) []const u8
{
    // Intentionally leaking memory
    return std.mem.concat(_b.allocator, u8, &.{"deps/", name, "/src/", name, ".zig"}) catch unreachable;
}

fn _createCFilePath(depName: ?[]const u8, cFile: []const u8) []const u8
{
    // If this is the C file of a dependency and that dependency is not local, prefix the path with "deps/<name>/"
    if (depName != null and (_localPackage == null or !std.mem.eql(u8, depName.?, _localPackage.?.info.name)))
    {
        // Intentionally leaking memory
        return std.mem.concat(_b.allocator, u8, &.{"deps/", depName.?, "/", cFile}) catch unreachable;
    }
    else
    {
        return cFile;
    }
}
