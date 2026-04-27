// Modified from https://github.com/natecraddock/ziglua/blob/main/src/tests.zig
// Copyright (c) 2022-2026 Nathan Craddock

const std = @import("std");
const testing = std.testing;
const ArrayList = std.ArrayListUnmanaged; // delete this once 0.14 support is no longer necessary

const lua = @import("lua.zig");

const Buffer = lua.Buffer;
const DebugInfo = lua.DebugInfo;
const State = lua.State;

const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
const expectError = testing.expectError;

fn expectStringContains(actual: []const u8, expected_contains: []const u8) !void {
    if (std.mem.indexOf(u8, actual, expected_contains) == null) return;
    return error.LuaTestExpectedStringContains;
}

test "initialization" {
    // initialize the Zig wrapper
    const L: *State = try .init(testing.allocator);
    try expectEqual(lua.Status.ok, L.status());
    L.deinit();

    // attempt to initialize the Zig wrapper with no memory
    try expectError(error.OutOfMemory, State.init(testing.failing_allocator));
}

test "Zig allocator access" {
    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    const inner = struct {
        fn inner(l: *State) callconv(.c) i32 {
            const allocator = l.allocator();
            const num = l.checkInteger(1);

            // Use the allocator
            const nums = allocator.alloc(i32, @intCast(num)) catch |e|
                l.raiseErrorStr("Allocation failed: {any}", .{&e});
            defer allocator.free(nums);

            // Do something pointless to use the slice
            var sum: i32 = 0;
            for (nums, 0..) |*n, i| n.* = @intCast(i);
            for (nums) |n| sum += n;

            l.pushInteger(sum);
            return 1;
        }
    }.inner;

    L.pushCFunction(inner);
    L.pushInteger(10);
    try L.pcall(.{ .args = 1, .rets = 1 });

    try expectEqual(45, L.toInteger(-1).?);
}

test "standard library loading" {
    // open all standard libraries
    {
        const L: *State = try .init(testing.allocator);
        defer L.deinit();
        L.openLibs();
    }

    // open all standard libraries with individual functions
    // these functions are only useful if you want to load the standard
    // packages into a non-standard table
    {
        const L: *State = try .init(testing.allocator);
        defer L.deinit();

        L.openlib(.base);
        L.openlib(.string);
        L.openlib(.table);
        L.openlib(.math);
        L.openlib(.os);
        L.openlib(.debug);

        if (comptime lua.lang.in(.{ .lua52, .luajit })) L.openlib(.bit32);

        if (comptime !lua.lang.eql(.luau)) {
            L.openlib(.package);
            L.openlib(.io);
        }
        if (comptime !lua.lang.eql(.lua51) and !lua.lang.eql(.luajit)) L.openlib(.coroutine);
        if (comptime !lua.lang.eql(.lua51) and !lua.lang.eql(.lua52) and !lua.lang.eql(.luajit)) L.openlib(.utf8);
    }
}

test "number conversion success and failure" {
    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    _ = L.pushString("1234.5678");
    try expectEqual(1234.5678, L.toNumber(-1).?);

    _ = L.pushString("1234");
    try expectEqual(1234, L.toInteger(-1).?);

    L.pushNil();
    try expectEqual(null, L.toNumber(-1));
    try expectEqual(null, L.toInteger(-1));

    _ = L.pushString("fail");
    try expectEqual(null, L.toNumber(-1));
    try expectEqual(null, L.toInteger(-1));
}

test "arithmetic (lua_arith)" {
    if (comptime !lua.lang.atLeast(.lua53)) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    L.pushNumber(10);
    L.pushNumber(42);

    L.arith(.add);
    try expectEqual(52, L.toNumber(1).?);

    L.pushNumber(12);
    L.arith(.sub);
    try expectEqual(40, L.toNumber(1).?);

    L.pushNumber(2);
    L.arith(.mul);
    try expectEqual(80, L.toNumber(1).?);

    L.pushNumber(8);
    L.arith(.div);
    try expectEqual(10, L.toNumber(1).?);

    L.pushNumber(3);
    L.arith(.mod);
    try expectEqual(1, L.toNumber(1).?);

    L.arith(.negate);
    try expectEqual(-1, L.toNumber(1).?);

    if (comptime lua.lang.eql(.lua52)) return;

    L.arith(.negate);
    L.pushNumber(2);
    L.arith(.shl);
    try expectEqual(4, L.toInteger(1).?);

    L.pushNumber(1);
    L.arith(.shr);
    try expectEqual(2, L.toInteger(1).?);

    L.pushNumber(4);
    L.arith(.bor);
    try expectEqual(6, L.toInteger(1).?);

    L.pushNumber(1);
    L.arith(.band);
    try expectEqual(0, L.toInteger(1).?);

    L.pushNumber(1);
    L.arith(.bxor);
    try expectEqual(1, L.toInteger(1).?);

    L.arith(.bnot); // 0xFFFFFFFFFFFFFFFE which is -2
    try expectEqual(-2, L.toInteger(1).?);

    L.pushNumber(3);
    L.arith(.pow);
    try expectEqual(-8, L.toInteger(1).?);

    L.pushNumber(11);
    L.pushNumber(2);
    L.arith(.int_div);
    try expectEqual(5, L.toNumber(-1).?);
}

test "compare" {
    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    L.pushNumber(1);
    L.pushNumber(2);

    if (comptime lua.lang.between(.lua52, .lua54)) {
        try expect(!L.compare(-2, -1, .eq));
        try expect(!L.compare(-1, -2, .le));
        try expect(!L.compare(-1, -2, .lt));
        try expect(L.compare(-2, -1, .le));
        try expect(L.compare(-2, -1, .lt));

        try expect(!L.rawEqual(-1, -2));
        L.pushNumber(2);
        try expect(L.rawEqual(-1, -2));
    } else {
        try testing.expect(!L.equal(1, 2));
        try testing.expect(L.lessThan(1, 2));

        L.pushInteger(2);
        try testing.expect(L.equal(2, 3));
    }
}

fn add(l: *State) callconv(.c) c_int {
    const a = l.checkInteger(1);
    const b = l.checkInteger(2);
    l.pushInteger(a + b);
    return 1;
}

test "type of and getting values" {
    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    L.pushNil();
    try expect(L.isNil(1));
    try expect(L.isNoneOrNil(1));
    try expect(L.isNoneOrNil(2));
    try expect(L.isNone(2));
    try expectEqual(.nil, L.typeOf(1));

    L.pushBoolean(true);
    try expectEqual(.boolean, L.typeOf(-1));
    try expect(L.isBoolean(-1));

    L.newTable();
    try expectEqual(.table, L.typeOf(-1));
    try expect(L.isTable(-1));

    L.pushInteger(1);
    try expectEqual(.number, L.typeOf(-1));
    try expect(L.isNumber(-1));
    try expectEqual(1, L.toInteger(-1).?);
    try expectEqualStrings("number", L.typeNameIndex(-1));

    var value: i32 = 0;
    L.pushLightUserdata(&value);
    try expectEqual(.light_userdata, L.typeOf(-1));
    try expect(L.isLightUserdata(-1));
    try expect(L.isUserdata(-1));

    L.pushNumber(0.1);
    try expectEqual(.number, L.typeOf(-1));
    try expect(L.isNumber(-1));
    try expectEqual(0.1, L.toNumber(-1).?);

    _ = L.pushThread();
    try expectEqual(.thread, L.typeOf(-1));
    try expect(L.isThread(-1));
    try expectEqual(L, L.toThread(-1).?);

    try expectEqualStrings(
        "all your codebase are belong to us",
        std.mem.span(L.pushString("all your codebase are belong to us")),
    );
    try expectEqual(.string, L.typeOf(-1));
    try expect(L.isString(-1));

    L.pushCFunction(add);
    try expectEqual(.function, L.typeOf(-1));
    try expect(L.isCFunction(-1));
    try expect(L.isFunction(-1));
    try expectEqual(add, L.toCFunction(-1).?);

    try expectEqualStrings("hello world", std.mem.span(L.pushString("hello world")));
    try expectEqual(.string, L.typeOf(-1));
    try expect(L.isString(-1));

    _ = L.pushFString("%s %s %d", .{ "hello", "world", @as(i32, 10) });
    try expectEqual(.string, L.typeOf(-1));
    try expect(L.isString(-1));
    try expectEqualStrings("hello world 10", L.toSlice(-1).?);

    L.pushValue(2);
    try expectEqual(.boolean, L.typeOf(-1));
    try expect(L.isBoolean(-1));
}

test "typenames" {
    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    try expectEqualStrings("no value", L.typeName(.none));
    try expectEqualStrings("nil", L.typeName(.nil));
    try expectEqualStrings("boolean", L.typeName(.boolean));
    try expectEqualStrings("userdata", L.typeName(.light_userdata));
    try expectEqualStrings("number", L.typeName(.number));
    try expectEqualStrings("string", L.typeName(.string));
    try expectEqualStrings("table", L.typeName(.table));
    try expectEqualStrings("function", L.typeName(.function));
    try expectEqualStrings("userdata", L.typeName(.userdata));
    try expectEqualStrings("thread", L.typeName(.thread));

    if (comptime lua.lang.eql(.luau)) {
        try expectEqualStrings("vector", L.typeName(.vector));
    }
}

test "unsigned" {
    if (comptime !lua.lang.between(.lua52, .lua54)) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    L.pushUnsigned(123456);
    try expectEqual(123456, L.toUnsigned(-1));

    _ = L.pushString("hello");
    try expectEqual(null, L.toUnsigned(-1));
}

test "executing string contents" {
    const L: *State = try .init(testing.allocator);
    defer L.deinit();
    L.openLibs();

    try L.loadString("f = function(x) return x + 10 end");
    try L.pcall(.{});
    try L.loadString("a = f(2)");
    try L.pcall(.{});

    try expectEqual(.number, L.getGlobal("a"));
    try expectEqual(12, L.toInteger(1).?);

    try expectError(if (comptime lua.lang.eql(.luau)) error.LuaError else error.LuaSyntax, L.loadString("bad syntax"));
    try L.loadString("a = g()");
    try expectError(error.LuaRuntime, L.pcall(.{}));
}

test "filling and checking the stack" {
    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    try expectEqual(0, L.getTop());

    // We want to push 30 values onto the stack
    // this should work without fail
    L.checkStackRaiseErr(30, null);

    var count: i32 = 0;
    while (count < 30) : (count += 1) {
        L.pushNil();
    }

    try expectEqual(30, L.getTop());

    // this should fail (beyond max stack size)
    try expectEqual(false, L.checkStack(1_000_000));

    // this is small enough it won't fail (would raise an error if it did)
    L.checkStackRaiseErr(40, null);
    while (count < 40) : (count += 1) {
        L.pushNil();
    }

    try expectEqual(40, L.getTop());
}

test "stack manipulation" {
    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    // TODO: combine these more
    if (comptime lua.lang.atLeast(.lua53)) {
        var num: i32 = 1;
        while (num <= 10) : (num += 1) {
            L.pushInteger(num);
        }
        try expectEqual(10, L.getTop());

        L.setTop(12);
        try expectEqual(12, L.getTop());
        try expect(L.isNil(-1));

        // rotate the two nils to the bottom of the stack
        L.rotate(1, 2);
        try expect(L.isNil(1));
        try expect(L.isNil(2));

        L.remove(2);
        try expect(L.isNil(1));
        try expect(L.isInteger(2));

        L.insert(1);
        try expect(L.isInteger(1));
        try expect(L.isNil(2));

        L.replace(2);
        try expect(L.isInteger(2));
        try expectEqual(10, L.getTop());

        L.copy(1, 2);
        try expectEqual(10, L.toInteger(1).?);
        try expectEqual(10, L.toInteger(2).?);
        try expectEqual(1, L.toInteger(3).?);
        try expectEqual(8, L.toInteger(-1).?);

        L.setTop(0);
        try expectEqual(0, L.getTop());
    } else {
        var num: i32 = 1;
        while (num <= 10) : (num += 1) {
            L.pushInteger(num);
        }
        try expectEqual(10, L.getTop());

        L.setTop(12);
        try expectEqual(12, L.getTop());
        try expect(L.isNil(-1));

        L.remove(1);
        try expect(L.isNil(-1));

        L.insert(1);
        try expect(L.isNil(1));

        if (comptime lua.lang.eql(.lua52)) {
            L.copy(1, 2);
            try expectEqual(3, L.toInteger(3).?);
            try expectEqual(10, L.toInteger(-2).?);
        }

        L.setTop(0);
        try expectEqual(0, L.getTop());
    }
}

test "calling a function" {
    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    L.register("zigadd", add);

    try expectEqual(.function, L.getGlobal("zigadd"));
    L.pushInteger(10);
    L.pushInteger(32);

    // pcall is preferred, but we might as well test call when we know it is safe
    L.call(.{ .args = 2, .rets = 1 });
    try expectEqual(42, L.toInteger(1).?);
}

test "calling a function with cpCall" {
    if (comptime !lua.lang.eql(.lua51)) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    var value: i32 = 1234;

    const testFn = struct {
        fn inner(l: *State) callconv(.c) i32 {
            const passedValue = l.toUserdata(i32, 1) orelse
                l.argError(1, "Expected a userdata pointer to an i32");
            if (passedValue.* != 1234) unreachable;
            return 0;
        }
    }.inner;

    // cpCall doesn't return values on the stack, so the test just makes
    // sure things work!
    try L.cpCall(testFn, &value);
}

test "version" {
    if (comptime lua.lang.in(.{ .lua51, .luau, .luajit })) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    if (lua.lang.atLeast(.lua52))
        try expectEqual(lua.lang.num(), L.version());

    L.checkVersion();
}

test "string buffers" {
    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    var buffer: Buffer = undefined;
    buffer.init(L);

    buffer.addChar('z');
    buffer.addString("igl");

    var str = buffer.prep();
    str[0] = 'u';
    str[1] = 'a';
    buffer.addSize(2);

    buffer.addSlice(" api ");
    L.pushNumber(5.1);
    buffer.addValue();
    buffer.pushResult();
    try expectEqualStrings("ziglua api 5.1", L.toSlice(-1).?);

    // now test a small buffer
    buffer.init(L);
    var b = buffer.prep();
    b[0] = 'a';
    b[1] = 'b';
    b[2] = 'c';
    buffer.addSize(3);

    b = buffer.prep();
    @memcpy(b[0..23], "defghijklmnopqrstuvwxyz");
    buffer.addSize(23);
    buffer.pushResult();
    try expectEqualStrings("abcdefghijklmnopqrstuvwxyz", L.toSlice(-1).?);
    L.pop(1);

    if (comptime lua.lang.in(.{ .lua51, .luajit })) return;

    buffer.init(L);
    b = buffer.prep();
    @memcpy(b[0..3], "abc");
    buffer.pushResultSize(3);
    try expectEqualStrings("abc", L.toSlice(-1).?);
    L.pop(1);

    if (comptime lua.lang.eql(.luau)) return;

    // TODO: maybe implement this for all langs?
    b = buffer.initSize(L, 20);
    @memcpy(b[0..20], "a" ** 20);
    buffer.pushResultSize(20);

    if (comptime !lua.lang.eql(.lua54)) return;
    try expectEqual(20, buffer.len());
    buffer.sub(10);
    try expectEqual(10, buffer.len());
    try expectEqualStrings("a" ** 10, buffer.addr());

    buffer.addGSub(" append", "append", "appended");
    try expectEqualStrings("a" ** 10 ++ " appended", buffer.addr());
}

test "global table" {
    if (comptime lua.lang.in(.{ .lua51, .luajit, .luau })) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    // open some libs so we can inspect them
    L.openlib(.base);
    L.openlib(.math);
    L.pushGlobalTable();

    // find the print function
    L.pushStringBlind("print");
    try expectEqual(.function, L.getTable(-2));

    // index the global table in the global table
    try expectEqual(.table, L.getField(-2, "_G"));

    // find pi in the math table
    try expectEqual(.table, L.getField(-1, "math"));
    try expectEqual(.number, L.getField(-1, "pi"));

    // but the string table should be nil
    L.pop(2);
    try expectEqual(.nil, L.getField(-1, "string"));
}

const sub = struct {
    fn subInner(l: *State) callconv(.c) i32 {
        const a = l.checkInteger(1);
        const b = l.checkInteger(2);
        l.pushInteger(a - b);
        return 1;
    }
}.subInner;

test "function registration" {
    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    if (comptime lua.lang.in(.{ .lua51, .luajit, .luau })) {
        // register all functions as part of a table
        const funcs = [_]lua.Reg{
            .{ .name = "add", .func = add },
        };
        L.newTable();
        L.setFuncs(&funcs, 0);

        _ = L.getField(-1, "add");
        L.pushInteger(1);
        L.pushInteger(2);
        try L.pcall(.{ .args = 2, .rets = 1 });
        try expectEqual(3, L.toInteger(-1));
        L.setTop(0);

        // register functions as globals in a library table
        // TODO: extract as a utility function
        L.newTable();
        L.setFuncs(&funcs, 0);
        L.setGlobal("testlib");

        // testlib.add(1, 2)
        try expectEqual(.table, L.getGlobal("testlib"));
        _ = L.getField(-1, "add");
        L.pushInteger(1);
        L.pushInteger(2);
        try L.pcall(.{ .args = 2, .rets = 1 });
        try expectEqual(3, L.toInteger(-1));

        return;
    }

    // register all functions as part of a table
    const funcs = [_]lua.Reg{
        .{ .name = "add", .func = add },
        .{ .name = "sub", .func = sub },
        .{ .name = "placeholder", .func = null },
    };
    L.newTable();
    L.setFuncs(&funcs, 0);

    _ = L.getField(-1, "placeholder");
    try expectEqual(.boolean, L.typeOf(-1));
    L.pop(1);
    _ = L.getField(-1, "add");
    try expectEqual(.function, L.typeOf(-1));
    L.pop(1);
    _ = L.getField(-1, "sub");
    try expectEqual(.function, L.typeOf(-1));

    // also try calling the sub function sub(42, 40)
    L.pushInteger(42);
    L.pushInteger(40);
    try L.pcall(.{ .args = 2, .rets = 1 });
    try expectEqual(2, L.toInteger(-1).?);

    // now test the newlib variation to build a library from functions
    // indirectly tests newLibTable
    L.newLib(&funcs);
    // add functions to the global table under "funcs"
    L.setGlobal("funcs");

    try L.doString("funcs.add(10, 20)");
    try L.doString("funcs.sub('10', 20)");
    try expectError(error.LuaRuntime, L.doString("funcs.placeholder()"));
}

test "panic fn" {
    if (comptime lua.lang.eql(.luau)) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    // just test setting up the panic function
    // it uses longjmp so cannot return here to test
    const panicFn = struct {
        fn inner(l: *State) callconv(.c) i32 {
            _ = l;
            return 0;
        }
    }.inner;
    try expectEqual(null, L.atPanic(panicFn));
}

test "warn fn" {
    if (comptime !lua.lang.eql(.lua54)) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    L.warning("this message is going to the void", false);

    const warnFn = struct {
        fn inner(ud: ?*anyopaque, msg: [*:0]const u8, to_cont: c_int) callconv(.c) void {
            _ = ud;
            _ = to_cont;
            if (!std.mem.eql(u8, std.mem.span(msg), "this will be caught by the warnFn")) std.debug.panic("test failed", .{});
        }
    }.inner;

    L.setWarnF(warnFn, null);
    L.warning("this will be caught by the warnFn", false);
}

test "concat" {
    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    _ = L.pushString("hello ");
    L.pushNumber(10);
    _ = L.pushString(" wow!");
    L.concat(3);

    if (comptime lua.lang.atLeast(.lua53)) {
        try expectEqualStrings("hello 10.0 wow!", L.toSlice(-1).?);
    } else {
        try expectEqualStrings("hello 10 wow!", L.toSlice(-1).?);
    }
}

test "garbage collector" {
    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    // because the garbage collector is an opaque, unmanaged
    // thing, it is hard to test, so just run each function
    L.gcStop();
    L.gcCollect();
    L.gcRestart();
    _ = L.gcCount();
    _ = L.gcCountB();
    L.gcStep(10);

    if (comptime !lua.lang.in(.{ .lua51, .luajit })) _ = L.gcIsRunning();

    if (comptime lua.lang.in(.{ .lua51, .lua52, .lua53 })) {
        _ = L.gcSetPause(2);
        _ = L.gcSetStepMul(2);
    }

    if (comptime lua.lang.eql(.lua52)) {
        _ = L.gcSetGenerational(0, 0);
        _ = L.gcSetGenerational(0, 0);
    } else if (comptime lua.lang.atLeast(.lua54)) {
        // Lua 5.4/5.5: LUA_GCGEN/LUA_GCINC always return the previous mode
        // (non-zero), so we just check the calls succeed.
        try expect(L.gcSetGenerational(0, 10));
        try expect(L.gcSetIncremental(0, 0, 0));
        _ = L.gcSetIncremental(0, 0, 0);
    } else if (comptime lua.lang.eql(.luau)) {
        _ = L.gcSetGoal(10);
        _ = L.gcSetStepMul(2);
        _ = L.gcSetStepSize(1);
    }
}

test "extra space" {
    if (comptime !lua.lang.atLeast(.lua53)) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    const space: *align(1) usize = @ptrCast(L.getExtraSpace().ptr);
    space.* = 1024;
    // each new thread is initialized with a copy of the extra space from the main thread
    var thread = L.newThread();
    try expectEqual(1024, @as(*align(1) usize, @ptrCast(thread.getExtraSpace())).*);
}

test "table access" {
    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    try L.doString("a = { [1] = 'first', key = 'value', ['other one'] = 1234 }");
    try expectEqual(.table, L.getGlobal("a"));

    if (comptime lua.lang.atLeast(.lua53)) {
        try expectEqual(.string, L.rawGetIndex(1, 1));
        try expectEqualStrings("first", L.toSlice(-1).?);
    }

    try expectEqual(.string, switch (lua.lang.version) {
        .lua53, .lua54, .lua55 => L.getIndex(1, 1),
        else => L.rawGetIndex(1, 1),
    });
    try expectEqualStrings("first", L.toSlice(-1).?);

    L.pushStringBlind("key");
    try expectEqual(.string, L.getTable(1));
    try expectEqualStrings("value", L.toSlice(-1).?);

    L.pushStringBlind("other one");
    try expectEqual(.number, L.rawGetTable(1));
    try expectEqual(1234, L.toInteger(-1).?);

    // a.name = "ziglua"
    L.pushStringBlind("name");
    L.pushStringBlind("ziglua");
    L.setTable(1);

    // a.lang = "zig"
    L.pushStringBlind("lang");
    L.pushStringBlind("zig");
    L.rawSetTable(1);

    try expectEqual(false, L.getMetatable(1));

    // create a metatable (it isn't a useful one)
    L.newTable();

    L.pushCFunction(add);
    L.setField(-2, "__len");
    L.setMetatable(1);

    try expectEqual(true, L.getMetatable(1));
    try expectEqual(.nil, L.getMetaField(-1, "__index"));
    try expectEqual(.nil, L.getMetaField(1, "__index"));

    L.pushBoolean(true);
    L.setField(1, "bool");

    try L.doString("b = a.bool");
    try expectEqual(.boolean, L.getGlobal("b"));
    try expect(L.toBoolean(-1));

    // create array [1, 2, 3, 4, 5]
    L.createTable(0, 0);
    var index: i32 = 1;
    while (index <= 5) : (index += 1) {
        L.pushInteger(index);
        if (comptime lua.lang.atLeast(.lua53)) L.setIndex(-2, index) else L.rawSetIndex(-2, index);
    }

    if (comptime !lua.lang.in(.{ .lua51, .luajit, .luau })) {
        try expectEqual(5, L.rawLen(-1));
        try expectEqual(5, L.lenRaiseErr(-1));
    }

    // add a few more
    while (index <= 10) : (index += 1) {
        L.pushInteger(index);
        L.rawSetIndex(-2, index);
    }
}

test "conversions" {
    if (comptime !lua.lang.atLeast(.lua53)) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    // number conversion
    try expectEqual(3, State.numberToInteger(3.14));
    try expectError(error.Overflow, State.numberToInteger(
        @as(lua.Number, @floatFromInt(lua.max_integer)) + 10,
    ));

    // string conversion
    try expectEqual(2, L.stringToNumber("1"));
    try expect(L.isInteger(-1));
    try expectEqual(1, L.toInteger(-1).?);

    try expectEqual(8, L.stringToNumber("  1.0  "));
    try expect(L.isNumber(-1));
    try expectEqual(1.0, L.toNumber(-1).?);

    try expectEqual(@as(usize, 0), L.stringToNumber("a"));
    try expectEqual(@as(usize, 0), L.stringToNumber("1.a"));
    try expectEqual(@as(usize, 0), L.stringToNumber(""));
}

test "absIndex" {
    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    L.setTop(2);

    try expectEqual(@as(i32, 2), L.absIndex(-1));
    try expectEqual(@as(i32, 1), L.absIndex(-2));
}

test "dump and load" {
    if (comptime lua.lang.eql(.luau)) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    // store a function in a global
    try L.doString("f = function(x) return function(n) return n + x end end");
    // put the function on the stack
    try expectEqual(.function, L.getGlobal("f"));

    const writer = struct {
        fn inner(l: *State, buf: [*]const u8, len: usize, ud: ?*anyopaque) callconv(.c) c_int {
            _ = l;
            var arr: *ArrayList(u8) = @ptrCast(@alignCast(ud));
            arr.appendSlice(std.testing.allocator, buf[0..len]) catch return 1;
            return 0;
        }
    }.inner;

    var buffer: ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);

    // save the function as a binary chunk in the buffer
    try L.dump(writer, &buffer, false);

    // clear the stack
    if (comptime lua.lang.atLeast(.lua54)) {
        // NOTE: for closeThread, passing `L` as `from` when L==from means
        // "thread closing itself" which only works inside a resume (Lua 5.5+).
        // Pass null to reset the thread normally.
        // See: https://www.L.org/manual/5.4/manual.html#lua_closethread
        //      https://www.L.org/manual/5.5/manual.html#lua_closethread
        try L.closeThread(null);
    } else L.setTop(0);

    const reader = struct {
        fn inner(l: *State, ud: ?*anyopaque, len: *usize) callconv(.c) ?[*:0]const u8 {
            _ = l;
            const arr: *ArrayList(u8) = @ptrCast(@alignCast(ud));
            len.* = arr.items.len;
            return @ptrCast(arr.items.ptr);
        }
    }.inner;

    // now load the function back onto the stack
    try L.load(reader, &buffer, "function", "b");
    try expectEqual(.function, L.typeOf(-1));

    // run the function (creating a new function)
    L.pushInteger(5);
    try L.pcall(.{ .args = 1, .rets = 1 });

    // now call the new function (which should return the value + 5)
    L.pushInteger(6);
    try L.pcall(.{ .args = 1, .rets = 1 });
    try expectEqual(11, L.toInteger(-1).?);
}

test "threads" {
    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    var new_thread = L.newThread();
    try expectEqual(1, L.getTop());
    try expectEqual(0, new_thread.getTop());

    L.pushInteger(10);
    L.pushNil();

    L.xMove(new_thread, 2);
    try expectEqual(2, new_thread.getTop());
}

test "userdata and uservalues" {
    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    const Data = struct {
        val: i32,
        code: [4]u8,
    };

    // create a Lua-owned pointer to a Data with 2 associated user values
    var data = if (comptime lua.lang.atLeast(.lua54)) L.newUserdataUV(Data, 2) else L.newUserdata(Data);
    data.val = 1;
    @memcpy(&data.code, "abcd");

    try expectEqual(data, L.toUserdata(Data, 1).?);
    try expectEqual(@as(*const anyopaque, @ptrCast(data)), L.toPointer(1).?);

    if (comptime lua.lang.in(.{ .lua52, .lua53 })) {
        // assign the associated user value
        L.pushNil();
        try expectEqual(true, L.setUserValue(1));
        try expectEqual(.nil, L.getUserValue(1));
    } else if (comptime lua.lang.atLeast(.lua54)) {
        // assign the user values
        L.pushNumber(1234.56);
        try expectEqual(true, L.setIUserValue(1, 1));

        L.pushStringBlind("test string");
        try expectEqual(true, L.setIUserValue(1, 2));

        try expectEqual(.number, L.getIUserValue(1, 1));
        try expectEqual(1234.56, L.toNumber(-1).?);
        try expectEqual(.string, L.getIUserValue(1, 2));
        try expectEqualStrings("test string", L.toSlice(-1).?);

        try expectEqual(false, L.setIUserValue(1, 3));
        try expectEqual(.none, L.getIUserValue(1, 3));
    }
}

test "upvalues" {
    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    // counter from PIL
    const counter = struct {
        fn inner(l: *State) callconv(.c) i32 {
            var counter = l.checkInteger(lua.upvalueIndex(1));
            counter += 1;
            l.pushInteger(counter);
            l.pushInteger(counter);
            l.replace(lua.upvalueIndex(1));
            return 1;
        }
    }.inner;

    // Initialize the counter at 0
    L.pushInteger(0);
    L.pushCClosure(counter, 1);
    L.setGlobal("counter");

    // call the function repeatedly, each time ensuring the result increases by one
    var expected: i32 = 1;
    while (expected <= 10) : (expected += 1) {
        try expectEqual(.function, L.getGlobal("counter"));
        L.call(.{ .rets = 1 });
        try expectEqual(expected, L.toInteger(-1).?);
        L.pop(1);
    }
}

test "table traversal" {
    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    try L.doString("t = { key = 'value', second = true, third = 1 }");
    try expectEqual(.table, L.getGlobal("t"));

    L.pushNil();

    while (L.next(1)) {
        switch (L.typeOf(-1)) {
            .string => {
                try expectEqualStrings("key", L.toSlice(-2).?);
                try expectEqualStrings("value", L.toSlice(-1).?);
            },
            .boolean => {
                try expectEqualStrings("second", L.toSlice(-2).?);
                try expectEqual(true, L.toBoolean(-1));
            },
            .number => {
                try expectEqualStrings("third", L.toSlice(-2).?);
                try expectEqual(1, L.toInteger(-1).?);
            },
            else => unreachable,
        }
        L.pop(1);
    }
}

test "registry" {
    if (comptime lua.lang.in(.{ .lua51, .luajit, .luau })) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    const key = "mykey";

    // store a string in the registry
    L.pushStringBlind("hello there");
    L.rawSetPtr(lua.registry_index, @ptrCast(key));

    // get key from the registry
    L.rawGetPBlind(lua.registry_index, @ptrCast(key));
    try expectEqualStrings("hello there", L.toSlice(-1).?);
}

test "closing vars" {
    if (comptime !lua.lang.eql(.lua54)) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    L.openlib(.base);

    // do setup in Lua for ease
    try L.doString(
        \\closed_vars = 0
        \\mt = { __close = function() closed_vars = closed_vars + 1 end }
    );

    L.newTable();
    try expectEqual(.table, L.getGlobal("mt"));
    L.setMetatable(-2);
    L.toClose(-1);
    L.closeSlot(-1);
    L.pop(1);

    L.newTable();
    try expectEqual(.table, L.getGlobal("mt"));
    L.setMetatable(-2);
    L.toClose(-1);
    L.closeSlot(-1);
    L.pop(1);

    // this should have incremented "closed_vars" to 2
    try expectEqual(.number, L.getGlobal("closed_vars"));
    try expectEqual(2, L.toNumber(-1).?);
}

test "raise error" {
    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    const makeError = struct {
        fn inner(l: *State) callconv(.c) i32 {
            _ = l.pushString("makeError made an error");
            l.raiseError();
            return 0;
        }
    }.inner;

    L.pushCFunction(makeError);
    try expectError(error.LuaRuntime, L.pcall(.{}));
    try expectEqualStrings("makeError made an error", L.toSlice(-1).?);
}

fn continuation(l: *State, status: lua.Status, ctx: lua.KContext) callconv(.c) c_int {
    _ = status;

    if (ctx == 5) {
        _ = l.pushString("done");
        return 1;
    } else {
        // yield the current context value
        l.pushInteger(@intCast(ctx));
        return l.yield(.{ .rets = 1, .ctx = ctx + 1, .k = continuation });
    }
}

test "yielding" {
    if (comptime !lua.lang.atLeast(.lua53)) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    // here we create some zig functions that will run 5 times, continutally
    // yielding a count until it finally returns the string "done"
    const willYield = struct {
        fn inner(l: *State) callconv(.c) i32 {
            return continuation(l, .ok, 0);
        }
    }.inner;

    var thread = L.newThread();
    thread.pushCFunction(willYield);

    try expect(!L.isYieldable());

    var i: i32 = 0;
    if (comptime lua.lang.atLeast(.lua54)) {
        try expect(thread.isYieldable());

        var results: i32 = undefined;
        while (i < 5) : (i += 1) {
            try expectEqual(.yield, try thread.resumeThread(L, 0, &results));
            try expectEqual(i, thread.toInteger(-1));
            thread.pop(results);
        }

        try expectEqual(.ok, try thread.resumeThread(L, 0, &results));
    } else {
        // Lua 5.3
        try expect(!thread.isYieldable());

        while (i < 5) : (i += 1) {
            try expectEqual(.yield, try thread.resumeThread(L, 0, null));
            try expectEqual(i, thread.toInteger(-1));
            L.pop(L.getTop());
        }
        try expectEqual(.ok, try thread.resumeThread(L, 0, null));
    }

    try expectEqualStrings("done", std.mem.span(thread.toString(-1).?));
}

fn continuation52(l: *State) callconv(.c) i32 {
    const ctxOrNull = l.getContext();
    const ctx = ctxOrNull orelse 0;
    if (ctx == 5) {
        _ = l.pushString("done");
        return 1;
    } else {
        // yield the current context value
        l.pushInteger(ctx);
        return l.yield(.{ .rets = 1, .ctx = ctx + 1, .k = continuation52 });
    }
}

test "yielding Lua 5.2" {
    if (comptime !lua.lang.eql(.lua52)) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    // here we create some zig functions that will run 5 times, continutally
    // yielding a count until it finally returns the string "done"
    const willYield = struct {
        fn inner(l: *State) callconv(.c) i32 {
            return continuation52(l);
        }
    }.inner;

    var thread = L.newThread();
    thread.pushCFunction(willYield);

    var i: i32 = 0;
    while (i < 5) : (i += 1) {
        try expectEqual(.yield, try thread.resumeThread(L, 0, null));
        try expectEqual(i, thread.toInteger(-1));
        L.pop(L.getTop());
    }
    try expectEqual(.ok, try thread.resumeThread(L, 0, null));
    try expectEqualStrings("done", std.mem.span(thread.toString(-1).?));
}

test "yielding no continuation" {
    if (comptime !lua.lang.in(.{ .lua51, .luau })) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    var thread = L.newThread();
    const func = struct {
        fn inner(l: *State) callconv(.c) i32 {
            l.pushInteger(1);
            return l.yield(.{ .rets = 1 });
        }
    }.inner;
    thread.pushCFunction(func);
    if (comptime lua.lang.eql(.luau)) {
        _ = try thread.resumeThread(null, 0, null);
    } else {
        _ = try thread.resumeThread(null, 0, null);
    }

    try expectEqual(1, thread.toInteger(-1));
}

test "resuming" {
    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    // here we create a Lua function that will run 5 times, continutally
    // yielding a count until it finally returns the string "done"
    var thread = L.newThread();
    thread.openLibs();
    try thread.doString(
        \\counter = function()
        \\  coroutine.yield(1)
        \\  coroutine.yield(2)
        \\  coroutine.yield(3)
        \\  coroutine.yield(4)
        \\  coroutine.yield(5)
        \\  return "done"
        \\end
    );
    try expectEqual(.function, thread.getGlobal("counter"));

    var num_results: i32 = 0;
    var i: i32 = 1;
    while (i <= 5) : (i += 1) {
        try expectEqual(.yield, switch (lua.lang.version) {
            .lua54, .lua55 => try thread.resumeThread(L, 0, &num_results),
            else => try thread.resumeThread(L, 0, null),
        });

        try expectEqual(i, thread.toInteger(-1));
        L.pop(L.getTop());
    }

    try expectEqual(.ok, switch (lua.lang.version) {
        .lua54, .lua55 => try thread.resumeThread(L, 0, &num_results),
        else => try thread.resumeThread(L, 0, null),
    });

    try expectEqualStrings("done", std.mem.span(thread.toString(-1).?));
}

test "aux check functions" {
    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    const function = struct {
        fn inner(l: *State) callconv(.c) i32 {
            l.checkAny(1);
            _ = l.checkInteger(2);
            _ = l.checkNumber(3);
            _ = l.checkString(4);
            l.checkType(5, .boolean);
            _ = if (comptime lua.lang.eql(.lua52)) l.checkUnsigned(6);
            return 0;
        }
    }.inner;

    L.pushCFunction(function);
    L.pcall(.{}) catch {
        try expectStringContains("argument #1", L.toSlice(-1).?);
        L.pop(-1);
    };

    L.pushCFunction(function);
    L.pushNil();
    L.pcall(.{ .args = 1 }) catch {
        try expectStringContains("number expected", L.toSlice(-1).?);
        L.pop(-1);
    };

    L.pushCFunction(function);
    L.pushNil();
    L.pushInteger(3);
    L.pcall(.{ .args = 2 }) catch {
        try expectStringContains("string expected", L.toSlice(-1).?);
        L.pop(-1);
    };

    L.pushCFunction(function);
    L.pushNil();
    L.pushInteger(3);
    L.pushNumber(4);
    L.pcall(.{ .args = 3 }) catch {
        try expectStringContains("string expected", L.toSlice(-1).?);
        L.pop(-1);
    };

    L.pushCFunction(function);
    L.pushNil();
    L.pushInteger(3);
    L.pushNumber(4);
    _ = L.pushString("hello world");
    L.pcall(.{ .args = 4 }) catch {
        try expectStringContains("boolean expected", L.toSlice(-1).?);
        L.pop(-1);
    };

    if (comptime lua.lang.eql(.lua52)) {
        L.pushCFunction(function);
        L.pushNil();
        L.pushInteger(3);
        L.pushNumber(4);
        _ = L.pushString("hello world");
        L.pushBoolean(true);
        L.pcall(.{ .args = 5 }) catch {
            try expectEqualStrings("bad argument #6 to '?' (number expected, got no value)", L.toSlice(-1).?);
            L.pop(-1);
        };
    }

    L.pushCFunction(function);
    // test pushFail here (currently acts the same as pushNil)
    if (comptime lua.lang.atLeast(.lua54)) L.pushFail() else L.pushNil();
    L.pushInteger(3);
    L.pushNumber(4);
    _ = L.pushString("hello world");
    L.pushBoolean(true);
    if (comptime lua.lang.eql(.lua52)) {
        L.pushUnsigned(1);
        try L.pcall(.{ .args = 6 });
    } else try L.pcall(.{ .args = 5 });
}

test "aux opt functions" {
    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    const function = struct {
        fn inner(l: *State) callconv(.c) i32 {
            const try_block = struct {
                fn inner(l1: *State) !void {
                    try expectEqual(10, l1.optInteger(1, 10));
                    try expectEqualStrings("zig", l1.optSlice(2, "zig"));
                    try expectEqual(1.23, l1.optNumber(3, 1.23));
                    try expectEqualStrings("lang", l1.optSlice(4, "lang"));
                }
            }.inner;
            try_block(l) catch l.raiseErrorStr("expected error", .{});
            return 0;
        }
    }.inner;

    L.pushCFunction(function);
    try L.pcall(.{});

    L.pushCFunction(function);
    L.pushInteger(10);
    L.pushStringBlind("zig");
    L.pushNumber(1.23);
    L.pushStringBlind("lang");
    try L.pcall(.{ .args = 4 });
}

test "checkOption" {
    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    const Variant = enum {
        one,
        two,
        three,
    };

    const function = struct {
        fn inner(l: *State) callconv(.c) i32 {
            const option = l.checkEnum(Variant, 1, .one);
            l.pushInteger(switch (option) {
                .one => 1,
                .two => 2,
                .three => 3,
            });
            return 1;
        }
    }.inner;

    L.pushCFunction(function);
    L.pushStringBlind("one");
    try L.pcall(.{ .args = 1, .rets = 1 });
    try expectEqual(1, L.toInteger(-1).?);
    L.pop(1);

    L.pushCFunction(function);
    L.pushStringBlind("two");
    try L.pcall(.{ .args = 1, .rets = 1 });
    try expectEqual(2, L.toInteger(-1).?);
    L.pop(1);

    L.pushCFunction(function);
    L.pushStringBlind("three");
    try L.pcall(.{ .args = 1, .rets = 1 });
    try expectEqual(3, L.toInteger(-1).?);
    L.pop(1);

    // try the default now
    L.pushCFunction(function);
    try L.pcall(.{ .rets = 1 });
    try expectEqual(1, L.toInteger(-1).?);
    L.pop(1);

    // check the raised error
    L.pushCFunction(function);
    L.pushStringBlind("unknown");
    try expectError(error.LuaRuntime, L.pcall(.{ .args = 1, .rets = 1 }));
    try expectStringContains("(invalid option 'unknown')", L.toSlice(-1).?);
}

test "get global fail" {
    if (comptime !lua.lang.eql(.lua54)) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    try expectEqual(.nil, L.getGlobal("foo"));
}

test "globalSub" {
    if (comptime lua.lang.eql(.luau)) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    _ = L.gsub("-gity -!", "-", "zig");
    try expectEqualStrings("ziggity zig!", L.toSlice(-1).?);
}

test "loadBuffer" {
    if (comptime lua.lang.eql(.luau)) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    if (comptime lua.lang.in(.{ .lua51, .luajit })) {
        _ = try L.loadBuffer("global = 10", "chunkname");
    } else _ = try L.loadBufferX("global = 10", "chunkname", "t");

    try L.pcall(.{ .mult_ret = true });
    try expectEqual(.number, L.getGlobal("global"));
    try expectEqual(10, L.toInteger(-1).?);
}

test "where" {
    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    const whereFn = struct {
        fn inner(l: *State) callconv(.c) i32 {
            l.where(1);
            return 1;
        }
    }.inner;

    L.pushCFunction(whereFn);
    L.setGlobal("whereFn");

    try L.doString(
        \\
        \\ret = whereFn()
    );

    try expectEqual(.string, L.getGlobal("ret"));
    try expectEqualStrings("[string \"...\"]:2: ", L.toSlice(-1).?);
}

test "ref" {
    if (comptime lua.lang.eql(.luau)) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    L.pushNil();
    try expectEqual(.ref_nil, L.ref(lua.registry_index));
    try expectEqual(0, L.getTop());

    _ = L.pushString("Hello there");
    const ref = L.ref(lua.registry_index);

    _ = L.rawGetIndex(lua.registry_index, @intCast(@intFromEnum(ref)));
    try expectEqualStrings("Hello there", L.toSlice(-1).?);

    L.unref(lua.registry_index, ref);
}

test "ref luau" {
    if (comptime !lua.lang.eql(.luau)) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    L.pushNil();
    try expectEqual(.ref_nil, L.ref(1));
    try expectEqual(1, L.getTop());

    // In luau L.ref does not pop the item from the stack
    // and the data is stored in the registry_index by default
    _ = L.pushString("Hello there");
    const ref = L.ref(2);

    _ = L.rawGetIndex(lua.registry_index, @intCast(@intFromEnum(ref)));
    try expectEqualStrings("Hello there", L.toSlice(-1).?);

    L.unref(ref);
}

test "metatables" {
    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    try L.doString("f = function() return 10 end");

    try expectEqual(true, L.newMetatable("mt"));

    if (comptime !lua.lang.in(.{ .lua51, .luajit, .luau })) {
        _ = L.getMetatableRegistry("mt");
        try expect(L.compare(1, 2, .eq));
        L.pop(1);
    }

    // set the len metamethod to the function f
    try expectEqual(.function, L.getGlobal("f"));
    L.setField(1, "__len");

    L.newTable();
    if (comptime !lua.lang.in(.{ .lua51, .luajit, .luau })) {
        L.setMetatableRegistry("mt");
    } else {
        _ = L.getField(lua.registry_index, "mt");
        L.setMetatable(-2);
    }

    try expect(L.callMeta(-1, "__len"));
    try expectEqual(10, L.toNumber(-1).?);
}

test "args and errors" {
    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    const argCheck = struct {
        fn inner(l: *State) callconv(.c) i32 {
            l.argCheck(false, 1, "error!");
            return 0;
        }
    }.inner;

    L.pushCFunction(argCheck);
    try expectError(error.LuaRuntime, L.pcall(.{}));

    const raisesError = struct {
        fn inner(l: *State) callconv(.c) i32 {
            l.raiseErrorStr("some error %s!", .{"zig"});
            unreachable;
        }
    }.inner;

    L.pushCFunction(raisesError);
    try expectError(error.LuaRuntime, L.pcall(.{}));
    try expectEqualStrings("some error zig!", L.toSlice(-1).?);

    if (comptime !lua.lang.eql(.lua54)) return;

    const argExpected = struct {
        fn inner(l: *State) callconv(.c) i32 {
            l.argExpected(false, 1, "string");
            return 0;
        }
    }.inner;

    L.pushCFunction(argExpected);
    try expectError(error.LuaRuntime, L.pcall(.{}));
}

test "traceback" {
    if (comptime lua.lang.in(.{ .lua51, .luajit, .luau })) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    const tracebackFn = struct {
        fn inner(l: *State) callconv(.c) i32 {
            l.traceback(l, "", 1);
            return 1;
        }
    }.inner;

    L.pushCFunction(tracebackFn);
    L.setGlobal("tracebackFn");
    try L.doString("res = tracebackFn()");

    try expectEqual(.string, L.getGlobal("res"));
    try expectEqualStrings(
        "\nstack traceback:\n\t[string \"res = tracebackFn()\"]:1: in main chunk",
        L.toSlice(-1).?,
    );
}

test "getSubtable" {
    if (comptime lua.lang.in(.{ .lua51, .luajit, .luau })) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    try L.doString(
        \\a = {
        \\  b = {},
        \\}
    );
    try expectEqual(.table, L.getGlobal("a"));

    // get the subtable a.b
    _ = L.getSubtable(-1, "b");

    // fail to get the subtable a.c (but it is created)
    try expectEqual(false, L.getSubtable(-2, "c"));

    // now a.c will return true
    try expectEqual(true, L.getSubtable(-3, "c"));
}

test "userdata" {
    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    const Type = struct { a: i32, b: f32 };
    try expectEqual(true, L.newMetatable("Type"));

    const checkUdata = struct {
        fn inner(l: *State) callconv(.c) i32 {
            const ptr = l.checkUserdata(Type, 1, "Type");
            if (ptr.a != 1234) {
                _ = l.pushString("error!");
                l.raiseError();
            }
            if (ptr.b != 3.14) {
                _ = l.pushString("error!");
                l.raiseError();
            }
            return 1;
        }
    }.inner;

    L.pushCFunction(checkUdata);

    {
        var t = if (comptime lua.lang.atLeast(.lua54)) L.newUserdataUV(Type, 0) else L.newUserdata(Type);
        if (comptime lua.lang.in(.{ .lua51, .luajit, .luau })) {
            _ = L.getField(lua.registry_index, "Type");
            L.setMetatable(-2);
        } else L.setMetatableRegistry("Type");

        t.a = 1234;
        t.b = 3.14;

        // call checkUdata asserting that the udata passed in with the
        // correct metatable and values
        try L.pcall(.{ .args = 1, .rets = 1 });
    }

    if (comptime lua.lang.in(.{ .lua51, .luajit, .luau })) return;

    const testUdata: lua.CFn = struct {
        fn inner(l: *State) callconv(.c) i32 {
            const ptr = l.testUserdata(Type, 1, "Type") orelse {
                _ = l.pushString("error!");
                l.raiseError();
            };
            if (ptr.a != 1234) {
                _ = l.pushString("error!");
                l.raiseError();
            }
            if (ptr.b != 3.14) {
                _ = l.pushString("error!");
                l.raiseError();
            }
            return 0;
        }
    }.inner;

    L.pushCFunction(testUdata);

    {
        var t = if (comptime lua.lang.atLeast(.lua54)) L.newUserdataUV(Type, 0) else L.newUserdata(Type);
        L.setMetatableRegistry("Type");
        t.a = 1234;
        t.b = 3.14;

        // call checkUdata asserting that the udata passed in with the
        // correct metatable and values
        try L.pcall(.{ .args = 1 });
    }
}

test "userdata slices" {
    const Integer = lua.Integer;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    try expectEqual(true, L.newMetatable("FixedArray"));

    // create an array of 10
    const slice = L.newUserdataSlice(Integer, 10, 0);
    if (comptime lua.lang.in(.{ .lua51, .luajit, .luau })) {
        _ = L.getField(lua.registry_index, "FixedArray");
        L.setMetatable(-2);
    } else L.setMetatableRegistry("FixedArray");

    for (slice, 1..) |*item, index| {
        item.* = @intCast(index);
    }

    const udataFn = struct {
        fn inner(l: *State) callconv(.c) i32 {
            _ = l.checkUdataSlice(Integer, 1, "FixedArray");

            if (comptime !lua.lang.in(.{ .lua51, .luajit, .luau }))
                _ = l.testUdataSlice(Integer, 1, "FixedArray");

            const arr = l.toUserdataSlice(Integer, 1).?;
            for (arr, 1..) |item, index| {
                if (item != index) l.raiseErrorStr("something broke!", .{});
            }

            return 0;
        }
    }.inner;

    L.pushCFunction(udataFn);
    L.pushValue(2);

    try L.pcall(.{ .args = 1 });
}

test "function environments" {
    if (comptime !lua.lang.in(.{ .lua51, .luau })) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    try L.doString("function test() return x end");

    // set the global _G.x to be 10
    L.pushInteger(10);
    L.setGlobal("x");

    try expectEqual(.function, L.getGlobal("test"));
    try L.pcall(.{ .rets = 1 });
    try testing.expectEqual(10, L.toInteger(1));
    L.pop(1);

    // now set the functions table to have a different value of x
    try expectEqual(.function, L.getGlobal("test"));
    L.newTable();
    L.pushInteger(20);
    L.setField(2, "x");
    try testing.expectEqual(true, L.setFnEnvironment(1));

    try L.pcall(.{ .rets = 1 });
    try testing.expectEqual(20, L.toInteger(1));
    L.pop(1);

    try expectEqual(.function, L.getGlobal("test"));
    L.getFnEnvironment(1);
    _ = L.getField(2, "x");
    try testing.expectEqual(20, L.toInteger(3));
}

test "objectLen" {
    if (comptime !lua.lang.in(.{ .lua51, .luau })) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    L.pushStringBlind("lua");
    try testing.expectEqual(3, L.objectLen(-1));
}

// Debug Library

test "debug interface" {
    if (comptime lua.lang.in(.{ .lua51, .luajit, .luau })) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    try L.doString(
        \\f = function(x)
        \\  local y = x * 2
        \\  y = y + 2
        \\  return x + y
        \\end
    );
    try expectEqual(.function, L.getGlobal("f"));

    var info: DebugInfo = undefined;
    L.getInfo(.{
        .@">" = true,
        .l = true,
        .S = true,
        .n = true,
        .u = true,
        .t = true,
    }, &info);

    // get information about the function
    try expectEqual(.Lua, info.what);
    try expectEqual(.other, info.name_what);
    const len = std.mem.len(@as([*:0]u8, @ptrCast(&info.short_src)));
    try expectEqualStrings("[string \"f = function(x)...\"]", info.short_src[0..len]);
    try expectEqual(1, info.first_line_defined);
    try expectEqual(5, info.last_line_defined);
    try expectEqual(1, info.num_params);
    try expectEqual(0, info.num_upvalues);
    try expect(!info.is_tail_call);
    try expectEqual(null, info.current_line);

    // create a hook
    const hook = struct {
        fn inner(l: *State, event: lua.Event, ar: *lua.DebugInfo) callconv(.c) void {
            switch (event) {
                .call => {
                    if (comptime lua.lang.atLeast(.lua54))
                        l.getInfo(.{ .l = true, .r = true }, ar)
                    else
                        l.getInfo(.{ .l = true }, ar);
                    if (ar.current_line.? != 2)
                        l.raiseErrorStr("Expected line to be 2, got {}", .{ar.current_line.?});
                    _ = if (comptime lua.lang.atLeast(.lua54))
                        l.getLocal(ar, ar.first_transfer).?
                    else
                        l.getLocal(ar, 1).?;
                    if (l.toNumber(-1).? != 3)
                        l.raiseErrorStr("Expected x to equal 3, got {}", .{l.toNumber(-1).?});
                },
                .line => if (ar.current_line.? == 4) {
                    // modify the value of y to be 0 right before returning
                    l.pushNumber(0);
                    _ = l.setLocal(ar, 2).?;
                },
                .ret => {
                    if (comptime lua.lang.atLeast(.lua54))
                        l.getInfo(.{ .l = true, .r = true }, ar)
                    else
                        l.getInfo(.{ .l = true }, ar);
                    if (ar.current_line.? != 4)
                        std.debug.panic("Expected line to be 4", .{});
                    _ = if (comptime lua.lang.atLeast(.lua54))
                        l.getLocal(ar, ar.first_transfer).?
                    else
                        l.getLocal(ar, 1).?;
                    if (l.toNumber(-1).? != 3)
                        std.debug.panic("Expected result to equal 3", .{});
                },
                else => unreachable,
            }
        }
    }.inner;

    // run the hook when a function is called
    try expectEqual(null, L.getHook());
    try expectEqual(lua.HookMask{}, L.getHookMask());
    try expectEqual(0, L.getHookCount());

    L.setHook(lua.hookFn(hook), .{ .call = true, .line = true, .ret = true }, 0);
    try expect(L.getHook() != null);
    try expectEqual(lua.HookMask{ .call = true, .line = true, .ret = true }, L.getHookMask());

    try expectEqual(.function, L.getGlobal("f"));
    L.pushNumber(3);
    try L.pcall(.{ .args = 1, .rets = 1 });
}

test "debug interface Lua 5.1 and Luau" {
    if (comptime !lua.lang.in(.{ .lua51, .luau })) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    try L.doString(
        \\f = function(x)
        \\  local y = x * 2
        \\  y = y + 2
        \\  return x + y
        \\end
    );
    try expectEqual(.function, L.getGlobal("f"));

    var info: DebugInfo = undefined;

    if (comptime lua.lang.eql(.lua51)) {
        L.getInfo(.{
            .@">" = true,
            .l = true,
            .S = true,
            .n = true,
            .u = true,
        }, &info);
    } else {
        L.getInfo(-1, .{
            .l = true,
            .s = true,
            .n = true,
            .u = true,
        }, &info);
    }

    // get information about the function
    try expectEqual(.Lua, info.what);
    const len = std.mem.len(@as([*:0]u8, @ptrCast(&info.short_src)));
    try expectEqual(1, info.first_line_defined);

    if (comptime lua.lang.eql(.luau)) {
        try expectEqual(1, info.current_line);
        try expectEqualStrings("[string \"...\"]", info.short_src[0..len]);
        return;
    }

    try expectEqual(null, info.current_line);
    try expectEqualStrings("[string \"f = function(x)...\"]", info.short_src[0..len]);
    try expectEqual(.other, info.name_what);
    try expectEqual(5, info.last_line_defined);

    // create a hook
    const hook = struct {
        fn inner(l: *State, event: lua.Event, i: *lua.DebugInfo) callconv(.c) void {
            switch (event) {
                .call => {
                    l.getInfo(.{ .l = true }, i);
                    if (i.current_line.? != 2) l.raiseErrorStr("Expected line to be 2", .{});
                    _ = l.getLocal(i, 1).?;
                    if (l.toNumber(-1).? != 3) l.raiseErrorStr("Expected x to equal 3", .{});
                },
                .line => if (i.current_line.? == 4) {
                    // modify the value of y to be 0 right before returning
                    l.pushNumber(0);
                    _ = l.setLocal(i, 2).?;
                },
                .ret => {
                    l.getInfo(.{ .l = true }, i);
                    if (i.current_line.? != 4) l.raiseErrorStr("Expected line to be 4", .{});
                    _ = l.getLocal(i, 1).?;
                    if (l.toNumber(-1).? != 3) l.raiseErrorStr("Expected result to equal 3", .{});
                },
                else => unreachable,
            }
        }
    }.inner;

    // run the hook when a function is called
    try expectEqual(null, L.getHook());
    try expectEqual(lua.HookMask{}, L.getHookMask());
    try expectEqual(@as(i32, 0), L.getHookCount());

    L.setHook(lua.hookFn(hook), .{ .call = true, .line = true, .ret = true }, 0);
    try expect(L.getHook() != null);
    try expectEqual(lua.HookMask{ .call = true, .line = true, .ret = true }, L.getHookMask());

    try expectEqual(.function, L.getGlobal("f"));
    L.pushNumber(3);
    try L.pcall(.{ .args = 1, .rets = 1 });
}

test "debug upvalues" {
    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    try L.doString(
        \\f = function(x)
        \\  return function(y)
        \\    return x + y
        \\  end
        \\end
        \\addone = f(1)
    );
    try expectEqual(.function, L.getGlobal("addone"));

    // index doesn't exist
    try expectEqual(null, L.getUpvalue(1, 2));

    // inspect the upvalue (should be x)
    const name = if (comptime lua.lang.eql(.luau)) "" else "x";
    const r = L.getUpvalue(-1, 1);
    try expectEqualStrings(std.mem.span(r orelse "null"), name);
    try expectEqual(1, L.toNumber(-1).?);
    L.pop(1);

    // now make the function an "add five" function
    L.pushNumber(5);
    const r2 = L.setUpvalue(-2, 1);
    try expectEqualStrings(std.mem.span(r2 orelse "null"), name);

    // test a bad index (the valid one's result is unpredicable)
    if (comptime lua.lang.atLeast(.lua54))
        try expectEqual(null, L.upvalueId(-1, 2));

    // call the new function (should return 7)
    L.pushNumber(2);
    try L.pcall(.{ .args = 1, .rets = 1 });
    try expectEqual(7, L.toNumber(-1).?);

    if (comptime lua.lang.in(.{ .lua51, .luajit, .luau })) return;

    L.pop(1);

    try L.doString(
        \\addthree = f(3)
    );

    try expectEqual(.function, L.getGlobal("addone"));
    try expectEqual(.function, L.getGlobal("addthree"));

    // now addone and addthree share the same upvalue
    L.upvalueJoin(-2, 1, -1, 1);
    try expectEqual(
        L.upvalueId(-2, 1),
        L.upvalueId(-1, 1),
    );
}

test "getstack" {
    if (comptime lua.lang.eql(.luau)) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    try expectEqual(null, L.getStack(1));

    const function = struct {
        fn inner(l: *State) callconv(.c) i32 {
            // get info about calling L function
            var info = l.getStack(1).?;
            l.getInfo(.{ .n = true }, &info);
            expectEqualStrings("g", std.mem.span(info.name.?)) catch
                l.raiseErrorStr("unexpected error", .{});
            return 0;
        }
    }.inner;

    L.pushCFunction(function);
    L.setGlobal("f");

    try L.doString(
        \\g = function()
        \\  f()
        \\end
        \\g()
    );
}

test "compile and run bytecode" {
    if (comptime !lua.lang.eql(.luau)) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();
    L.openLibs();

    // Load bytecode
    const src = "return 133";
    const bc = try L.compile(testing.allocator, src, L.CompileOptions{});
    defer testing.allocator.free(bc);

    try L.loadBytecode("...", bc);
    try L.pcall(.{ .rets = 1 });
    const v = L.toInteger(-1).?;
    try expectEqual(133, v);

    // Try mutable globals.  Calls to mutable globals should produce longer bytecode.
    const src2 = "Foo.print()\nBar.print()";
    const bc1 = try L.compile(testing.allocator, src2, L.CompileOptions{});
    defer testing.allocator.free(bc1);

    const options = L.CompileOptions{
        .mutable_globals = &[_:null]?[*:0]const u8{ "Foo", "Bar" },
    };
    const bc2 = try L.compile(testing.allocator, src2, options);
    defer testing.allocator.free(bc2);
    // A really crude check for changed bytecode.  Better would be to match
    // produced bytecode in text format, but the API doesn't support it.
    try expect(bc1.len < bc2.len);
}

// test "userdata dtor" {
//     if (comptime !lua.lang.eql(.luau)) return;
//     var gc_hits: i32 = 0;
//
//     const Data = struct {
//         gc_hits_ptr: *i32,
//
//         pub fn dtor(udata: *anyopaque) void {
//             const self: *@This() = @ptrCast(@alignCast(udata));
//             self.gc_hits_ptr.* = self.gc_hits_ptr.* + 1;
//         }
//     };
//
//     // create a Lua-owned pointer to a Data, configure Data with a destructor.
//     {
//         const L: *State = try .init(testing.allocator);
//         defer L.deinit(); // forces dtors to be called at the latest
//
//         var data = L.newUserdataDtor(Data, Data.dtor);
//         data.gc_hits_ptr = &gc_hits;
//         try expectEqual(@as(*anyopaque, @ptrCast(data)), L.toPointer(1).?);
//         try expectEqual(0, gc_hits);
//         L.pop(1); // don't let the stack hold a ref to the user data
//         L.gcCollect();
//         try expectEqual(1, gc_hits);
//         L.gcCollect();
//         try expectEqual(1, gc_hits);
//     }
// }

// test "tagged userdata" {
//     if (comptime !lua.lang.eql(.luau)) return;
//
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit(); // forces dtors to be called at the latest
//
//     const Data = struct {
//         val: i32,
//     };
//
//     // create a Lua-owned tagged pointer
//     var data = L.newUserdataTagged(Data, 13);
//     data.val = 1;
//
//     const data2 = L.toUserdataTagged(Data, -1, 13).?;
//     try testing.expectEqual(data.val, data2.val);
//
//     var tag = L.userdataTag(-1).?;
//     try testing.expectEqual(13, tag);
//
//     L.setUserdataTag(-1, 100);
//     tag = L.userdataTag(-1).?;
//     try testing.expectEqual(100, tag);
//
//     // Test that tag mismatch error handling works.  Userdata is not tagged with 123.
//     try expectError(error.LuaError, L.toUserdataTagged(Data, -1, 123));
//
//     // should not fail
//     _ = L.toUserdataTagged(Data, -1, 100).?;
//
//     // Integer is not userdata, so userdataTag should fail.
//     L.pushInteger(13);
//     try expectError(error.LuaError, L.userdataTag(-1));
// }

fn vectorCtor(l: *State) callconv(.c) i32 {
    const x = l.toNumber(1).?;
    const y = l.toNumber(2).?;
    const z = l.toNumber(3).?;
    if (lua.luau_vector_size == 4) {
        const w = l.optNumber(4, 0);
        l.pushVector(@floatCast(x), @floatCast(y), @floatCast(z), @floatCast(w));
    } else {
        l.pushVector(@floatCast(x), @floatCast(y), @floatCast(z));
    }
    return 1;
}

// test "luau vectors" {
//     if (comptime !lua.lang.eql(.luau)) return;
//
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//     L.openLibs();
//     L.register("vector", L.wrap(vectorCtor));
//
//     try L.doString(
//         \\function test()
//         \\  local a = vector(1, 2, 3)
//         \\  local b = vector(4, 5, 6)
//         \\  local c = (a + b) * vector(2, 2, 2)
//         \\  return vector(c.x, c.y, c.z)
//         \\end
//     );
//     try expectEqual(.function, L.getGlobal("test"));
//     try L.pcall(.{ .rets = 1 });
//     var v = L.toVector(-1).?;
//     try testing.expectEqualSlices(f32, &[3]f32{ 10, 14, 18 }, v[0..3]);
//
//     if (L.luau_vector_size == 3) L.pushVector(1, 2, 3) else L.pushVector(1, 2, 3, 4);
//     try expect(L.isVector(-1));
//     v = L.toVector(-1).?;
//     const expected = if (L.luau_vector_size == 3) [3]f32{ 1, 2, 3 } else [4]f32{ 1, 2, 3, 4 };
//     try expectEqual(expected, v);
//     try expectEqualStrings("vector", L.typeNameIndex(-1));
//
//     L.pushInteger(5);
//     try expect(!L.isVector(-1));
// }
//
// test "luau 4-vectors" {
//     if (comptime !lua.lang.eql(.luau)) return;
//
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//     L.openLibs();
//     L.register("vector", L.wrap(vectorCtor));
//
//     // More specific 4-vector tests
//     if (L.luau_vector_size == 4) {
//         try L.doString(
//             \\local a = vector(1, 2, 3, 4)
//             \\local b = vector(5, 6, 7, 8)
//             \\return a + b
//         );
//         const vec4 = L.toVector(-1).?;
//         try expectEqual([4]f32{ 6, 8, 10, 12 }, vec4);
//     }
// }

// test "useratom" {
//     if (comptime !lua.lang.eql(.luau)) return;
//
//     const useratomCb = struct {
//         pub fn inner(str: []const u8) i16 {
//             if (std.mem.eql(u8, str, "method_one")) {
//                 return 0;
//             } else if (std.mem.eql(u8, str, "another_method")) {
//                 return 1;
//             }
//             return -1;
//         }
//     }.inner;
//
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//     L.setUserAtomCallbackFn(L.wrap(useratomCb));
//
//     L.pushStringBlind("unknownatom");
//     L.pushStringBlind("method_one");
//     L.pushStringBlind("another_method");
//
//     const atom_idx0, const str0 = L.toStringAtom(-2).?;
//     const atom_idx1, const str1 = L.toStringAtom(-1).?;
//     const atom_idx2, const str2 = L.toStringAtom(-3).?;
//     try testing.expect(std.mem.eql(u8, str0, "method_one"));
//     try testing.expect(std.mem.eql(u8, str1, "another_method"));
//     try testing.expect(std.mem.eql(u8, str2, "unknownatom")); // should work, but returns -1 for atom idx
//
//     try expectEqual(0, atom_idx0);
//     try expectEqual(1, atom_idx1);
//     try expectEqual(-1, atom_idx2);
//
//     L.pushInteger(13);
//     try expectError(error.LuaError, L.toStringAtom(-1));
// }

test "namecall" {
    if (comptime !lua.lang.eql(.luau)) return;

    const funcs = struct {
        const dot_idx: i32 = 0;
        const sum_idx: i32 = 1;

        // The useratom callback to initially form a mapping from method names to
        // integer indices. The indices can then be used to quickly dispatch the right
        // method in namecalls without needing to perform string compares.
        pub fn useratomCb(str: []const u8) i16 {
            if (std.mem.eql(u8, str, "dot")) {
                return dot_idx;
            }
            if (std.mem.eql(u8, str, "sum")) {
                return sum_idx;
            }
            return -1;
        }

        pub fn vectorNamecall(l: *State) i32 {
            const atom_idx, _ = l.namecallAtom() catch {
                l.raiseErrorStr("%s is not a valid vector method", .{l.checkString(1).ptr});
            };
            switch (atom_idx) {
                dot_idx => {
                    const a = l.checkVector(1);
                    const b = l.checkVector(2);
                    l.pushNumber(a[0] * b[0] + a[1] * b[1] + a[2] * b[2]); // vec3 dot
                    return 1;
                },
                sum_idx => {
                    const a = l.checkVector(1);
                    l.pushNumber(a[0] + a[1] + a[2]);
                    return 1;
                },
                else => unreachable,
            }
        }
    };

    const L: *State = try .init(testing.allocator);
    defer L.deinit();
    L.setUserAtomCallbackFn(L.wrap(funcs.useratomCb));

    L.register("vector", L.wrap(vectorCtor));
    L.pushVector(0, 0, 0);

    try expectEqual(true, L.newMetatable("vector"));
    L.pushStringBlind("__namecall");
    L.pushCFunctionNamed(L.wrap(funcs.vectorNamecall), "vector_namecall");
    L.setTable(-3);

    L.setReadonly(-1, true);
    L.setMetatable(-2);

    // Vector setup, try some L code on them.
    try L.doString(
        \\local a = vector(1, 2, 3)
        \\local b = vector(3, 2, 1)
        \\return a:dot(b)
    );
    const d = L.toNumber(-1).?;
    L.pop(-1);
    try expectEqual(10, d);

    try L.doString(
        \\local a = vector(1, 2, 3)
        \\return a:sum()
    );
    const s = L.toNumber(-1).?;
    L.pop(-1);
    try expectEqual(6, s);
}

// test "toAny" {
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//
//     //int
//     L.pushInteger(100);
//     const my_int = L.toAny(i32, -1).?;
//     try testing.expect(my_int == 100);
//
//     //bool
//     L.pushBoolean(true);
//     const my_bool = L.toAny(bool, -1).?;
//     try testing.expect(my_bool);
//
//     //float
//     L.pushNumber(100.0);
//     const my_float = L.toAny(f32, -1).?;
//     try testing.expect(my_float == 100.0);
//
//     //[]const u8
//     L.pushStringBlind("hello world");
//     const my_string_1 =  L.toAny([]const u8, -1).?;
//     try testing.expect(std.mem.eql(u8, my_string_1, "hello world"));
//
//     //[:0]const u8
//     L.pushStringBlind("hello world");
//     const my_string_2 = L.toAny([:0]const u8, -1).?;
//     try testing.expect(std.mem.eql(u8, my_string_2, "hello world"));
//
//     //[*:0]const u8
//     L.pushStringBlind("hello world");
//     const my_string_3 = L.toAny([*:0]const u8, -1).?;
//     const end = std.mem.indexOfSentinel(u8, 0, my_string_3);
//     try testing.expect(std.mem.eql(u8, my_string_3[0..end], "hello world"));
//
//     //ptr
//     var my_value: i32 = 100;
//     _ = L.pushLightUserdata(&my_value);
//     const my_ptr = L.toAny(*i32, -1).?;
//     try testing.expect(my_ptr.* == my_value);
//
//     //optional
//     L.pushNil();
//     const maybe = L.toAny(?i32, -1).?;
//     try testing.expect(maybe == null);
//
//     //enum
//     const MyEnumType = enum { hello, goodbye };
//     L.pushStringBlind("hello");
//     const my_enum = L.toAny(MyEnumType, -1).?;
//     try testing.expect(my_enum == MyEnumType.hello);
//
//     //void
//     try L.doString("value = {}\nvalue_err = {a = 5}");
//     try expectEqual(.table, L.getGlobal("value"));
//     try testing.expectEqual(void{}, L.toAny(void, -1).?);
//     try expectEqual(.table, L.getGlobal("value_err"));
//     try testing.expectError(error.LuaVoidTableIsNotEmpty, L.toAny(void, -1).?);
// }
//
// test "toAny struct" {
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//
//     const MyType = struct {
//         foo: i32,
//         bar: bool,
//         bizz: []const u8 = "hi",
//     };
//     try L.doString("value = {[\"foo\"] = 10, [\"bar\"] = false}");
//     const lua_type = L.getGlobal("value");
//     try testing.expect(lua_type == .table);
//     const my_struct = L.toAny(MyType, 1).?;
//     try testing.expect(std.meta.eql(
//         my_struct,
//         MyType{ .foo = 10, .bar = false },
//     ));
// }
//
// test "toAny tuple from vararg" {
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//
//     const Tuple = std.meta.Tuple(&.{ i32, bool, i32 });
//
//     L.pushInteger(100);
//     L.pushBoolean(true);
//     L.pushInteger(300);
//
//     const result = L.toAny(Tuple, 1).?;
//     try testing.expect(std.meta.eql(result, .{ 100, true, 300 }));
//
//     const result_reverse = L.toAny(Tuple, -1).?;
//     try testing.expect(std.meta.eql(result_reverse, .{ 300, true, 100 }));
//
//     const result_error = L.toAny(Tuple, 2);
//     try testing.expectError(error.NotInRange, result_error);
//
//     const result_reverse_error = L.toAny(Tuple, -2);
//     try testing.expectError(error.NotInRange, result_reverse_error);
// }
//
// test "toAny tuple from struct" {
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//
//     const MyType = struct {
//         foo: i32,
//         bar: bool,
//         tuple: std.meta.Tuple(&.{ i32, bool, struct { foo: bool } }),
//     };
//
//     try L.doString(
//         \\ value = {
//         \\   ["foo"] = 10,
//         \\   ["bar"] = false,
//         \\   ["tuple"] = {100, false, {["foo"] = true}}
//         \\ }
//     );
//
//     const lua_type = L.getGlobal("value");
//     try testing.expect(lua_type == .table);
//     const my_struct = L.toAny(MyType, 1).?;
//     try testing.expect(std.meta.eql(
//         my_struct,
//         MyType{ .foo = 10, .bar = false, .tuple = .{ 100, false, .{ .foo = true } } },
//     ));
// }
//
// test "toAny from struct with fromLua" {
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//
//     const MyType = struct {
//         foo: bool,
//         bar: struct {
//             const Self = @This();
//             foo: i32,
//
//             pub fn fromLua(l: *State, a: ?std.mem.Allocator, i: i32) !Self {
//                 return try l.toStruct(Self, a, false, i);
//             }
//         },
//     };
//
//     try L.doString(
//         \\ value = {
//         \\   ["foo"] = true,
//         \\   ["bar"] = {
//         \\     ["foo"] = 12
//         \\   }
//         \\ }
//     );
//
//     const lua_type = L.getGlobal("value");
//     try testing.expect(lua_type == .table);
//     const my_struct = L.toAny(MyType, 1).?;
//     try testing.expect(std.meta.eql(
//         my_struct,
//         MyType{ .foo = true, .bar = .{ .foo = 12 } },
//     ));
// }
//
// test "toAny mutable string" {
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//
//     //[] u8
//     L.pushStringBlind("hello world");
//     const parsed = L.toAnyAlloc([]u8, -1).?;
//     defer parsed.deinit();
//
//     const my_string = parsed.value;
//
//     try testing.expect(std.mem.eql(u8, my_string, "hello world"));
// }
//
// test "toAny mutable string in struct" {
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//
//     const MyType = struct {
//         name: []u8,
//         sentinel: [:0]u8,
//         bar: bool,
//     };
//     try L.doString("value = {[\"name\"] = \"hi\", [\"sentinel\"] = \"ss\", [\"bar\"] = false}");
//     const lua_type = L.getGlobal("value");
//     try testing.expect(lua_type == .table);
//     const parsed = L.toAnyAlloc(MyType, 1).?;
//     defer parsed.deinit();
//
//     const my_struct = parsed.value;
//
//     var name: [2]u8 = .{ 'h', 'i' };
//     var sentinel: [2:0]u8 = .{ 's', 's' };
//
//     try testing.expectEqualDeep(
//         MyType{ .name = &name, .sentinel = &sentinel, .bar = false },
//         my_struct,
//     );
// }
//
// test "toAny struct recursive" {
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//
//     const MyType = struct {
//         foo: i32 = 10,
//         bar: bool = false,
//         bizz: []const u8 = "hi",
//         meep: struct { a: ?i7 = null } = .{},
//     };
//
//     try L.doString(
//         \\value = {
//         \\  ["foo"] = 10,
//         \\  ["bar"] = false,
//         \\  ["bizz"] = "hi",
//         \\  ["meep"] = {
//         \\    ["a"] = nil
//         \\  }
//         \\}
//     );
//
//     try expectEqual(.table, L.getGlobal("value"));
//     const my_struct = L.toAny(MyType, -1).?;
//     try testing.expectEqualDeep(MyType{}, my_struct);
// }
//
// test "toAny tagged union" {
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//
//     const MyType = union(enum) {
//         a: i32,
//         b: bool,
//         c: []const u8,
//         d: struct { t0: f64, t1: f64 },
//     };
//
//     try L.doString(
//         \\value0 = {
//         \\  ["c"] = "Hello, world!",
//         \\}
//         \\value1 = {
//         \\  ["d"] = {t0 = 5.0, t1 = -3.0},
//         \\}
//         \\value2 = {
//         \\  ["a"] = 1000,
//         \\}
//     );
//
//     try expectEqual(.table, L.getGlobal("value0"));
//     const my_struct0 = L.toAny(MyType, -1).?;
//     try testing.expectEqualDeep(MyType{ .c = "Hello, world!" }, my_struct0);
//
//     try expectEqual(.table, L.getGlobal("value1"));
//     const my_struct1 = L.toAny(MyType, -1).?;
//     try testing.expectEqualDeep(MyType{ .d = .{ .t0 = 5.0, .t1 = -3.0 } }, my_struct1);
//
//     try expectEqual(.table, L.getGlobal("value2"));
//     const my_struct2 = L.toAny(MyType, -1).?;
//     try testing.expectEqualDeep(MyType{ .a = 1000 }, my_struct2);
// }
//
// test "toAny slice" {
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//
//     const program =
//         \\list = {1, 2, 3, 4, 5}
//     ;
//     try L.doString(program);
//     try expectEqual(.table, L.getGlobal("list"));
//     const sliced =   L.toAnyAlloc([]u32, -1).?;
//     defer sliced.deinit();
//
//     try testing.expect(
//         std.mem.eql(u32, &[_]u32{ 1, 2, 3, 4, 5 }, sliced.value),
//     );
// }
//
// test "toAny array" {
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//
//     const arr: [5]?u32 = .{ 1, 2, null, 4, 5 };
//     const program =
//         \\array= {1, 2, nil, 4, 5}
//     ;
//     try L.doString(program);
//     try expectEqual(.table, L.getGlobal("array"));
//     const array = L.toAny([5]?u32, -1).?;
//     try testing.expectEqual(arr, array);
// }
//
// test "toAny vector" {
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//
//     const vec = @Vector(4, bool){ true, false, false, true };
//     const program =
//         \\vector= {true, false, false, true}
//     ;
//     try L.doString(program);
//     try expectEqual(.table, L.getGlobal("vector"));
//     const vector = L.toAny(@Vector(4, bool), -1).?;
//     try testing.expectEqual(vec, vector);
// }
//
// test "pushAny" {
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//
//     //int
//     try L.pushAny(1);
//     const my_int = L.toInteger(-1).?;
//     try testing.expect(my_int == 1);
//
//     //float
//     try L.pushAny(1.0);
//     const my_float = L.toNumber(-1).?;
//     try testing.expect(my_float == 1.0);
//
//     //bool
//     try L.pushAny(true);
//     const my_bool = L.toBoolean(-1).?;
//     try testing.expect(my_bool);
//
//     //string literal
//     try L.pushAny("hello world");
//     const value = L.toSlice(-1).?;
//     const end = std.mem.indexOfSentinel(u8, 0, value);
//     try testing.expect(std.mem.eql(u8, value[0..end], "hello world"));
//
//     //null
//     try L.pushAny(null);
//     try testing.expect(L.toAny(?f32, -1).? == null);
//
//     //optional
//     const my_optional: ?i32 = -1;
//     try L.pushAny(my_optional);
//     try testing.expect(L.toAny(?i32, -1).? == my_optional);
//
//     //enum
//     const MyEnumType = enum { hello, goodbye };
//     try L.pushAny(MyEnumType.goodbye);
//     const my_enum = L.toAny(MyEnumType, -1).?;
//     try testing.expect(my_enum == MyEnumType.goodbye);
//
//     //void
//     try L.pushAny(void{});
//     try testing.expectEqual(void{}, L.toAny(void, -1).?);
// }
//
// test "pushAny struct" {
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//
//     const MyType = struct {
//         foo: i32 = 1,
//         bar: bool = false,
//         bizz: []const u8 = "hi",
//     };
//     try L.pushAny(MyType{});
//     const value = L.toAny(MyType, -1).?;
//     try testing.expect(std.mem.eql(u8, value.bizz, (MyType{}).bizz));
//     try testing.expect(value.foo == (MyType{}).foo);
//     try testing.expect(value.bar == (MyType{}).bar);
// }
//
// test "pushAny tuple" {
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//
//     const Tuple = std.meta.Tuple(&.{ i32, bool, i32 });
//     const value: Tuple = .{ 500, false, 600 };
//
//     try L.pushAny(value);
//
//     const result = L.toAny(Tuple, 1).?;
//     try testing.expect(std.meta.eql(result, .{ 500, false, 600 }));
// }

// test "pushAny from struct with toLua" {
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//
//     const MyType = struct {
//         const Self = @This();
//         foo: i32,
//         tuple: std.meta.Tuple(&.{ i32, i32 }),
//
//         pub fn toLua(self: Self, l: *State) void {
//             l.newTable();
//
//             inline for (@typeInfo(Self).@"struct".fields) |f| {
//                 try l.pushAny(f.name);
//                 try l.pushAny(@field(self, f.name));
//                 l.setTable(-3);
//             }
//         }
//     };
//
//     const value: MyType = .{ .foo = 15, .tuple = .{ 1, 2 } };
//
//     try L.pushAny(value);
//     const my_struct = L.toAny(MyType, 1).?;
//     try testing.expect(std.meta.eql(
//         my_struct,
//         MyType{ .foo = 15, .tuple = .{ 1, 2 } },
//     ));
// }

// test "pushAny tagged union" {
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//
//     const MyType = union(enum) {
//         a: i32,
//         b: bool,
//         c: []const u8,
//         d: struct { t0: f64, t1: f64 },
//     };
//
//     const t0 = MyType{ .d = .{ .t0 = 5.0, .t1 = -3.0 } };
//     try L.pushAny(t0);
//     const value0 = L.toAny(MyType, -1).?;
//     try testing.expectEqualDeep(t0, value0);
//
//     const t1 = MyType{ .c = "Hello, world!" };
//     try L.pushAny(t1);
//     const value1 = L.toAny(MyType, -1).?;
//     try testing.expectEqualDeep(t1, value1);
// }

// test "pushAny toAny slice/array/vector" {
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//
//     var my_array = [_]u32{ 1, 2, 3, 4, 5 };
//     const my_slice: []u32 = my_array[0..];
//     const my_vector: @Vector(5, u32) = .{ 1, 2, 3, 4, 5 };
//     try L.pushAny(my_slice);
//     try L.pushAny(my_array);
//     try L.pushAny(my_vector);
//     const vector = L.toAny(@TypeOf(my_vector), -1).?;
//     const array = L.toAny(@TypeOf(my_array), -2).?;
//     const slice = L.toAnyAlloc(@TypeOf(my_slice), -3).?;
//     defer slice.deinit();
//
//     try testing.expectEqual(my_array, array);
//     try testing.expectEqualDeep(my_slice, slice.value);
//     try testing.expectEqual(my_vector, vector);
// }

fn foo(a: i32, b: i32) i32 {
    return a + b;
}

fn bar(a: i32, b: i32) !i32 {
    if (a > b) return error.wrong;
    return a + b;
}

fn baz(a: []const u8) usize {
    return a.len;
}

// test "autoPushFunction" {
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//     L.openLibs();
//
//     L.autoPushFunction(foo);
//     L.setGlobal("foo");
//
//     L.autoPushFunction(bar);
//     L.setGlobal("bar");
//
//     L.autoPushFunction(baz);
//     L.setGlobal("baz");
//
//     try L.doString(
//         \\result = foo(1, 2)
//     );
//     try L.doString(
//         \\local status, result = pcall(bar, 1, 2)
//     );
//
//     try L.doString(
//         \\result = baz("test")
//     );
//
//     //automatic api construction
//     const my_api = .{
//         .foo = foo,
//         .bar = bar,
//         .baz = baz,
//     };
//
//     try L.pushAny(my_api);
//     L.setGlobal("api");
//
//     try L.doString(
//         \\api.foo(1, 2)
//     );
// }

// test "autoCall" {
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//
//     const program =
//         \\function add(a, b)
//         \\   return a + b
//         \\end
//     ;
//
//     try L.doString(program);
//
//     for (0..100) |_| {
//         const sum = try L.autoCall(usize, "add", .{ 1, 2 });
//         try std.testing.expect(3 == sum);
//     }
//
//     for (0..100) |_| {
//         const sum = try L.autoCallAlloc(usize, "add", .{ 1, 2 });
//         defer sum.deinit();
//         try std.testing.expect(3 == sum.value);
//     }
// }

// test "autoCall stress test" {
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//
//     const program =
//         \\function add(a, b)
//         \\   return a + b
//         \\end
//         \\
//         \\
//         \\function KeyBindings()
//         \\
//         \\   local bindings = {
//         \\      {['name'] = 'player_right', ['key'] = 'a'},
//         \\      {['name'] = 'player_left',  ['key'] = 'd'},
//         \\      {['name'] = 'player_up',    ['key'] = 'w'},
//         \\      {['name'] = 'player_down',  ['key'] = 's'},
//         \\      {['name'] = 'zoom_in',      ['key'] = '='},
//         \\      {['name'] = 'zoom_out',     ['key'] = '-'},
//         \\      {['name'] = 'debug_mode',   ['key'] = '/'},
//         \\   }
//         \\
//         \\   return bindings
//         \\end
//     ;
//
//     try L.doString(program);
//
//     const ConfigType = struct {
//         name: []const u8,
//         key: []const u8,
//         shift: bool = false,
//         control: bool = false,
//     };
//
//     for (0..100) |_| {
//         const sum = try L.autoCallAlloc([]ConfigType, "KeyBindings", .{});
//         defer sum.deinit();
//     }
// }

// test "get set" {
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//
//     try L.set("hello", true);
//     try testing.expect(try L.get(bool, "hello"));
//
//     try L.set("world", 1000);
//     try testing.expect(try L.get(u64, "world") == 1000);
//
//     try L.set("foo", 'a');
//     try testing.expect(try L.get(u8, "foo") == 'a');
// }

// test "array of strings" {
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//
//     const program =
//         \\function strings()
//         \\   return {"hello", "world", "my name", "is foobar"}
//         \\end
//     ;
//
//     try L.doString(program);
//
//     for (0..100) |_| {
//         const strings = try L.autoCallAlloc([]const []const u8, "strings", .{});
//         defer strings.deinit();
//     }
// }

test "loadFile binary mode" {
    if (comptime lua.lang.in(.{ .lua51, .luajit, .luau })) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    // Should fail to load a L file as a binary file
    try expectError(
        error.LuaSyntax,
        L.loadFileX("src/test.lua", "b"),
    );
}

test "doFile" {
    if (comptime lua.lang.eql(.luau)) return;

    const L: *State = try .init(testing.allocator);
    defer L.deinit();

    // should set the variable GLOBAL to "testing"
    try L.doFile("src/test.lua");

    try expectEqual(.string, L.getGlobal("GLOBAL"));
    try expectEqualStrings("testing", L.toSlice(-1).?);
}

// test "interrupt" {
//     if (comptime lua.lang.eql(.luau)) return;
//
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//
//     const interrupt_handler = struct {
//         var times_called: i32 = 0;
//
//         pub fn inner(l: *State, _: i32) void {
//             times_called += 1;
//             l.setInterruptCallbackFn(null);
//             l.raiseInterruptErrorStr("interrupted", .{});
//         }
//     };
//
//     // Luau only checks for an interrupt callback at certain points, including function calls
//     try L.doString(
//         \\function add(a, b)
//         \\   return a + b
//         \\end
//     );
//     L.setInterruptCallbackFn(L.wrap(interrupt_handler.inner));
//
//     const expected_err = L.doString(
//         \\c = add(1, 2)
//     );
//     try testing.expectError(error.LuaRuntime, expected_err);
//     try testing.expectEqual(1, interrupt_handler.times_called);
//
//     // Handler should have removed itself
//     try L.doString(
//         \\c = add(1, 2)
//     );
//     try testing.expectEqual(1, interrupt_handler.times_called);
// }

// test "error union for CFn" {
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//
//     const fails = struct {
//         fn inner(l: *State) callconv(.c) i32 {
//             // Test returning some error union
//             _ = l.toInteger(1) catch return error.MissingInteger;
//             return 0;
//         }
//     }.inner;
//
//     // This will fail because there is no argument passed
//     L.pushCFunction(L.wrap(fails));
//     L.pcall(.{}) catch {
//         // Get the error string
//         try expectEqualStrings("MissingInteger", L.toSlice(-1).?);
//     };
// }

// test "checkNumeric and toNumeric" {
//     const error_msg = "integer argument doesn't fit inside u8 range [0, 255]";
//
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//
//     L.pushCFunction(struct {
//         fn f(l: *State) callconv(.c) i32 {
//             _ = l.checkNumeric(u8, 1);
//             return 1;
//         }
//     }.f);
//     const idx = L.getTop();
//
//     L.pushValue(idx);
//     L.pushInteger(128);
//     try L.pcall(.{
//         .args = 1,
//         .results = 1,
//     });
//     const val = L.toNumeric(u8, L.getTop());
//     try std.testing.expectEqual(128, val);
//
//     L.pushValue(idx);
//     L.pushInteger(256);
//     if (L.pcall(.{
//         .args = 1,
//         .results = 0,
//     })) |_| {
//         return error.ExpectedError;
//     } else |_| {
//         const string = L.toSlice(L.getTop()).?;
//         errdefer std.log.err("expected error message to contain: {s}", .{error_msg});
//         errdefer std.log.err("error message: {s}", .{string});
//         _ = std.mem.indexOf(u8, string, error_msg) orelse return error.BadErrorMessage;
//     }
// }

// test "function registration with fnRegsFromType" {
//     const L: *State = try .init(testing.allocator);
//     defer L.deinit();
//
//     const MyLib = struct {
//         pub fn add(l: *State) i32 {
//             const a = l.toInteger(1) catch 0;
//             const b = l.toInteger(2) catch 0;
//             l.pushInteger(a + b);
//             return 1;
//         }
//         pub fn neg(l: *State) i32 {
//             const a = l.toInteger(1) catch 0;
//             l.pushInteger(-a);
//             return 1;
//         }
//     };
//
//     // Construct function registration table at comptime from
//     // public decls on MyLib.
//
//     if (comptime lua.lang.eql(.lua51) or lua.lang.eql(.luau) or lua.lang.eql(.luajit)) {
//         const funcs = comptime L.fnRegsFromType(MyLib);
//         L.newTable();
//         L.registerFns("fnregs", funcs);
//     } else {
//         L.newLib(comptime L.fnRegsFromType(MyLib));
//         L.setGlobal("fnregs");
//     }
//     try L.doString("res = fnregs.add(100, fnregs.neg(25))");
//     try expectEqual(75, L.get(i32, "res"));
// }
//
