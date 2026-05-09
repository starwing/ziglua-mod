const std = @import("std");

/// The version of Lua to target. This is used to determine which API functions
/// are available, and to provide compatibility shims for older versions of Lua.
pub const lang = struct {
    /// The Lua version to target. This is set by the `--lang` option in `build.zig`.
    pub const version = @import("config").lang;

    /// Whether Lua uses 32-bit integers.
    pub const is32bit = @import("config").is32bit;

    pub inline fn atLeast(min: @TypeOf(version)) bool {
        return @intFromEnum(version) >= @intFromEnum(min);
    }

    pub inline fn between(min: @TypeOf(version), max: @TypeOf(version)) bool {
        const v = @intFromEnum(version);
        return v >= @intFromEnum(min) and v <= @intFromEnum(max);
    }

    pub inline fn in(langs: anytype) bool {
        inline for (langs) |l| if (version == l) return true;
        return false;
    }

    pub inline fn eql(other: @TypeOf(version)) bool {
        return version == other;
    }

    pub inline fn num() Number {
        return switch (lang.version) {
            .lua51 => @as(Number, 501),
            .lua52 => @as(Number, 502),
            .lua53 => @as(Number, 503),
            .lua54 => @as(Number, 504),
            .lua55 => @as(Number, 505),
            else => unreachable,
        };
    }
};

const c_str = [*:0]const u8;
const c_voidp = ?*anyopaque;
const c_voidpc = ?*const anyopaque;

/// The C function type for Lua C API functions.
pub const CFn = *const fn (*State) callconv(.c) c_int;

/// The continuation function type for Lua 5.2+.
pub const KFn = if (lang.eql(.lua52))
    CFn
else
    *const fn (*State, Status, KContext) callconv(.c) c_int;

/// The C function type for Lua memory allocators.
pub const Alloc = *const fn (
    ud: c_voidp,
    ptr: c_voidp,
    osize: usize,
    nsize: usize,
) callconv(.c) c_voidp;

/// The C function type for Lua reader callbacks used by [`load`].
pub const Reader = *const fn (
    *State,
    data: c_voidp,
    size: *usize,
) callconv(.c) ?c_str;

/// The C function type for Lua writer callbacks used by [`dump`].
pub const Writer = *const fn (
    *State,
    ptr: [*]const u8,
    sz: usize,
    ud: c_voidp,
) callconv(.c) c_int;

/// The number type used by Lua.
pub const Number = if (lang.is32bit) f32 else f64;

/// The integer type used by Lua.
pub const Integer = if (lang.in(.{ .lua51, .lua52 }))
    isize
else if (lang.is32bit) i32 else i64;

/// The unsigned integer type used by Lua.
pub const Unsigned = if (lang.in(.{ .lua51, .lua52 }))
    u32
else if (lang.is32bit) u32 else u64;

/// Maximum representable Lua integer.
pub const max_integer = std.math.maxInt(Integer);

/// Minimum representable Lua integer.
pub const min_integer = std.math.minInt(Integer);

/// The type of a Lua function, as returned by `getInfo` in the `what` field.
pub const FnType = enum { Lua, C, main, tail };

/// The meaning of a function's name, as returned by `getInfo`.
pub const NameType = enum { global, local, field, method, upvalue, other };

/// The C function type for Lua warning callbacks (Lua 5.4+).
pub const WarnFn = *const fn (c_voidp, [*:0]const u8, c_int) callconv(.c) void;

/// Registry pseudo-index. The registry is a predefined table available to any
/// C code, used to store Lua values to be retrieved later.
pub const registry_index: i32 = if (lang.in(.{ .lua51, .luajit }))
    -10000
else if (lang.between(.lua52, .lua54) or lang.eql(.luau))
    -luai_maxstack - 1000
else
    -(std.math.maxInt(i32) / 2 + 1000);

/// The Lua max stack size (configurable, default 1000000).
const luai_maxstack = if (@sizeOf(Integer) >= 4) 1000000 else 15000;

/// Pseudo-index for the globals table. Available in Lua 5.1 and LuaJIT.
pub const globals_index = if (lang.in(.{ .lua51, .luajit }))
    @as(i32, -10002)
else
    notAvail("globals_index");

/// Pseudo-index for the `i`-th upvalue of the running C function.
pub inline fn upvalueIndex(i: i32) i32 {
    if (comptime lang.in(.{ .lua51, .luajit })) return globals_index - i;
    return registry_index - i;
}

/// Wraps a Zig hook function into a C-compatible `lua_Hook`. The Zig function
/// must have signature `fn (*State, Event, *DebugInfo) callconv(.c) void`.
pub inline fn hookFn(comptime f: anytype) *const fn (*State, *DebugInfo.Raw) callconv(.c) void {
    return struct {
        fn cb(l: *State, ar: *DebugInfo.Raw) callconv(.c) void {
            const event: Event = @enumFromInt(ar.event);
            var info = DebugInfo.fromRaw(.{}, ar);
            info.current_line = if (ar.currentline >= 0) ar.currentline else null;
            @call(.auto, f, .{ l, event, &info });
        }
    }.cb;
}

/// The Lua state, which is passed to all C API functions.
pub const State = opaque {
    // state manipulation
    //
    const alignment = @alignOf(std.c.max_align_t);

    fn allocf(ud: c_voidp, ptr: c_voidp, osize: usize, nsize: usize) callconv(.c) ?*align(alignment) anyopaque {
        const alloc: *std.mem.Allocator = @ptrCast(@alignCast(ud.?));
        if (@as(?[*]align(alignment) u8, @ptrCast(@alignCast(ptr)))) |p| {
            const prev_slice = p[0..osize];
            if (nsize == 0) {
                alloc.free(prev_slice);
                return null;
            }
            const new_slice = alloc.realloc(prev_slice, nsize) catch return null;
            return new_slice.ptr;
        }
        if (nsize == 0) return null;
        const new_slice = alloc.alignedAlloc(u8, .fromByteUnits(alignment), nsize) catch return null;
        return new_slice.ptr;
    }

    pub inline fn init(alloc: std.mem.Allocator) !*State {
        const ud = try alloc.create(std.mem.Allocator);
        ud.* = alloc;
        return api(.lua_newstate)(allocf, ud) orelse error.OutOfMemory;
    }

    /// [-0,+0,-] Close the Lua state, freeing all resources associated with it.
    pub inline fn deinit(L: *State) void {
        var ud: ?*std.mem.Allocator = undefined;
        _ = api(.lua_getallocf)(L, @ptrCast(&ud)).?;
        const alloc = ud.?;
        api(.lua_close)(L);
        alloc.destroy(alloc);
    }

    /// Returns the allocator used to initialize the state.
    pub inline fn allocator(L: *State) std.mem.Allocator {
        var ud: ?*std.mem.Allocator = undefined;
        _ = api(.lua_getallocf)(L, @ptrCast(&ud)).?;
        return ud.?.*;
    }

    /// Returns the status of the thread `L`.
    pub inline fn status(L: *State) Status {
        return api(.lua_status)(L);
    }

    /// [-0,+1,m] Creates a new Lua state, and returns a pointer to it.
    pub inline fn newThread(L: *State) *State {
        return api(.lua_newthread)(L);
    }

    /// [-0,+0,-] Sets a new panic function and returns the old one.
    pub inline fn atPanic(L: *State, panicf: CFn) ?CFn {
        return api(.lua_atpanic)(L, panicf);
    }

    /// Returns the Lua version.
    pub inline fn version(L: *State) Number {
        if (comptime !lang.atLeast(.lua52) and !lang.eql(.luau)) notAvail("version");
        if (comptime lang.in(.{ .lua52, .lua53 })) {
            const T = *const fn (*State) callconv(.c) *const Number;
            return @extern(T, extName(.lua_version))(L).*;
        }
        const T = *const fn (*State) callconv(.c) Number;
        return @extern(T, extName(.lua_version))(L);
    }

    /// [-?,+?,e] Resets the thread `L` by closing any to-be-closed variables
    /// and emptying its stack. Available in Lua 5.4+.
    pub inline fn closeThread(L: *State, from: ?*State) Error!void {
        return checkErr(api(.lua_closethread)(L, from orelse null));
    }

    /// Returns a pointer to the raw memory area associated with the given
    /// Lua state. The size of this area is `LUA_EXTRASPACE` (typically
    /// `@sizeOf(*anyopaque)`). Available in Lua 5.3+.
    pub inline fn getExtraSpace(L: *State) []align(1) u8 {
        if (comptime !lang.atLeast(.lua53)) notAvail("getExtraSpace");
        const addr = @intFromPtr(L) - @sizeOf(*anyopaque);
        const ptr: [*]align(1) u8 = @ptrFromInt(addr);
        return ptr[0..@sizeOf(*anyopaque)];
    }

    // garbage collector

    /// `[-0,+0,-]` Stops the garbage collector.
    pub inline fn gcStop(L: *State) void {
        _ = api(.lua_gc)(L, gcOp.stop, @as(c_int, 0));
    }

    /// `[-0,+0,-]` Restarts the garbage collector.
    pub inline fn gcRestart(L: *State) void {
        _ = api(.lua_gc)(L, gcOp.restart, @as(c_int, 0));
    }

    /// `[-0,+0,-]` Performs a full garbage-collection cycle.
    pub inline fn gcCollect(L: *State) void {
        _ = api(.lua_gc)(L, gcOp.collect, @as(c_int, 0));
    }

    /// `[-0,+0,-]` Returns the current amount of memory (in Kbytes) in use by Lua.
    pub inline fn gcCount(L: *State) usize {
        return @intCast(api(.lua_gc)(L, gcOp.count, @as(c_int, 0)));
    }

    /// `[-0,+0,-]` Returns the current amount of memory (in bytes) in use by Lua.
    pub inline fn gcCountB(L: *State) usize {
        return @intCast(api(.lua_gc)(L, gcOp.countb, @as(c_int, 0)));
    }

    /// `[-0,+0,-]` Performs an incremental step of garbage collection.
    pub inline fn gcStep(L: *State, stepsize: i32) void {
        _ = api(.lua_gc)(L, gcOp.step, stepsize);
    }

    /// `[-0,+0,-]` Returns whether the collector is running. Available in Lua 5.2+.
    pub inline fn gcIsRunning(L: *State) bool {
        if (comptime !lang.atLeast(.lua52)) notAvail("gcIsRunning");
        return api(.lua_gc)(L, gcOp.isrunning, @as(c_int, 0)) != 0;
    }

    /// `[-0,+0,-]` Sets the collector to generational mode.
    /// Lua 5.2: toggles mode (no arguments).
    /// Lua 5.4+: takes minor and major multipliers.
    pub inline fn gcSetGenerational(L: *State, minor: i32, major: i32) bool {
        if (comptime lang.in(.{ .lua51, .lua53, .luajit })) notAvail("gcSetGenerational");
        if (comptime lang.eql(.lua52)) {
            _ = api(.lua_gc)(L, gcOp.gen, @as(c_int, 0)); // always return 0
            return true;
        }
        return api(.lua_gc)(L, gcOp.gen, minor, major) != 0;
    }

    /// `[-0,+0,-]` Sets the collector to incremental mode with the given parameters.
    /// Available in Lua 5.4+.
    pub inline fn gcSetIncremental(L: *State, pause: i32, stepmul: i32, stepsize: i32) bool {
        if (comptime !lang.atLeast(.lua54)) notAvail("gcSetIncremental");
        return api(.lua_gc)(L, gcOp.inc, pause, stepmul, stepsize) != 0;
    }

    /// `[-0,+0,-]` Sets the garbage-collector pause as a percentage.
    pub inline fn gcSetPause(L: *State, pause: i32) i32 {
        if (comptime lang.atLeast(.lua55)) notAvail("gcSetPause");
        return api(.lua_gc)(L, gcOp.setpause, pause);
    }

    /// `[-0,+0,-]` Sets the garbage-collector step multiplier.
    pub inline fn gcSetStepMul(L: *State, mul: i32) i32 {
        if (comptime lang.atLeast(.lua55)) notAvail("gcSetStepMul");
        return api(.lua_gc)(L, gcOp.setstepmul, mul);
    }

    // basic stack manipulation
    //

    /// Converts a stack index to an absolute index.
    pub inline fn absIndex(L: *State, idx: i32) i32 {
        if (comptime lang.in(.{ .lua51, .luajit })) {
            if (idx > 0 or idx <= registry_index) return idx;
            return L.getTop() + idx + 1;
        }
        return api(.lua_absindex)(L, idx);
    }

    /// [-0,+0,-] Returns the index of the top element in the stack.
    pub inline fn getTop(L: *State) i32 {
        return api(.lua_gettop)(L);
    }

    /// [-?,+?,e] Sets the stack top to the given index.
    /// If the new top is larger than the old top, then the new elements are
    /// filled with `nil`. If the new top is smaller than the old top, then the
    /// values at the top are removed.
    pub inline fn setTop(L: *State, idx: i32) void {
        api(.lua_settop)(L, idx);
    }

    /// [-n,+0,e] Pops `n` elements from the stack.
    pub inline fn pop(L: *State, n: i32) void {
        setTop(L, -n - 1);
    }

    /// [-0,+1,-] Pushes a copy of the element at the given index onto the stack.
    pub inline fn pushValue(L: *State, idx: i32) void {
        api(.lua_pushvalue)(L, idx);
    }

    /// `[-0,+0,-]` Removes the element at the given index, shifting down the
    /// elements above to fill the gap. Available in Lua 5.3+.
    pub inline fn rotate(L: *State, idx: i32, n: i32) void {
        if (comptime !lang.atLeast(.lua53)) notAvail("rotate");
        api(.lua_rotate)(L, idx, n);
    }

    /// `[-1,+0,e]` Moves the top element to the given index, shifting up the
    /// elements above.
    pub inline fn insert(L: *State, idx: i32) void {
        if (comptime !lang.atLeast(.lua53)) return api(.lua_insert)(L, idx);
        L.rotate(idx, 1);
    }

    /// `[-1,+0,e]` Removes the element at the given index, shifting down the
    /// elements above to fill the gap.
    pub inline fn remove(L: *State, idx: i32) void {
        if (comptime !lang.atLeast(.lua53)) return api(.lua_remove)(L, idx);
        L.rotate(idx, -1);
        L.pop(1);
    }

    /// `[-1,+0,e]` Replaces the element at the given index with the value at
    /// the top of the stack, popping the top.
    pub inline fn replace(L: *State, idx: i32) void {
        if (comptime !lang.atLeast(.lua53)) return api(.lua_replace)(L, idx);
        L.copy(-1, idx);
        L.pop(1);
    }

    /// Copies the element at the given index to the given index, without shifting
    /// any elements.
    pub inline fn copy(L: *State, from_idx: i32, to_idx: i32) void {
        api(.lua_copy)(L, from_idx, to_idx);
    }

    /// Checks whether the stack has space for at least `n` extra slots, returns
    /// `true` if it does.
    pub inline fn checkStack(L: *State, n: i32) bool {
        return api(.lua_checkstack)(L, n) != 0;
    }

    /// `[-0,+0,v]` Grows the stack size to top + `sz` elements, raising an
    /// error if the stack cannot grow to that size.
    /// `msg` is an additional text to go into the error message (or null for no
    /// additional text).
    pub inline fn checkStackRaiseErr(L: *State, sz: i32, msg: ?c_str) void {
        api(.luaL_checkstack)(L, sz, msg);
    }

    /// [-?,+?,-] Moves `n` elements from the top of the stack of `from` to the
    /// top of the stack of `to`.
    pub inline fn xMove(from: *State, to: *State, n: i32) void {
        api(.lua_xmove)(from, to, n);
    }

    // access functions (stack -> C)
    //

    /// [-0,+0,-] Returns whether the value at the given index is a number.
    pub inline fn isNumber(L: *State, idx: i32) bool {
        return api(.lua_isnumber)(L, idx) != 0;
    }

    /// `[-0,+0,-]` Returns true if the value at the given index is a string or
    /// a number (which is always convertible to a string), and false otherwise.
    pub inline fn isString(L: *State, idx: i32) bool {
        return api(.lua_isstring)(L, idx) != 0;
    }

    /// [-0,+0,-] Returns whether the value at the given index is a C function.
    pub inline fn isCFunction(L: *State, idx: i32) bool {
        return api(.lua_iscfunction)(L, idx) != 0;
    }

    /// [-0,+0,-] Returns whether the value at the given index is an integer.
    pub inline fn isInteger(L: *State, idx: i32) bool {
        if (comptime lang.in(.{ .lua51, .luajit })) {
            if (!L.isNumber(idx)) return false;
            const n = api(.lua_tonumber)(L, idx);
            const i = api(.lua_tointeger)(L, idx);
            return @abs(n - @as(Number, @floatFromInt(i))) < 0.001;
        }
        return api(.lua_isinteger)(L, idx) != 0;
    }

    /// [-0,+0,-] Returns whether the value at the given index is a userdata.
    pub inline fn isUserdata(L: *State, idx: i32) bool {
        return api(.lua_isuserdata)(L, idx) != 0;
    }

    /// [-0,+0,-] Returns the type of the value at the given index.
    pub inline fn typeOf(L: *State, idx: i32) LuaType {
        return api(.lua_type)(L, idx);
    }

    /// [-0,+0,-] Returns whether the value at the given index is a function.
    pub inline fn isFunction(L: *State, idx: i32) bool {
        return L.typeOf(idx) == .function;
    }

    /// [-0,+0,-] Returns whether the value at the given index is a table.
    pub inline fn isTable(L: *State, idx: i32) bool {
        return L.typeOf(idx) == .table;
    }

    /// [-0,+0,-] Returns whether the value at the given index is a light userdata.
    pub inline fn isLightUserdata(L: *State, idx: i32) bool {
        return L.typeOf(idx) == .light_userdata;
    }

    /// [-0,+0,-] Returns whether the value at the given index is `nil`.
    pub inline fn isNil(L: *State, idx: i32) bool {
        return L.typeOf(idx) == .nil;
    }

    /// [-0,+0,-] Returns whether the value at the given index is a boolean.
    pub inline fn isBoolean(L: *State, idx: i32) bool {
        return L.typeOf(idx) == .boolean;
    }

    /// [-0,+0,-] Returns whether the value at the given index is a thread.
    pub inline fn isThread(L: *State, idx: i32) bool {
        return L.typeOf(idx) == .thread;
    }

    /// [-0,+0,-] Returns whether the given index is not valid.
    pub inline fn isNone(L: *State, idx: i32) bool {
        return L.typeOf(idx) == .none;
    }

    /// [-0,+0,-] Returns whether the given index is not valid or if the value
    /// at this index is `nil`.
    pub inline fn isNoneOrNil(L: *State, idx: i32) bool {
        const t = L.typeOf(idx);
        return t == .none or t == .nil;
    }

    /// [-0,+0,-] Returns the name of the type `t`.
    pub inline fn typeName(L: *State, t: LuaType) []const u8 {
        return std.mem.span(api(.lua_typename)(L, t));
    }

    /// [-0,+0,-] Returns the name of the type of the value at the given index.
    pub inline fn typeNameIndex(L: *State, idx: i32) []const u8 {
        return L.typeName(L.typeOf(idx));
    }

    /// `[-0,+0,-]` Converts the Lua value at the given index to the type
    /// [`Number`], or returns `null` if the value is not convertible.
    pub inline fn toNumber(L: *State, idx: i32) ?Number {
        if (comptime lang.eql(.lua51)) {
            if (!L.isNumber(idx)) return null;
            return api(.lua_tonumber)(L, idx);
        }
        var isnum: c_int = 0;
        const v = api(.lua_tonumberx)(L, idx, &isnum);
        return if (isnum != 0) v else null;
    }

    /// `[-0,+0,-]` Like [`toNumber`] but returns `0` if the value is not
    /// convertible.
    pub inline fn toNumberOrZero(L: *State, idx: i32) Number {
        if (comptime lang.eql(.lua51)) return api(.lua_tonumber)(L, idx);
        return toNumber(L, idx) orelse 0;
    }

    /// `[-0,+0,-]` Converts the Lua value at the given index to the signed
    /// integral type [`Integer`], or returns `null` if the value is not
    /// convertible.
    pub inline fn toInteger(L: *State, idx: i32) ?Integer {
        if (comptime lang.eql(.lua51)) {
            if (!L.isInteger(idx)) return null;
            return api(.lua_tointeger)(L, idx);
        }
        var isnum: c_int = 0;
        const v = api(.lua_tointegerx)(L, idx, &isnum);
        return if (isnum != 0) v else null;
    }

    /// `[-0,+0,-]` Like [`toInteger`] but returns `0` if the value is not
    /// convertible.
    pub inline fn toIntegerOrZero(L: *State, idx: i32) Integer {
        if (comptime lang.eql(.lua51)) return api(.lua_tointeger)(L, idx);
        return toInteger(L, idx) orelse 0;
    }

    /// Converts the Lua value at the given index to the unsigned integral type
    /// `u64`, or returns `null` if the value is not convertible.
    /// This routine is not documented by Lua manual, and removed in Lua 5.5.
    pub inline fn toUnsigned(L: *State, idx: i32) ?Unsigned {
        if (comptime lang.eql(.lua51)) {
            if (!L.isInteger(idx)) return null;
            return @intCast(api(.lua_tointeger)(L, idx));
        }
        if (comptime lang.eql(.lua52)) {
            var isnum: c_int = 0;
            const v = api(.lua_tounsignedx)(L, idx, &isnum);
            return if (isnum != 0) v else null;
        }
        return if (toInteger(L, idx)) |i| @intCast(i) else null;
    }

    /// `[-0,+0,-]` Like [`toUnsigned`] but returns `0` if the value is not
    /// convertible.
    pub inline fn toUnsignedOrZero(L: *State, idx: i32) Unsigned {
        if (comptime lang.eql(.lua51)) return @intCast(api(.lua_tointeger)(L, idx));
        return toUnsigned(L, idx) orelse 0;
    }

    /// [-0,+0,-] Converts the Lua value at the given index to a boolean.
    pub inline fn toBoolean(L: *State, idx: i32) bool {
        return api(.lua_toboolean)(L, idx) != 0;
    }

    /// [-0,+0,m] Converts the Lua value at the given index to a string, and
    /// returns it as a slice.
    pub inline fn toSlice(L: *State, idx: i32) ?[]const u8 {
        var l: usize = 0;
        const ptr = api(.lua_tolstring)(L, idx, &l);
        return if (ptr) |p| p[0..l] else null;
    }

    /// [-0,+0,m] Converts the Lua value at the given index to a C string.
    pub inline fn toString(L: *State, idx: i32) ?c_str {
        return if (toSlice(L, idx)) |s| @ptrCast(s) else null;
    }

    /// Returns the length of the Lua value at the given index, without invoking
    /// any metamethods.
    pub inline fn rawLen(L: *State, idx: i32) usize {
        if (comptime lang.in(.{ .lua51, .luajit })) return api(.lua_objlen)(L, idx);
        return api(.lua_rawlen)(L, idx);
    }
    /// Alias for `rawLen`, for compatibility with Lua 5.1 and LuaJIT.
    pub const objectLen = rawLen;

    /// [-0,+0,-] Returns the C function pointer of the Lua value at the given
    /// index, or `null` if the value is not a C function.
    pub inline fn toCFunction(L: *State, idx: i32) ?CFn {
        return api(.lua_tocfunction)(L, idx);
    }

    /// [-0,+0,-] Returns the userdata pointer of the Lua value at the given
    /// index, or `null` if the value is not a userdata.
    pub inline fn toUserdata(L: *State, comptime T: type, idx: i32) ?*T {
        return @ptrCast(@alignCast(api(.lua_touserdata)(L, idx)));
    }

    /// [-0,+0,-] Returns the thread pointer of the Lua value at the given
    /// index, or `null` if the value is not a thread.
    pub inline fn toThread(L: *State, idx: i32) ?*State {
        return api(.lua_tothread)(L, idx);
    }

    /// `[-0,+0,-]` Converts the value at the given index to a generic pointer
    /// `*const void`.
    /// The value can be a userdata, a table, a thread, a string, or a function;
    /// otherwise, `toPointer` returns `null`. Different objects will give
    /// different pointers. There is no way to convert the pointer back to its
    /// original value.
    /// Typically this function is used only for hashing and debug information.
    pub inline fn toPointer(L: *State, idx: i32) c_voidpc {
        return api(.lua_topointer)(L, idx);
    }

    // Comparison and arithmetic functions
    //

    /// `[-2,+1,e]` Performs an arithmetic operation on the top 1-2 values of
    /// the stack and pushes the result.
    /// Available on Lua 5.3+, Luau, and LuaJIT.
    pub inline fn arith(L: *State, op: ArithOperator) void {
        if (comptime !lang.atLeast(.lua53) and !lang.in(.{ .luajit, .luau }))
            notAvail("arith");
        api(.lua_arith)(L, op);
    }

    /// `[-0,+0,e]` Compares two Lua values. Returns `true` if `idx1` satisfies
    /// the comparison operator `op` with respect to `idx2`. Available on 5.2+.
    pub inline fn compare(L: *State, idx1: i32, idx2: i32, op: CompareOperator) bool {
        if (comptime !lang.atLeast(.lua52)) notAvail("compare");
        return api(.lua_compare)(L, idx1, idx2, op) != 0;
    }

    /// `[-0,+0,-]` Returns `true` if the two values at the given indices are
    /// equal, without invoking metamethods. Available on Lua 5.2+.
    pub inline fn rawEqual(L: *State, idx1: i32, idx2: i32) bool {
        if (comptime !lang.atLeast(.lua52)) notAvail("rawEqual");
        return api(.lua_rawequal)(L, idx1, idx2) != 0;
    }

    /// `[-0,+0,e]` Returns `true` if the Lua value at `idx1` is equal to
    /// the value at `idx2`, following the semantics of the Lua `==` operator.
    pub inline fn equal(L: *State, idx1: i32, idx2: i32) bool {
        if (comptime lang.atLeast(.lua52))
            return L.compare(idx1, idx2, .eq);
        return api(.lua_equal)(L, idx1, idx2) != 0;
    }

    /// `[-0,+0,e]` Returns `true` if the Lua value at `idx1` is less than
    /// the value at `idx2`, following the semantics of the Lua `<` operator.
    pub inline fn lessThan(L: *State, idx1: i32, idx2: i32) bool {
        if (comptime lang.atLeast(.lua52))
            return L.compare(idx1, idx2, .lt);
        return api(.lua_lessthan)(L, idx1, idx2) != 0;
    }

    /// Tries to convert a Lua float to a Lua integer; the float `n` must have
    /// an integral value.
    /// If that value is within the range of Lua integers, it is converted to an
    /// integer returned.
    pub inline fn numberToInteger(n: Number) error{Overflow}!Integer {
        const min_float: Number = @floatFromInt(std.math.minInt(Integer));
        if (n < min_float or n >= -min_float) return error.Overflow;
        return @intFromFloat(n);
    }

    // push functions (C -> stack)
    //

    /// [-0,+1,-] Pushes `nil` to the stack.
    pub inline fn pushNil(L: *State) void {
        api(.lua_pushnil)(L);
    }
    /// Alias for `pushNil`, for better readability when pushing a fail value.
    pub const pushFail = pushNil;

    /// [-0,+1,-] Pushes a number onto the stack.
    pub inline fn pushNumber(L: *State, n: Number) void {
        api(.lua_pushnumber)(L, n);
    }

    /// [-0,+1,-] Pushes an integer onto the stack.
    pub inline fn pushInteger(L: *State, n: Integer) void {
        api(.lua_pushinteger)(L, n);
    }

    /// `[-0,+1,-]` Pushes an unsigned integer onto the stack.
    /// Available in Lua 5.2–5.4.
    pub inline fn pushUnsigned(L: *State, n: Unsigned) void {
        if (comptime !lang.between(.lua52, .lua54)) notAvail("pushUnsigned");
        pushInteger(L, @intCast(n));
    }

    /// Pushes a null-terminated string onto the stack.
    pub inline fn pushString(L: *State, s: c_str) c_str {
        const r = api(.lua_pushstring)(L, s);
        if (comptime lang.atLeast(.lua52)) return r;
        return L.toString(-1).?;
    }

    /// Pushes a null-terminated string onto the stack, and return a pointer to
    /// the string in Lua memory.
    pub inline fn pushStringBlind(L: *State, s: c_str) void {
        _ = api(.lua_pushstring)(L, s);
    }

    /// `[-0,+1,v]` Pushes a string with the given length onto the stack,
    /// and returns a pointer to the string in Lua memory.
    pub inline fn pushSlice(L: *State, s: []const u8) c_str {
        const r = api(.lua_pushlstring)(L, s, s.len);
        if (comptime lang.atLeast(.lua52)) return r;
        return L.toString(-1).?;
    }

    /// `[-0,+1,v]` Pushes a string with the given length onto the stack.
    pub inline fn pushSliceBlind(L: *State, s: []const u8) void {
        _ = api(.lua_pushlstring)(L, s, s.len);
    }

    /// `[-0,+1,v]` Push a formatted string onto the stack, and return a pointer
    /// to the string in Lua memory.
    /// `[-0,+1,v]` Push a formatted string onto the stack, and return a pointer
    /// to the string in Lua memory.
    pub inline fn pushFString(L: *State, fmt: c_str, args: anytype) c_str {
        return @call(
            .auto,
            api(.lua_pushfstring),
            .{ L, fmt } ++ args,
        );
    }

    // pub inline fn pushExternalString()

    /// [-n,+1,m] Pushes a C function onto the stack, and sets its upvalues to
    /// the values at the top of the stack, when `n` is different from zero.
    pub inline fn pushCClosure(L: *State, f: CFn, n: i32) void {
        api(.lua_pushcclosure)(L, f, n);
    }

    /// [-0,+1,m] Pushes a C function onto the stack.
    pub inline fn pushCFunction(L: *State, f: CFn) void {
        pushCClosure(L, f, 0);
    }

    /// [-0,+0,e] Sets the C function `f` as the new value of global name.
    pub inline fn register(L: *State, name: c_str, f: CFn) void {
        L.pushCFunction(f);
        L.setGlobal(name);
    }

    /// [-0,+1,-] Pushes a boolean value onto the stack.
    pub inline fn pushBoolean(L: *State, b: bool) void {
        api(.lua_pushboolean)(L, if (b) 1 else 0);
    }

    /// [-0,+1,-] Pushes a light userdata pointer onto the stack.
    pub inline fn pushLightUserdata(L: *State, p: c_voidp) void {
        api(.lua_pushlightuserdata)(L, p orelse null);
    }

    /// [-0,+1,-] Pushes the thread at the given index onto the stack, and returns whether
    /// it is the main thread.
    pub inline fn pushThread(L: *State) bool {
        return api(.lua_pushthread)(L) != 0;
    }

    // get functions (Lua -> stack)
    //

    /// Pushes the value of the global variable `name` onto the stack.
    pub inline fn getGlobal(L: *State, name: c_str) LuaType {
        if (comptime lang.in(.{ .lua51, .luajit }))
            return L.getField(globals_index, name);
        const r = api(.lua_getglobal)(L, name);
        if (comptime lang.atLeast(.lua53)) return r;
        return L.typeOf(-1);
    }

    /// Pushes the value of the global variable `name` onto the stack, and return its type.
    pub inline fn getGlobalBlind(L: *State, name: c_str) void {
        if (comptime lang.in(.{ .lua51, .luajit })) return api(.lua_getfield)(L, globals_index, name);
        _ = api(.lua_getglobal)(L, name);
    }

    /// Pushes the value of the table at the given index, with the key at the
    /// top of the stack,
    pub inline fn getTable(L: *State, idx: i32) LuaType {
        const r = api(.lua_gettable)(L, idx);
        return if (comptime lang.atLeast(.lua53)) r else L.typeOf(-1);
    }

    /// Pushes the value of the table at the given index, with the key at the
    /// top of the stack, and return its type.
    pub inline fn getTableBlind(L: *State, idx: i32) void {
        _ = api(.lua_gettable)(L, idx);
    }

    /// Pushes table field `k` onto the stack.
    pub inline fn getField(L: *State, idx: i32, k: c_str) LuaType {
        const r = api(.lua_getfield)(L, idx, k);
        return if (comptime lang.atLeast(.lua53)) r else L.typeOf(-1);
    }

    /// Pushes table field `k` onto the stack, and return its type.
    pub inline fn getFieldBlind(L: *State, idx: i32, k: c_str) void {
        _ = api(.lua_getfield)(L, idx, k);
    }

    /// Pushes the value of the table at the given index, with the integer key
    /// `n`, onto the stack.
    pub inline fn getI(L: *State, idx: i32, n: Integer) LuaType {
        const r = api(.lua_geti)(L, idx, n);
        if (comptime lang.atLeast(.lua53)) return r;
        return L.typeOf(-1);
    }
    /// Alias for `getI`, for compatibility with ziglua.
    pub const getIndex = getI;

    /// Pushes the value of the table at the given index, with the integer key
    /// `n`, onto the stack, and return its type.
    pub inline fn getIBlind(L: *State, idx: i32, n: Integer) void {
        _ = api(.lua_geti)(L, idx, n);
    }

    /// Pushes the value of the table at the given index, with the pointer key
    /// `p`, onto the stack.
    pub inline fn rawGet(L: *State, idx: i32) LuaType {
        const r = api(.lua_rawget)(L, idx);
        if (comptime lang.atLeast(.lua53)) return r;
        return L.typeOf(-1);
    }
    /// Alias for `rawGet`, for compatibility with ziglua.
    pub const rawGetTable = rawGet;

    /// Pushes the value of the table at the given index, with the pointer key
    pub inline fn rawGetBlind(L: *State, idx: i32) void {
        _ = api(.lua_rawget)(L, idx);
    }

    /// Pushes the value of the table at the given index, with the integer key
    /// `n`, onto the stack.
    pub inline fn rawGetI(L: *State, idx: i32, n: Integer) LuaType {
        const r = api(.lua_rawgeti)(L, idx, n);
        if (comptime lang.atLeast(.lua53)) return r;
        return L.typeOf(-1);
    }
    /// Alias for `rawGetI`, for compatibility with ziglua.
    pub const rawGetIndex = rawGetI;

    /// Pushes the value of the table at the given index, with the integer key
    /// `n`, onto the stack, and return its type.
    pub inline fn rawGetIBlind(L: *State, idx: i32, n: Integer) void {
        _ = api(.lua_rawgeti)(L, idx, n);
    }

    /// Pushes the value of the table at the given index, with the pointer key
    /// `p`, onto the stack.
    pub inline fn rawGetP(L: *State, idx: i32, p: c_voidpc) LuaType {
        const r = api(.lua_rawgetp)(L, idx, p);
        if (comptime lang.atLeast(.lua53)) return r;
        return L.typeOf(-1);
    }
    /// Alias for `rawGetP`, for compatibility with ziglua.
    const rawGetPtr = rawGetP;

    /// Pushes the value of the table at the given index, with the pointer key
    /// `p`, onto the stack, and return its type.
    pub inline fn rawGetPBlind(L: *State, idx: i32, p: c_voidpc) void {
        _ = api(.lua_rawgetp)(L, idx, p);
    }

    /// [-0,+1,m] Creates a new table and pushes it onto the stack.
    pub inline fn createTable(L: *State, narr: i32, nrec: i32) void {
        api(.lua_createtable)(L, narr, nrec);
    }

    /// [-0,+1,m] Creates a new empty table and pushes it onto the stack. It is
    /// equivalent to `L.createTable(0,0)`.
    pub inline fn newTable(L: *State) void {
        createTable(L, 0, 0);
    }

    /// `[-0,+1,m]` Creates a new userdata with the given size, pushes it onto
    /// the stack, and returns a pointer to the new userdata block.
    pub inline fn newUserdataRaw(L: *State, size: usize) c_voidp {
        return api(.lua_newuserdata)(L, size);
    }

    /// `[-0,+1,m]` Creates a new userdata with the given size and `nuvalue`
    /// user values, pushes it onto the stack, and returns a pointer to the new
    /// userdata block.
    pub inline fn newUserdataUVRaw(L: *State, size: usize, nuvalue: i32) c_voidp {
        return api(.lua_newuserdatauv)(L, size, nuvalue);
    }

    /// `[-0,+1,m]` Creates a new userdata and pushes it onto the stack.
    pub inline fn newUserdata(L: *State, comptime T: type) *T {
        if (comptime lang.atLeast(.lua54)) return newUserdataUV(L, T, 1);
        return @ptrCast(@alignCast(newUserdataRaw(L, @sizeOf(T))));
    }

    /// `[-0,+1,m]` Creates a new userdata with `nuvalue` user values, and pushes
    /// it onto the stack. Available in Lua 5.4+.
    pub inline fn newUserdataUV(L: *State, comptime T: type, nuvalue: i32) *T {
        if (comptime !lang.atLeast(.lua54)) notAvail("newUserdataUV");
        return @ptrCast(@alignCast(newUserdataUVRaw(L, @sizeOf(T), nuvalue)));
    }

    /// `[-0,+1,m]` Creates a new userdata large enough for `count` elements of
    /// type `T`, pushes it onto the stack, and returns it as a slice.
    /// The `nuvalue` will ignored and treated as `1` before Lua 5.4.
    pub inline fn newUserdataSlice(L: *State, comptime T: type, count: usize, nuvalue: i32) []T {
        const ptr: [*]T = @ptrCast(@alignCast(if (comptime lang.atLeast(.lua54))
            newUserdataUVRaw(L, @sizeOf(T) * count, nuvalue)
        else
            newUserdataRaw(L, @sizeOf(T) * count)));
        return ptr[0..count];
    }

    /// [-0,+(0|1),-] Pushes the metatable of the value at the given index onto
    /// the stack, and returns whether it exists.
    pub inline fn getMetatable(L: *State, idx: i32) bool {
        return api(.lua_getmetatable)(L, idx) != 0;
    }

    /// Pushes the user value of the userdata at the given index onto the stack, and
    /// returns whether it exists.
    pub inline fn getUserValue(L: *State, idx: i32) LuaType {
        if (comptime lang.in(.{ .lua51, .lua52, .luajit })) {
            if (comptime lang.in(.{ .lua51, .luajit }))
                api(.lua_getfenv)(L, idx)
            else
                _ = api(.lua_getuservalue)(L, idx);
            return L.typeOf(-1);
        }
        if (comptime lang.eql(.lua53))
            return api(.lua_getuservalue)(L, idx);
        return getIUserValue(L, idx, 1);
    }

    /// Pushes the user value of the userdata at the given index onto the stack,
    /// without returns whether it exists, push `nil` instead.
    pub inline fn getUserValueBlind(L: *State, idx: i32) void {
        if (comptime lang.in(.{ .lua51, .luajit }))
            api(.lua_getfenv)(L, idx)
        else if (comptime lang.in(.{ .lua52, .lua53 }))
            _ = api(.lua_getuservalue)(L, idx)
        else
            _ = getIUserValue(L, idx, 1);
    }
    /// Alias for `getUserValue`, for compatibility with Lua 5.1.
    pub const getFnEnvironment = getUserValueBlind;

    /// Pushes the user value `n` of the userdata at the given index onto the
    /// stack, and returns whether it exists.
    pub inline fn getIUserValue(L: *State, idx: i32, n: i32) LuaType {
        return api(.lua_getiuservalue)(L, idx, n);
    }

    // set functions (stack -> Lua)
    //

    /// Pops a value from the stack and sets it as the new value of the global
    /// variable `name`.
    pub inline fn setGlobal(L: *State, name: c_str) void {
        if (comptime lang.in(.{ .lua51, .luajit })) return api(.lua_setfield)(L, globals_index, name);
        api(.lua_setglobal)(L, name);
    }

    /// [-2,+0,e] Pops a value from the stack and sets it as the new value of
    /// the table at the given index, with the key at the top of the stack.
    pub inline fn setTable(L: *State, idx: i32) void {
        api(.lua_settable)(L, idx);
    }

    /// [-1,+0,e] Pops a value from the stack and sets it as the new value of
    /// field `k` in the table at the given index.
    pub inline fn setField(L: *State, idx: i32, k: c_str) void {
        api(.lua_setfield)(L, idx, k);
    }

    /// Pops a value from the stack and sets it as the new value of the table at the
    /// given index, with the integer key `n`.
    pub inline fn setI(L: *State, idx: i32, n: Integer) void {
        api(.lua_seti)(L, idx, n);
    }
    /// Alias for `setI`, for compatibility with ziglua.
    pub const setIndex = setI;

    /// [-2,+0,m] Pops a value from the stack and sets it as the new value of
    /// the table at the given index, with the key at the top of the stack. Does
    /// not invoke metamethods.
    pub inline fn rawSet(L: *State, idx: i32) void {
        api(.lua_rawset)(L, idx);
    }
    /// Alias for `rawSet`, for compatibility with ziglua.
    pub const rawSetTable = rawSet;

    /// Pops a value from the stack and sets it as the new value of the table at the
    /// given index, with the integer key `n`. Does not invoke metamethods.
    pub inline fn rawSetI(L: *State, idx: i32, n: Integer) void {
        api(.lua_rawseti)(L, idx, n);
    }
    /// Alias for `rawSetI`, for compatibility with ziglua.
    pub const rawSetIndex = rawSetI;

    /// Pops a value from the stack and sets it as the new value of the table at the
    /// given index, with the pointer key `p`. Does not invoke metamethods.
    pub inline fn rawSetP(L: *State, idx: i32, p: c_voidpc) void {
        api(.lua_rawsetp)(L, idx, p);
    }
    /// Alias for `rawSetP`, for compatibility with ziglua.
    pub const rawSetPtr = rawSetP;

    /// [-1,+0,-] Pops a value from the stack and sets it as the new metatable
    /// of the value at the given index.
    pub inline fn setMetatable(L: *State, idx: i32) void {
        api(.lua_setmetatable)(L, idx);
    }

    /// Pops a value from the stack and sets it as the new user value of the
    /// userdata at the given index.
    pub inline fn setUserValue(L: *State, idx: i32) bool {
        if (comptime lang.in(.{ .lua51, .luajit }))
            return api(.lua_setfenv)(L, idx) != 0;
        if (comptime lang.between(.lua52, .lua53)) {
            _ = api(.lua_setuservalue)(L, idx);
            return true;
        }
        return setIUserValue(L, idx, 1);
    }
    /// Alias for `setUserValue`, for compatibility with Lua 5.1.
    pub const setFnEnvironment = setUserValue;

    /// Pops a value from the stack and sets it as the new user value `n` of the
    /// userdata at the given index.
    pub inline fn setIUserValue(L: *State, idx: i32, n: i32) bool {
        return api(.lua_setiuservalue)(L, idx, n) != 0;
    }

    // 'load' and 'call' functions (load and run Lua code)
    //

    /// Calls a function. Set `mult_ret = true` to return all results.
    pub inline fn call(L: *State, a: CallArgs) void {
        const nrets: i32 = if (a.mult_ret) -1 else a.rets;
        if (comptime lang.atLeast(.lua52))
            api(.lua_callk)(L, a.args, nrets, a.ctx, a.k)
        else
            api(.lua_call)(L, a.args, nrets);
    }

    /// Calls a function in protected mode.
    pub inline fn pcall(L: *State, a: CallArgs) Error!void {
        const nrets: i32 = if (a.mult_ret) -1 else a.rets;
        return checkErr(if (comptime lang.atLeast(.lua52))
            api(.lua_pcallk)(L, a.args, nrets, a.msg_idx, a.ctx, a.k)
        else
            api(.lua_pcall)(L, a.args, nrets, a.msg_idx));
    }

    /// `[-0,+0,-]` This function is called by a continuation function to
    /// retrieve the status of the thread and a context information.
    /// Returns the continuation context. Available in Lua 5.2.
    pub inline fn getContext(L: *State) ?KContext {
        if (comptime !lang.eql(.lua52)) notAvail("getContext");
        var ctx: c_int = undefined;
        if (api(.lua_getctx)(L, &ctx) != 0) return @intCast(ctx);
        return null;
    }

    /// `[-0,+1,m]` Loads a Lua chunk from a string and pushes it onto the stack
    /// as a function.
    pub inline fn loadString(L: *State, s: c_str) Error!void {
        return checkErr(api(.luaL_loadstring)(L, s));
    }

    /// `[-1,+(nresults|1),e]` Loads and executes the string `s` as a Lua chunk.
    pub inline fn doString(L: *State, s: c_str) Error!void {
        try L.loadString(s);
        try L.pcall(.{});
    }

    /// `[-0,+1,m]` Loads a buffer as a Lua chunk. `name` is used for error
    /// messages. `chunkname` is used as the chunk name for error messages.
    pub inline fn loadBuffer(L: *State, buf: []const u8, chunkname: c_str) Error!void {
        return checkErr(api(.luaL_loadbuffer)(L, buf.ptr, buf.len, chunkname));
    }

    /// `[-0,+1,m]` Loads a buffer as a Lua chunk, with a mode string that
    /// specifies how to interpret the chunk ("t" for text, "b" for binary,
    /// or "bt"/"tb" for both). Available in Lua 5.2+.
    pub inline fn loadBufferX(L: *State, buf: []const u8, chunkname: c_str, mode: c_str) Error!void {
        return checkErr(api(.luaL_loadbufferx)(L, buf.ptr, buf.len, chunkname, mode));
    }

    /// `[-0,+1,m]` Loads a Lua chunk from a file and pushes it onto the stack
    /// as a function.
    pub inline fn loadFile(L: *State, filename: c_str) Error!void {
        if (comptime lang.in(.{ .lua51, .luajit, .luau }))
            return checkErr(api(.luaL_loadfile)(L, filename));
        return checkErr(api(.luaL_loadfilex)(L, filename, null));
    }

    /// `[-0,+1,m]` Loads a Lua chunk from a file with a mode string.
    /// Available in Lua 5.2+.
    pub inline fn loadFileX(L: *State, filename: c_str, mode: c_str) Error!void {
        return checkErr(api(.luaL_loadfilex)(L, filename, mode));
    }

    /// `[-0,+?,e]` Loads and executes a Lua chunk from a file.
    pub inline fn doFile(L: *State, filename: c_str) Error!void {
        try L.loadFile(filename);
        try L.pcall(.{ .mult_ret = true });
    }

    /// Calls the C function `fn` in protected mode. Available in Lua 5.1 only.
    pub inline fn cpCall(L: *State, f: CFn, ud: c_voidp) Error!void {
        if (comptime !lang.in(.{ .lua51, .luajit })) notAvail("cpCall");
        return checkErr(api(.lua_cpcall)(L, f, ud));
    }

    /// `[-0,+1,m]` Loads a Lua chunk via a reader function.
    /// `mode` specifies how to interpret the chunk on Lua 5.2+; on 5.1 it
    /// is ignored.
    pub inline fn load(L: *State, reader: Reader, data: c_voidp, chunkname: c_str, mode: ?c_str) Error!void {
        if (comptime lang.in(.{ .lua51, .luajit })) {
            const T = *const fn (*State, Reader, c_voidp, c_str) callconv(.c) c_int;
            return checkErr(@extern(T, extName(.lua_load))(L, reader, data, chunkname));
        }
        const T = *const fn (*State, Reader, c_voidp, c_str, c_str) callconv(.c) c_int;
        return checkErr(@extern(T, extName(.lua_load))(L, reader, data, chunkname, mode orelse "t"));
    }

    /// `[-0,+0,-]` Dumps a function on the stack as a binary chunk.
    /// `strip` controls debug info removal on Lua 5.3+; ignored on earlier
    /// versions.
    pub inline fn dump(L: *State, writer: Writer, data: c_voidp, strip: bool) Error!void {
        if (comptime lang.atLeast(.lua53)) {
            const T = *const fn (*State, Writer, c_voidp, c_int) callconv(.c) c_int;
            return checkErr(@extern(T, extName(.lua_dump))(L, writer, data, @intFromBool(strip)));
        }
        const T = *const fn (*State, Writer, c_voidp) callconv(.c) c_int;
        return checkErr(@extern(T, extName(.lua_dump))(L, writer, data));
    }

    // miscellaneous functions
    //

    /// [-1,+0,v] Raises a Lua error, using the value at the top of the stack as
    /// the error object.
    pub inline fn raiseError(L: *State) noreturn {
        api(.lua_error)(L);
        unreachable;
    }

    /// [-0,+0,v] Raises a Lua error with a formatted message.
    pub inline fn raiseErrorStr(L: *State, fmt: c_str, args: anytype) noreturn {
        @call(.auto, api(.luaL_error), .{ L, fmt } ++ args);
        unreachable;
    }

    /// `[-0,+0,-]` Emits a warning. `tocont` controls whether the message can
    /// be continued in subsequent calls. Available in Lua 5.4+.
    pub inline fn warning(L: *State, msg: c_str, tocont: bool) void {
        if (comptime !lang.atLeast(.lua54)) notAvail("warning");
        api(.lua_warning)(L, msg, @intFromBool(tocont));
    }

    /// `[-0,+0,-]` Sets the warning function to be called when Lua emits a warning.
    /// Available in Lua 5.4+.
    pub inline fn setWarnF(L: *State, f: WarnFn, ud: c_voidp) void {
        if (comptime !lang.atLeast(.lua54)) notAvail("setWarnF");
        api(.lua_setwarnf)(L, f, ud);
    }

    /// `[-0,+0,-]` Marks the value at the given index as to-be-closed
    /// when the current scope exits. Available in Lua 5.4+.
    pub inline fn toClose(L: *State, idx: i32) void {
        if (comptime !lang.atLeast(.lua54)) notAvail("toClose");
        api(.lua_toclose)(L, idx);
    }

    /// `[-0,+0,-]` Closes a to-be-closed variable at the given index,
    /// releasing its resources. Available in Lua 5.4+.
    pub inline fn closeSlot(L: *State, idx: i32) void {
        if (comptime !lang.atLeast(.lua54)) notAvail("closeSlot");
        api(.lua_closeslot)(L, idx);
    }

    /// [-1,+(2|0),v] Pops a key from the stack, and pushes a key–value pair
    /// from the table at the given index, the "next" pair after the given key.
    /// If there are no more elements in the table, then `next` returns `false`
    /// and pushes nothing.
    pub inline fn next(L: *State, idx: i32) bool {
        return api(.lua_next)(L, idx) != 0;
    }

    /// [-n,+1,e] Concatenates the n values at the top of the stack, pops them,
    /// and leaves the result on the top.
    /// If n is 1, the result is the single value on the stack (that is, the
    /// function does nothing); if n is 0, the result is the empty string.
    /// Concatenation is performed following the usual semantics of Lua.
    pub inline fn concat(L: *State, n: i32) void {
        api(.lua_concat)(L, n);
    }

    /// Returns the length of the value at the given index.
    pub inline fn len(L: *State, idx: i32) usize {
        return api(.lua_len)(L, idx);
    }

    /// `[-?,+?,e]` Yields a coroutine.
    pub inline fn yield(L: *State, a: CallArgs) c_int {
        const nrets = if (a.mult_ret) -1 else a.rets;
        if (comptime lang.in(.{ .lua51, .luajit, .luau }))
            return api(.lua_yield)(L, nrets);
        if (comptime lang.eql(.lua52)) {
            const T = *const fn (*State, c_int, c_int, ?KFn) callconv(.c) c_int;
            return @extern(T, extName(.lua_yieldk))(L, nrets, a.ctx, a.k);
        }
        const T = *const fn (*State, c_int, KContext, ?KFn) callconv(.c) c_int;
        return @extern(T, extName(.lua_yieldk))(L, nrets, a.ctx, a.k);
    }

    /// `[-0,+0,-]` Returns whether the running coroutine can be yielded.
    /// Available in Lua 5.3+.
    pub inline fn isYieldable(L: *State) bool {
        if (comptime !lang.atLeast(.lua53)) notAvail("isYieldable");
        return api(.lua_isyieldable)(L) != 0;
    }

    /// `[-?,+?,?]` Resumes a coroutine. Returns the status of the resumed thread.
    pub inline fn resumeThread(L: *State, from: ?*State, narg: i32, nres: ?*i32) Error!Status {
        const rc = if (comptime lang.eql(.lua51) or lang.eql(.luajit)) rc: {
            const T = *const fn (*State, c_int) callconv(.c) c_int;
            break :rc @extern(T, extName(.lua_resume))(L, narg);
        } else if (comptime lang.between(.lua52, .lua53)) rc: {
            const T = *const fn (*State, *State, c_int) callconv(.c) c_int;
            break :rc @extern(T, extName(.lua_resume))(L, from orelse L, narg);
        } else rc: {
            const T = *const fn (*State, *State, c_int, *i32) callconv(.c) c_int;
            break :rc @extern(T, extName(.lua_resume))(L, from orelse L, narg, nres orelse unreachable);
        };
        try checkErr(rc);
        return @enumFromInt(rc);
    }

    // Debug API
    //

    /// `[-0,+0,-]` Gets information about the activation record at the given
    /// stack `level`. Returns `null` if the level is invalid.
    pub inline fn getStack(L: *State, level: i32) ?DebugInfo {
        var raw: DebugInfo.Raw = undefined;
        if (api(.lua_getstack)(L, level, &raw) == 0) return null;
        return .{ ._ci = raw._ci };
    }

    /// `[-0,+0,-]` Gets information about a function or activation record
    /// and fills the [`DebugInfo`] structure. The `what` parameter specifies
    /// which fields to fill (see [`InfoWhat`]).
    pub inline fn getInfo(L: *State, what: InfoWhat, ar: *DebugInfo) void {
        var raw: DebugInfo.Raw = undefined;
        raw._ci = ar._ci;
        api(.lua_getinfo)(L, &what.toWhat(), &raw);
        ar.* = DebugInfo.fromRaw(what, &raw);
    }

    /// `[-0,+(0|1),-]` Gets information about a local variable of the
    /// activation record at `ar`, pushing the variable's value and returning
    /// its name.
    pub inline fn getLocal(L: *State, ar: *DebugInfo, n: i32) ?c_str {
        var raw: DebugInfo.Raw = undefined;
        raw._ci = ar._ci;
        return api(.lua_getlocal)(L, &raw, n);
    }

    /// `[-0,+0,-]` Sets the value of a local variable. The value to be
    /// assigned is popped from the stack, and `name` is returned.
    pub inline fn setLocal(L: *State, ar: *DebugInfo, n: i32) ?c_str {
        var raw: DebugInfo.Raw = undefined;
        raw._ci = ar._ci;
        return api(.lua_setlocal)(L, &raw, n);
    }

    /// `[-0,+0,-]` Sets the value of an upvalue. The value to be assigned is
    /// popped from the stack, and `name` is returned.
    pub inline fn setUpvalue(L: *State, func_idx: i32, n: i32) ?c_str {
        return api(.lua_setupvalue)(L, func_idx, n);
    }

    /// `[-0,+(0|1),-]` Gets information about the `n`-th upvalue of the closure
    /// at index `func_idx`.
    /// It pushes the upvalue's value onto the stack and returns its name.
    /// Returns `null` (and pushes nothing) when the index `n` is greater than
    /// the number of upvalues.
    pub inline fn getUpvalue(L: *State, func_idx: i32, n: i32) ?c_str {
        return api(.lua_getupvalue)(L, func_idx, n);
    }

    /// `[-0,+0,-]` Returns a unique identifier for the `n`-th upvalue of
    /// the closure at `func_idx`. Available in Lua 5.2+.
    pub inline fn upvalueId(L: *State, func_idx: i32, n: i32) c_voidp {
        return api(.lua_upvalueid)(L, func_idx, n);
    }

    /// `[-0,+0,-]` Makes the `n1`-th upvalue of the closure at `func_idx1`
    /// refer to the same value as the `n2`-th upvalue of the closure at
    /// `func_idx2`. Available in Lua 5.2+.
    pub inline fn upvalueJoin(L: *State, func_idx1: i32, n1: i32, func_idx2: i32, n2: i32) void {
        api(.lua_upvaluejoin)(L, func_idx1, n1, func_idx2, n2);
    }

    /// Returns the current hook function.
    pub inline fn getHook(L: *State) ?*const fn (*State, *DebugInfo.Raw) callconv(.c) void {
        return api(.lua_gethook)(L);
    }

    /// Returns the current hook mask.
    pub inline fn getHookMask(L: *State) HookMask {
        const m = api(.lua_gethookmask)(L);
        return .{
            .call = (m & (1 << 0)) != 0,
            .ret = (m & (1 << 1)) != 0,
            .line = (m & (1 << 2)) != 0,
            .count = (m & (1 << 3)) != 0,
        };
    }

    /// Returns the current hook count.
    pub inline fn getHookCount(L: *State) i32 {
        return api(.lua_gethookcount)(L);
    }

    /// Sets the debugging hook function. Use [`hookFn`] to wrap a Zig function
    /// into a C-compatible hook. `mask` specifies on which events the hook
    /// will be called. `count` is only meaningful when `mask.count` is set.
    pub inline fn setHook(L: *State, f: *const fn (*State, *DebugInfo.Raw) callconv(.c) void, mask: HookMask, count: i32) void {
        api(.lua_sethook)(L, f, mask.toInt(), count);
    }

    // auxiliary library functions
    //

    /// [-0,+(0|1),m] Pushes onto the stack the field e from the metatable of
    /// the object at index obj and returns the type of the pushed value.
    /// If the object does not have a metatable, or if the metatable does not
    /// have this field, pushes nothing and returns `.nil`.
    pub inline fn getMetaField(L: *State, idx: i32, k: c_str) LuaType {
        return api(.luaL_getmetafield)(L, idx, k);
    }

    /// [-0,+(0|1)m,e] Calls a metamethod.
    /// If the object at index `obj` has a metatable and this metatable has a
    /// field `e`, this function calls this field passing the object as its only
    /// argument.
    /// In this case this function returns true and pushes onto the stack the
    /// value returned by the call.
    /// If there is no metatable or no metamethod, this function returns false
    /// without pushing any value on the stack.
    pub inline fn callMeta(L: *State, obj: i32, e: c_str) bool {
        return api(.luaL_callmeta)(L, obj, e) != 0;
    }

    // luaL_checkstack (same)

    /// `[-0,+1,-]` Pushes the global environment table onto the stack.
    /// Available in Lua 5.2+.
    pub inline fn pushGlobalTable(L: *State) void {
        L.rawGetIBlind(registry_index, 2); // LUA_RIDX_GLOBALS
    }

    /// `[-0,+1,m]` Pushes a copy of the string `s` with every occurrence of
    /// `p` replaced by `r`, and returns the result.
    pub inline fn gsub(L: *State, s: c_str, p: c_str, r: c_str) c_str {
        return api(.luaL_gsub)(L, s, p, r);
    }

    /// `[-0,+1,m]` Pushes a string identifying the current position of the
    /// caller at level `lvl` (e.g., "main chunk", "function X").
    pub inline fn where(L: *State, lvl: i32) void {
        api(.luaL_where)(L, lvl);
    }

    /// `[-0,+1,m]` Produces a traceback from thread `L1` starting at stack
    /// level `level`, and pushes it onto `L`'s stack.
    pub inline fn traceback(L: *State, L1: *State, msg: c_str, level: i32) void {
        api(.luaL_traceback)(L, L1, msg, level);
    }

    /// `[-0,+1,e]` Loads the C function `open_fn`, pushes it onto the stack, If
    /// `mod_name` is not already present in `package.loaded`, calls function
    /// `open_fn` with string `mod_name` as an argument and sets the call result
    /// in `package.loaded[mod_name]`, as if that function has been called
    /// through `require`.
    /// If `global` is true, also stores the module into global `mod_name`.
    /// Leaves a copy of the module on the stack.
    pub inline fn requireF(L: *State, mod_name: [*:0]const u8, open_fn: CFn, global: bool) void {
        if (comptime lang.in(.{ .lua51, .luajit, .luau })) {
            L.pushCFunction(open_fn);
            L.pushStringBlind(mod_name);
            return L.call(.{ .args = 1 });
        }
        api(.luaL_requiref)(L, mod_name, open_fn, @intFromBool(global));
    }

    /// Checks that the Lua library was compiled with the same Lua version as
    /// the caller. Available in Lua 5.2+.
    pub inline fn checkVersion(L: *State) void {
        if (comptime !lang.atLeast(.lua52)) notAvail("checkVersion");
        const version_num = lang.num();
        if (comptime lang.eql(.lua52)) {
            const T = *const fn (*State, Number) callconv(.c) void;
            @extern(T, extName(.luaL_checkversion_))(L, version_num);
        } else {
            const T = *const fn (*State, Number, usize) callconv(.c) void;
            const LUAL_NUMSIZES = @sizeOf(Integer) * 16 + @sizeOf(Number);
            @extern(T, extName(.luaL_checkversion_))(L, version_num, LUAL_NUMSIZES);
        }
    }

    /// `[-0,+0,v]` Returns the length of the value at `idx`, respecting the
    /// `__len` metamethod. Raises an error if the value does not have a length.
    pub inline fn lenRaiseErr(L: *State, idx: i32) Integer {
        return api(.luaL_len)(L, idx);
    }

    /// `[-0,+1,e]` Converts the string `s` to a number and pushes the number
    /// onto the stack. Returns the number of bytes consumed from the string,
    /// or 0 if the string is not a valid number.
    pub inline fn stringToNumber(L: *State, s: c_str) usize {
        return api(.lua_stringtonumber)(L, s);
    }

    /// `[-0,+(0|1),e]` Pushes onto the stack the metatable associated with
    /// `tname` in the registry (see [`newMetatable`]), or `nil` if there is
    /// no metatable associated with that name.
    pub inline fn getMetatableRegistry(L: *State, tname: c_str) LuaType {
        return L.getField(registry_index, tname);
    }

    /// `[-1,+0,e]` Sets the metatable of the object on top of the stack as
    /// the metatable associated with `tname` in the registry.
    pub inline fn setMetatableRegistry(L: *State, tname: c_str) void {
        api(.luaL_setmetatable)(L, tname);
    }

    /// `[-0,+1,e]` Ensures that `t[fname]` (where `t` is the table at `idx`)
    /// is a table and pushes it. Returns `true` if it already existed,
    /// `false` if freshly created.
    pub inline fn getSubtable(L: *State, idx: i32, fname: c_str) bool {
        return api(.luaL_getsubtable)(L, idx, fname) != 0;
    }

    /// [-0,+1,m] If the registry already has the key `tname`, returns false.
    /// Otherwise, creates a new table to be used as a metatable for userdata,
    /// adds to this new table the pair `__name = tname`, adds to the registry
    /// the pair `[tname] = new table`, and returns true.
    /// In both cases, the function pushes onto the stack the final value
    /// associated with `tname` in the registry.
    pub inline fn newMetatable(L: *State, tname: c_str) bool {
        return api(.luaL_newmetatable)(L, tname) != 0;
    }

    /// `[-0,+0,v]` Checks whether the function argument `arg` is a userdata of
    /// the type `tname` (see [`newMetatable`]) and returns the userdata's
    /// memory-block address.
    pub inline fn checkUdata(L: *State, idx: i32, tname: c_str) *anyopaque {
        return api(.luaL_checkudata)(L, idx, tname);
    }

    /// `[-0,+0,v]` Like [`checkUdata`] but with a Zig type parameter.
    pub inline fn checkUserdata(L: *State, comptime T: type, idx: i32, tname: c_str) *T {
        return @ptrCast(@alignCast(checkUdata(L, idx, tname)));
    }

    /// `[-0,+0,v]` Like [`checkUserdata`] but returns the userdata as a slice of `T`.
    pub inline fn checkUdataSlice(L: *State, comptime T: type, idx: i32, tname: c_str) []T {
        const ptr = checkUserdata(L, u8, idx, tname);
        const l = rawLen(L, idx);
        return @as([*]T, @ptrCast(@alignCast(ptr)))[0..@divExact(l, @sizeOf(T))];
    }

    /// `[-0,+0,v]` Like [`checkUdata`] but returns `null` instead of raising
    /// an error if the userdata does not have the expected metatable.
    pub inline fn testUdata(L: *State, idx: i32, tname: c_str) c_voidp {
        if (comptime lang.atLeast(.lua52))
            return api(.luaL_testudata)(L, idx, tname);
        // Lua 5.1: manual implementation
        const p = api(.lua_touserdata)(L, idx);
        if (p != null) {
            if (getMetatable(L, idx)) {
                _ = getMetatableRegistry(L, tname);
                if (L.typeOf(-2) == .nil or !equal(L, -1, -2)) {
                    L.pop(2);
                    return null;
                }
                L.pop(2);
                return p;
            }
        }
        return null;
    }

    /// `[-0,+0,v]` Like [`testUdata`] but with a Zig type parameter.
    pub inline fn testUserdata(L: *State, comptime T: type, idx: i32, tname: c_str) ?*T {
        const ud = testUdata(L, idx, tname);
        return if (ud) |p| @ptrCast(@alignCast(p)) else null;
    }

    /// `[-0,+0,v]` Like [`testUserdata`] but returns the userdata as a slice of `T`.
    pub inline fn testUdataSlice(L: *State, comptime T: type, idx: i32, tname: c_str) ?[]T {
        const ud = testUdata(L, idx, tname);
        if (ud) |p| {
            const l = rawLen(L, idx);
            return @as([*]T, @ptrCast(@alignCast(p)))[0..@divExact(l, @sizeOf(T))];
        }
        return null;
    }

    /// `[-0,+0,-]` Converts the userdata at the given index to a slice of `T`.
    pub inline fn toUserdataSlice(L: *State, comptime T: type, idx: i32) ?[]T {
        const ptr = toUserdata(L, u8, idx);
        if (ptr) |p| {
            const l = rawLen(L, idx);
            return @as([*]T, @ptrCast(@alignCast(p)))[0..@divExact(l, @sizeOf(T))];
        }
        return null;
    }

    // luaL_where

    /// `[-1,+0,m]` Creates and returns a reference, in the table at index t,
    /// for the object on the top of the stack (and pops the object).
    pub inline fn ref(L: *State, t: i32) RefID {
        return api(.luaL_ref)(L, t);
    }

    /// `[+0,-0,-]` Releases a reference (see [`ref`]). The integer `ref_id`
    /// must be either `.no_ref`, `.ref_nil`, or a reference previously returned
    /// by [`ref`] and not already released.
    /// If `ref_id` is either `.no_ref` or `.ref_nil` this function does
    /// nothing.  Otherwise, the entry is removed from the table, so that the
    /// referred object can be collected and the reference ref can be used again
    /// by [`ref`].
    pub inline fn unref(L: *State, t: i32, ref_id: RefID) void {
        api(.luaL_unref)(L, t, ref_id);
    }

    /// `[-0,+0,v]` Checks whether the function argument `arg` has type `t`. See
    /// [`typeOf`] for the encoding of types for `t`.
    pub inline fn checkType(L: *State, arg: i32, t: LuaType) void {
        api(.luaL_checktype)(L, arg, t);
    }

    /// `[-0,+0,v]` Checks that the function has a (non-missing) argument at
    /// position `arg`.
    pub inline fn checkAny(L: *State, arg: i32) void {
        api(.luaL_checkany)(L, arg);
    }

    /// `[-0,+0,v]` Checks that argument `arg` is a number and returns it.
    pub inline fn checkNumber(L: *State, arg: i32) Number {
        return api(.luaL_checknumber)(L, arg);
    }

    /// `[-0,+0,v]` Checks that argument `arg` is a string and returns it.
    pub inline fn checkString(L: *State, arg: i32) c_str {
        return api(.luaL_checklstring)(L, arg, null).?;
    }

    /// `[-0,+0,v]` Checks that argument `arg` is a string and returns it as a slice.
    pub inline fn checkSlice(L: *State, arg: i32) []const u8 {
        var l: usize = undefined;
        const ptr = api(.luaL_checklstring)(L, arg, &l).?;
        return ptr[0..l];
    }

    /// `[-0,+0,v]` If argument `arg` is present and is an integer, returns
    /// it; if absent or nil, returns `def`; otherwise returns `null`.
    pub inline fn optInteger(L: *State, arg: i32, def: Integer) Integer {
        return if (L.isNoneOrNil(arg)) def else L.checkInteger(arg);
    }

    /// `[-0,+0,v]` If argument `arg` is present and is a number, returns
    /// it; if absent or nil, returns `def`; otherwise returns `null`.
    pub inline fn optNumber(L: *State, arg: i32, def: Number) Number {
        return if (L.isNoneOrNil(arg)) def else L.checkNumber(arg);
    }

    /// `[-0,+0,v]` If argument `arg` is present and is a string, returns
    /// it; if absent or nil, returns `def`; otherwise returns `null`.
    pub inline fn optString(L: *State, arg: i32, def: c_str) c_str {
        return if (L.isNoneOrNil(arg)) def else L.checkString(arg);
    }

    /// `[-0,+0,v]` If argument `arg` is present and is a string, returns
    /// it; if absent or nil, returns `def`; otherwise returns `null`.
    pub inline fn optSlice(L: *State, arg: i32, def: ?c_str) []const u8 {
        var l: usize = undefined;
        const s = api(.luaL_optlstring)(L, arg, def, &l);
        return s[0..l];
    }

    /// `[-0,+0,v]` Checks that argument `arg` is one of the strings in the
    /// enum `T` and returns the corresponding enum value.
    /// `[-0,+0,v]` Checks that argument `arg` is one of the strings in `lst`
    /// (a null-terminated array) and returns its index.
    pub inline fn checkOption(L: *State, arg: i32, def: c_str, lst: [*:null]const ?c_str) c_int {
        return api(.luaL_checkoption)(L, arg, def, lst);
    }

    /// `[-0,+0,v]` Checks that argument `arg` is one of the variants of enum `T`
    /// and returns the corresponding enum value. `def` is the default.
    pub inline fn checkEnum(L: *State, comptime T: type, arg: i32, comptime def: T) T {
        const names = comptime blk: {
            const fields = @typeInfo(T).@"enum".fields;
            var arr: [fields.len:null]?c_str = undefined;
            for (fields, 0..) |f, i| arr[i] = f.name.ptr;
            const ns = arr;
            break :blk &ns;
        };
        const idx = checkOption(L, arg, @tagName(def), names);
        return @enumFromInt(idx);
    }

    /// `[-0,+0,v]` Raises an error reporting a problem with argument `arg` of
    /// the C function that called it, using a standard message that includes
    /// `extramsg` as a comment.
    /// This function never returns.
    pub inline fn argError(L: *State, arg: i32, extramsg: c_str) noreturn {
        api(.luaL_argerror)(L, arg, extramsg);
        unreachable;
    }

    /// `[-0,+0,v]` Checks whether `cond` is true. If it is not, raises an error
    /// with a standard message (see [`argError`]).
    pub inline fn argCheck(L: *State, cond: bool, arg: i32, extramsg: c_str) void {
        if (!cond) L.argError(arg, extramsg);
    }

    /// `[-0,+0,v]` Raises an error if `cond` is false, reporting that
    /// argument `arg` was expected to be of type `tname`. Available in Lua 5.4+.
    pub inline fn argExpected(L: *State, cond: bool, arg: i32, tname: c_str) void {
        if (comptime !lang.atLeast(.lua54)) notAvail("argExpected");
        if (!cond) {
            const T = *const fn (*State, c_int, c_str) callconv(.c) noreturn;
            @extern(T, extName(.luaL_typeerror))(L, arg, tname);
        }
    }

    /// `[-0,+0,v]` Checks whether the function argument `arg` is an integer (or
    /// can be converted to an integer) and returns this integer.
    pub inline fn checkInteger(L: *State, arg: i32) Integer {
        return api(.luaL_checkinteger)(L, arg);
    }

    /// `[-0,+0,v]` Checks that argument `arg` is an unsigned integer and returns it.
    pub inline fn checkUnsigned(L: *State, arg: i32) Unsigned {
        return @intCast(checkInteger(L, arg));
    }

    /// `[-0,+1,m]` Creates a new table and registers there the functions in the
    /// list l.
    pub inline fn newLib(L: *State, libs: []const Reg) void {
        L.createTable(0, libs.len);
        L.setFuncs(libs, 0);
    }

    /// `[-nup,+0,m]` Registers all functions in the array `l` (see [`Reg`])
    /// into the table on the top of the stack (below optional upvalues, see
    /// next).
    /// When `nup` is not zero, all functions are created with `nup` upvalues,
    /// initialized with copies of the `nup` values previously pushed on the
    /// stack on top of the library table. These values are popped from the
    /// stack after the registration.
    /// A function with a `null` value represents a placeholder, which is filled
    /// with `false`.
    pub inline fn setFuncs(L: *State, l: []const Reg, nup: i32) void {
        for (l) |e| {
            if (e.func) |func| {
                for (0..nup) |_| L.pushValue(-nup);
                L.pushCClosure(func, nup);
            } else {
                L.pushBoolean(false);
            }
            L.setField(-(nup + 2), e.name);
        }
        L.pop(nup);
    }

    // library opening functions
    //

    /// Opens all standard Lua libraries.
    pub inline fn openLibs(L: *State) void {
        if (comptime !lang.atLeast(.lua55)) return api(.luaL_openlibs)(L);
        const T = *const fn (*State, c_int, c_int) callconv(.c) void;
        @extern(T, extName(.luaL_openselectedlibs))(L, -1, 0);
    }

    /// Opens a standard Lua library.
    /// Call with the library name, e.g. `L.openlib(.base)` or `L.openlib(.string)`.
    pub inline fn openlib(L: *State, comptime lib: LuaLib) void {
        if (comptime !lib.available()) notAvail(@tagName(lib) ++ " library");
        const name = comptime "luaopen_" ++ @tagName(lib);
        const l = @extern(CFn, .{ .name = name });
        L.requireF(@tagName(lib), l, true);
    }
};

/// Zig wrapper around `luaL_Buffer` for building strings piecemeal.
pub const Buffer = struct {
    /// The initial buffer size used by the lauxlib buffer system.
    const bufsize: usize = if (lang.atLeast(.lua54))
        @as(usize, 16) * @sizeOf(*anyopaque) * @sizeOf(Number) // 1024 on 64-bit
    else
        1024; // BUFSIZ

    /// The C type `luaL_Buffer`, version-specific layout.
    const Raw = if (lang.eql(.lua51) or lang.eql(.luajit))
        extern struct {
            p: [*]u8,
            lvl: c_int,
            L: *State,
            buffer: [bufsize]u8,
        }
    else if (lang.between(.lua52, .lua53))
        extern struct {
            b: [*]u8,
            size: usize,
            n: usize,
            L: *State,
            initb: [bufsize]u8,
        }
    else
        extern struct {
            b: [*]u8,
            size: usize,
            n: usize,
            L: *State,
            init: extern union {
                _align: std.c.max_align_t,
                b: [bufsize]u8,
            },
        };

    buf: Raw,

    /// Initialize the buffer. Must be called before any other operation.
    pub inline fn init(self: *Buffer, L: *State) void {
        const T = *const fn (*State, *Raw) callconv(.c) void;
        @extern(T, extName(.luaL_buffinit))(L, &self.buf);
    }

    /// Initialize the buffer with a preallocated size. Returns a slice of
    /// at least `sz` bytes that can be written to directly. Available in Lua 5.2+.
    pub inline fn initSize(self: *Buffer, L: *State, sz: usize) []u8 {
        if (comptime !lang.atLeast(.lua52)) notAvail("initSize");
        const T = *const fn (*State, *Raw, usize) callconv(.c) [*]u8;
        const ptr = @extern(T, extName(.luaL_buffinitsize))(L, &self.buf, sz);
        return ptr[0..sz];
    }

    /// Add a single character to the buffer.
    pub inline fn addChar(self: *Buffer, c: u8) void {
        if (comptime lang.in(.{ .lua51, .luajit })) {
            if (@intFromPtr(self.buf.p) - @intFromPtr(&self.buf.buffer) >= self.buf.buffer.len)
                _ = self.prep();
            self.buf.p[0] = c;
            self.buf.p += 1;
        } else {
            if (self.buf.n >= self.buf.size)
                _ = self.prep();
            self.buf.b[self.buf.n] = c;
            self.buf.n += 1;
        }
    }

    /// Add a null-terminated string to the buffer.
    pub inline fn addString(self: *Buffer, s: c_str) void {
        const T = *const fn (*Raw, c_str) callconv(.c) void;
        @extern(T, extName(.luaL_addstring))(&self.buf, s);
    }

    /// Add a string of known length to the buffer.
    pub inline fn addSlice(self: *Buffer, s: []const u8) void {
        const T = *const fn (*Raw, [*]const u8, usize) callconv(.c) void;
        @extern(T, extName(.luaL_addlstring))(&self.buf, s.ptr, s.len);
    }

    /// Add the value at the top of the stack to the buffer, popping it.
    pub inline fn addValue(self: *Buffer) void {
        const T = *const fn (*Raw) callconv(.c) void;
        @extern(T, extName(.luaL_addvalue))(&self.buf);
    }

    /// Return a writable slice of the buffer's current space. After writing,
    /// call `addSize` with the number of bytes actually used.
    pub inline fn prep(self: *Buffer) []u8 {
        if (comptime lang.eql(.lua51) or lang.eql(.luajit)) {
            const T = *const fn (*Buffer.Raw) callconv(.c) [*]u8;
            const p = @extern(T, extName(.luaL_prepbuffer))(&self.buf);
            return p[0..bufsize];
        }
        return self.prepSize(bufsize);
    }

    pub inline fn prepSize(self: *Buffer, sz: usize) []u8 {
        if (comptime !lang.atLeast(.lua52)) notAvail("prepSize");
        const T = *const fn (*Raw, usize) callconv(.c) [*]u8;
        const ptr = @extern(T, extName(.luaL_prepbuffsize))(&self.buf, sz);
        return ptr[0..sz];
    }

    /// Mark `n` bytes as written after a `prep` call.
    pub inline fn addSize(self: *Buffer, n: usize) void {
        if (comptime lang.in(.{ .lua51, .luajit })) {
            self.buf.p += n;
        } else {
            self.buf.n += n;
        }
    }

    /// Push the buffer contents onto the Lua stack as a string.
    pub inline fn pushResult(self: *Buffer) void {
        const T = *const fn (*Raw) callconv(.c) void;
        @extern(T, extName(.luaL_pushresult))(&self.buf);
    }

    /// Push the first `sz` bytes of the buffer onto the Lua stack as a string.
    /// Available in Lua 5.2+.
    pub inline fn pushResultSize(self: *Buffer, sz: usize) void {
        if (comptime !lang.atLeast(.lua52)) notAvail("pushResultSize");
        const T = *const fn (*Raw, usize) callconv(.c) void;
        @extern(T, extName(.luaL_pushresultsize))(&self.buf, sz);
    }

    /// Returns the current length of the buffer. Available in Lua 5.4+.
    pub inline fn len(self: *const Buffer) usize {
        if (comptime !lang.atLeast(.lua54)) notAvail("len");
        return self.buf.n;
    }

    /// Subtract `n` bytes from the buffer length. Available in Lua 5.4+.
    pub inline fn sub(self: *Buffer, n: usize) void {
        if (comptime !lang.atLeast(.lua54)) notAvail("sub");
        self.buf.n -= n;
    }

    /// Returns a slice of the current buffer contents. Available in Lua 5.4+.
    pub inline fn addr(self: *const Buffer) []const u8 {
        if (comptime !lang.atLeast(.lua54)) notAvail("addr");
        return self.buf.b[0..self.buf.n];
    }

    /// Add a copy of `s` with occurrences of `p` replaced by `r`.
    /// Available in Lua 5.4+.
    pub inline fn addGSub(self: *Buffer, s: c_str, p: c_str, r: c_str) void {
        if (comptime !lang.atLeast(.lua54)) notAvail("addGSub");
        const T = *const fn (*Raw, c_str, c_str, c_str) callconv(.c) void;
        @extern(T, extName(.luaL_addgsub))(&self.buf, s, p, r);
    }
};

/// Lua Types
/// Must be a signed integer because LuaType.none is -1
pub const LuaType = enum(c_int) {
    none = -1,
    nil,
    boolean,
    light_userdata,
    number,
    string,
    table,
    function,
    userdata,
    thread,
};

/// Status codes for a Lua thread.
pub const Status = if (lang.between(.lua52, .lua53))
    enum(c_int) { ok, yield, errrun, errsyntax, errmem, errgcmm, errerr, errfile }
else
    enum(c_int) { ok, yield, errrun, errsyntax, errmem, errerr, errfile };

/// The superset of all errors returned from zlua
pub const Error = error{
    /// A runtime error
    LuaRuntime,
    /// A syntax error during precompilation
    LuaSyntax,
    /// A memory allocation error
    OutOfMemory,
    /// An error while running the message handler
    LuaMsgHandler,
    /// A file-releated error
    LuaFile,
} || if (lang.between(.lua52, .lua53)) error{
    /// A memory error during garbage collection
    LuaGCMetaMethod,
} else error{};

/// Arguments for [`call`] and [`pcall`].
pub const CallArgs = struct {
    /// Number of arguments to pass to the called function.
    args: i32 = 0,
    /// Number of results to collect. Ignored if `mult_ret` is set.
    rets: i32 = 0,
    /// If true, return all results (equivalent to `rets = -1`).
    mult_ret: bool = false,
    /// Stack index of the error handler function (0 = no handler).
    msg_idx: i32 = 0,
    /// Continuation context for [`callk`]/[`pcallk`].
    ctx: KContext = 0,
    /// Continuation function for [`callk`]/[`pcallk`].
    k: ?KFn = null,
};

/// Continuation context type for `lua_callk` and `lua_pcallk`.
pub const KContext = if (lang.atLeast(.lua53)) isize else c_int;

/// The reference ID type used by [`ref`] and [`unref`].
pub const RefID = enum(c_int) { no_ref = -2, ref_nil = -1, _ };

/// Arguments to `lua.newlib` to create a Lua table with functions.
pub const Reg = struct { name: c_str, func: ?CFn };

/// Arithmetic operators for [`arith`].
pub const ArithOperator = enum(c_int) {
    add,
    sub,
    mul,
    mod,
    pow,
    div,
    /// Integer division (Lua 5.3+)
    int_div,
    /// Bitwise AND (Lua 5.3+)
    band,
    /// Bitwise OR (Lua 5.3+)
    bor,
    /// Bitwise XOR (Lua 5.3+)
    bxor,
    /// Left shift (Lua 5.3+)
    shl,
    /// Right shift (Lua 5.3+)
    shr,
    /// Unary minus (Lua 5.3+)
    negate,
    /// Bitwise NOT (Lua 5.3+)
    bnot,
};

/// Comparison operators for [`compare`].
pub const CompareOperator = enum(c_int) { eq, lt, le };

/// Standard Lua libraries that can be loaded with [`openlib`].
pub const LuaLib = enum {
    base,
    math,
    string,
    table,
    io,
    os,
    debug,
    package,
    coroutine,
    utf8,
    bit32,

    /// Returns `true` if this library is available for the current Lua version.
    pub fn available(self: @This()) bool {
        return switch (self) {
            .base, .math, .string, .table, .io, .os, .debug, .package => true,
            .coroutine => !lang.eql(.lua51) and !lang.eql(.luajit),
            .utf8 => lang.atLeast(.lua53) or lang.eql(.luajit) or lang.eql(.luau),
            .bit32 => lang.eql(.lua52) or lang.eql(.luajit),
        };
    }
};

/// Debug information about a function or activation record, filled by
/// [`getInfo`] or [`getStack`].
pub const DebugInfo = struct {
    event: Event = .call,
    name: ?c_str = null,
    name_what: NameType = .other,
    what: FnType = .Lua,
    source: ?c_str = null,
    current_line: ?i32 = null,
    first_line_defined: i32 = 0,
    last_line_defined: i32 = 0,
    num_upvalues: i32 = 0,
    num_params: i32 = 0,
    is_tail_call: bool = false,
    /// Index of the first value transferred (Lua 5.4+).
    first_transfer: i32 = 0,
    short_src: [id_size]u8 = @splat(0),
    /// Active function (private, used by `getInfo`).
    _ci: if (lang.eql(.lua51)) c_int else c_voidp =
        if (lang.eql(.lua51)) 0 else null,

    const id_size = 60;

    /// Version-specific raw C struct matching `lua_Debug`.
    const Raw = if (lang.eql(.lua51))
        extern struct {
            event: c_int,
            name: ?c_str,
            namewhat: ?c_str,
            what: ?c_str,
            source: ?c_str,
            currentline: c_int,
            nups: c_int,
            linedefined: c_int,
            lastlinedefined: c_int,
            short_src: [id_size]u8,
            _ci: c_int,
        }
    else if (lang.between(.lua52, .lua53))
        extern struct {
            event: c_int,
            name: ?c_str,
            namewhat: ?c_str,
            what: ?c_str,
            source: ?c_str,
            currentline: c_int,
            linedefined: c_int,
            lastlinedefined: c_int,
            nups: u8,
            nparams: u8,
            isvararg: u8,
            istailcall: u8,
            short_src: [id_size]u8,
            _ci: c_voidp,
        }
    else if (lang.eql(.lua54))
        extern struct {
            event: c_int,
            name: ?c_str,
            namewhat: ?c_str,
            what: ?c_str,
            source: ?c_str,
            srclen: usize,
            currentline: c_int,
            linedefined: c_int,
            lastlinedefined: c_int,
            nups: u8,
            nparams: u8,
            isvararg: u8,
            istailcall: u8,
            ftransfer: u16,
            ntransfer: u16,
            short_src: [id_size]u8,
            _ci: c_voidp,
        }
    else
        extern struct { // Lua 5.5+
            event: c_int,
            name: ?c_str,
            namewhat: ?c_str,
            what: ?c_str,
            source: ?c_str,
            srclen: usize,
            currentline: c_int,
            linedefined: c_int,
            lastlinedefined: c_int,
            nups: u8,
            nparams: u8,
            isvararg: u8,
            extraargs: u8,
            istailcall: u8,
            ftransfer: c_int,
            ntransfer: c_int,
            short_src: [id_size]u8,
            _ci: c_voidp,
        };

    fn fromRaw(what: InfoWhat, raw: *const Raw) DebugInfo {
        const name_what: NameType = if (what.n) blk: {
            const nw_str = if (raw.namewhat) |nw| std.mem.span(nw) else "";
            if (nw_str.len == 0) break :blk .other;
            break :blk std.meta.stringToEnum(NameType, nw_str).?;
        } else .other;
        const fwhat: FnType = if (what.S) blk: {
            const w_str = if (raw.what) |w| std.mem.span(w) else "C";
            break :blk std.meta.stringToEnum(FnType, w_str).?;
        } else .Lua;
        return .{
            .event = @enumFromInt(raw.event),
            .name = if (what.n) raw.name else null,
            .name_what = name_what,
            .what = fwhat,
            .source = if (what.S) raw.source else null,
            .current_line = if (what.l and raw.currentline >= 0) raw.currentline else null,
            .first_line_defined = if (what.S) raw.linedefined else 0,
            .last_line_defined = if (what.S) raw.lastlinedefined else 0,
            .num_upvalues = if (what.u) @intCast(raw.nups) else 0,
            .num_params = if (comptime lang.atLeast(.lua52))
                if (what.u) @intCast(raw.nparams) else 0
            else
                0,
            .is_tail_call = if (comptime lang.atLeast(.lua52))
                if (what.t) raw.istailcall != 0 else false
            else
                false,
            .first_transfer = if ((comptime lang.atLeast(.lua54)) and what.r)
                @intCast(raw.ftransfer)
            else
                1,
            .short_src = if (what.S) raw.short_src else @splat(0),
            ._ci = raw._ci,
        };
    }
};

/// Hook event codes passed to a hook function.
pub const Event = enum(c_int) { call, ret, line, count, tail_call, _ };

/// Mask of hook events for [`setHook`].
pub const HookMask = packed struct {
    call: bool = false,
    ret: bool = false,
    line: bool = false,
    count: bool = false,
    tail_call: bool = false,

    pub fn toInt(self: @This()) c_int {
        return (@as(c_int, @intFromBool(self.call)) << 0) |
            (@as(c_int, @intFromBool(self.ret)) << 1) |
            (@as(c_int, @intFromBool(self.line)) << 2) |
            (@as(c_int, @intFromBool(self.count)) << 3) |
            (@as(c_int, @intFromBool(self.tail_call)) << 4);
    }
};

/// Options for [`getInfo`], corresponding to the `what` string in
/// `lua_getinfo`. Set the fields you want to request.
pub const InfoWhat = packed struct {
    /// Treat as function (not activation record).
    @">": bool = false,
    /// Push the function onto the stack and fill `func`.
    f: bool = false,
    /// Fill `current_line`.
    l: bool = false,
    /// Fill `name` and `name_what`.
    n: bool = false,
    /// Fill `ftransfer` and `ntransfer` (Lua 5.4+).
    r: bool = false,
    /// Fill `source`, `short_src`, `linedefined`, `lastlinedefined`, `what`.
    S: bool = false,
    /// Fill `is_tail_call`.
    t: bool = false,
    /// Fill `num_upvalues`, `num_params`.
    u: bool = false,
    /// Fill `activelines` (Lua 5.4+).
    L: bool = false,

    fn toWhat(self: @This()) [10:0]u8 {
        var str: [10:0]u8 = @splat(0);
        var index: u8 = 0;
        inline for (std.meta.fields(@This())) |f| {
            if (@field(self, f.name)) {
                str[index] = f.name[0];
                index += 1;
            }
        }
        while (index < str.len) : (index += 1) str[index] = 0;
        return str;
    }
};

const gcOp = if (lang.eql(.lua51))
    enum(c_int) { stop, restart, collect, count, countb, step, setpause, setstepmul, _ }
else if (lang.between(.lua52, .lua53))
    enum(c_int) { stop, restart, collect, count, countb, step, setpause, setstepmul, setmajorinc, isrunning, gen, inc, _ }
else if (lang.eql(.lua54))
    enum(c_int) { stop, restart, collect, count, countb, step, setpause, setstepmul, isrunning = 9, gen = 10, inc = 11, _ }
else // 5.5
    enum(c_int) { stop, restart, collect, count, countb, step, isrunning, gen, inc, param, _ };

inline fn notAvail(comptime name: []const u8) noreturn {
    @compileError(name ++ " is not available in Lua " ++ @tagName(lang.version));
}

inline fn api(comptime name: anytype) ApiType(name) {
    return @extern(ApiType(name), extName(name));
}

inline fn extName(comptime name: anytype) std.lang.ExternOptions {
    return .{ .name = @tagName(name) };
}

const specialApiTypes = std.StaticStringMap(type).initComptime(&([_]struct { []const u8, type }{
    .{ "lua_error", @TypeOf(State.raiseError) },
    .{ "luaL_error", @TypeOf(State.raiseErrorStr) },
    .{ "lua_close", @TypeOf(State.deinit) },
    .{ "lua_type", @TypeOf(State.typeOf) },
    .{ "luaL_checkstack", @TypeOf(State.checkStackRaiseErr) },
    .{ "luaL_len", @TypeOf(State.lenRaiseErr) },
    .{ "luaL_setmetatable", @TypeOf(State.setMetatableRegistry) },
    .{ "lua_newstate", fn (Alloc, c_voidp) ?*State },
    .{ "lua_getallocf", fn (*State, c_voidp) ?Alloc },
    .{ "lua_tolstring", fn (*State, i32, *usize) ?c_str },
    .{ "luaL_checklstring", fn (*State, i32, ?*usize) ?c_str },
    .{ "luaL_optlstring", fn (*State, i32, ?c_str, ?*usize) c_str },
    .{ "lua_call", fn (*State, i32, i32) void },
    .{ "lua_callk", fn (*State, i32, i32, KContext, ?KFn) void },
    .{ "lua_pcall", fn (*State, i32, i32, i32) c_int },
    .{ "lua_pcallk", fn (*State, i32, i32, i32, KContext, ?KFn) c_int },
    .{ "lua_yield", fn (*State, i32) c_int },
    .{ "luaL_loadbufferx", fn (*State, [*]const u8, usize, c_str, c_str) c_int },
    .{ "luaL_loadfilex", fn (*State, c_str, ?c_str) c_int },
    .{ "lua_tonumberx", fn (*State, i32, *c_int) Number },
    .{ "lua_tointegerx", fn (*State, i32, *c_int) Integer },
    .{ "lua_tounsignedx", fn (*State, i32, *c_int) Unsigned }, // only in Lua 5.2
    .{ "lua_newuserdata", @TypeOf(State.newUserdataRaw) },
    .{ "lua_newuserdatauv", @TypeOf(State.newUserdataUVRaw) },
    .{ "lua_touserdata", fn (*State, i32) c_voidp },
    .{ "lua_gc", fn (*State, gcOp, anytype) c_int },
    .{ "lua_getstack", fn (*State, c_int, *DebugInfo.Raw) c_int },
    .{ "lua_getctx", fn (*State, *c_int) KContext }, // Only in Lua 5.2
} ++ .{ // Lua 5.1 special APIs
    .{ "luaL_loadbuffer", fn (*State, [*]const u8, usize, c_str) c_int },
    .{ "lua_tonumber", fn (*State, i32) Number },
    .{ "lua_tointeger", fn (*State, i32) Integer },
    .{ "lua_objlen", fn (*State, i32) usize },
    .{ "lua_setfenv", fn (*State, i32) c_int },
    .{ "lua_getfenv", fn (*State, i32) void },
}));

const apiMap = blk: {
    const decls = @typeInfo(State).@"opaque".decls;
    var kvs: [decls.len]struct { []const u8, type } = undefined;
    @setEvalBranchQuota(10_000);
    for (decls, 0..) |d, i| {
        var buf: [d.name.len]u8 = undefined;
        _ = std.ascii.lowerString(&buf, d.name);
        const lower = buf;
        kvs[i] = .{ &lower, DeclType(@TypeOf(@field(State, d.name))) };
    }
    const result = kvs;
    break :blk std.StaticStringMap(type).initComptime(&result);
};

inline fn ApiType(comptime name: anytype) type {
    const tag = @tagName(name);
    @setEvalBranchQuota(10_000);
    if (specialApiTypes.get(tag)) |t| return DeclType(t);
    const cutPrefix = std.mem.cutPrefix;
    const fname = cutPrefix(u8, tag, "lua_") orelse
        (cutPrefix(u8, tag, "luaL_") orelse tag);
    return if (apiMap.get(fname)) |t|
        t
    else
        @compileError("unsupported API function");
}

inline fn DeclType(comptime dt: type) type {
    const ft = @typeInfo(dt).@"fn";
    const params_len = ft.params.len;
    const va = params_len > 0 and ft.params[params_len - 1].type == null;
    const cf = @Fn(
        &paramTypes(if (va) ft.params[0 .. params_len - 1] else ft.params),
        &@splat(.{}),
        TypeMap(ft.return_type orelse void),
        .{ .@"callconv" = .c, .varargs = va },
    );
    return @Pointer(.one, .{ .@"const" = true }, cf, null);
}

inline fn paramTypes(comptime params: []const std.lang.Type.Fn.Param) [params.len]type {
    var types: [params.len]type = undefined;
    for (params, &types) |param, *t|
        t.* = TypeMap(param.type orelse @compileError("unsupported type"));
    return types;
}

inline fn TypeMap(comptime t: type) type {
    return switch (t) {
        bool => c_int,
        i32 => c_int,
        []const u8 => c_str,
        HookMask => c_int,
        InfoWhat => c_str,
        Error!void => c_int,
        *DebugInfo => *DebugInfo.Raw,
        else => t,
    };
}

inline fn checkErr(err: c_int) Error!void {
    if (err == 0) return;
    if (comptime lang.between(.lua52, .lua53)) {
        return switch (@as(Status, @enumFromInt(err))) {
            .ok => return,
            .yield => return,
            .errrun => error.LuaRuntime,
            .errsyntax => error.LuaSyntax,
            .errmem => error.OutOfMemory,
            .errgcmm => error.LuaGCMetaMethod,
            .errerr => error.LuaMsgHandler,
            .errfile => error.LuaFile,
        };
    } else {
        return switch (@as(Status, @enumFromInt(err))) {
            .ok => return,
            .yield => return,
            .errrun => error.LuaRuntime,
            .errsyntax => error.LuaSyntax,
            .errmem => error.OutOfMemory,
            .errerr => error.LuaMsgHandler,
            .errfile => error.LuaFile,
        };
    }
}
