const State = @import("lua").State;
const Reg = @import("lua").Reg;

fn lAdd(lua: *State) callconv(.c) c_int {
    const a = lua.checkInteger(1);
    const b = lua.checkInteger(2);
    lua.pushInteger(a + b);
    return 1;
}

fn lHello(lua: *State) callconv(.c) c_int {
    _ = lua.pushString("Hello from Zig!");
    return 1;
}

fn lError(lua: *State) callconv(.c) c_int {
    lua.raiseErrorStr("This is an error from Zig: %d", .{@as(c_int, 42)});
    unreachable;
}

fn lCall(lua: *State) callconv(.c) c_int {
    const top = lua.getTop();
    lua.call(.{ .args = top - 1, .mult_ret = true });
    return lua.getTop();
}

fn lCallRet1(lua: *State) callconv(.c) c_int {
    const top = lua.getTop();
    lua.call(.{ .args = top - 1, .rets = 1 });
    return 1;
}

fn lGetZig(lua: *State) callconv(.c) c_int {
    lua.checkType(1, .table);
    if (lua.getField(-1, "zig_version") == .nil)
        lua.argError(1, "'zig_version' field expected in table");
    _ = lua.pushFString("Zig version: %s", .{lua.toString(-1).?});
    return 1;
}

export fn luaopen_mod(lua: *State) callconv(.c) c_int {
    lua.newLib(&[_]Reg{
        .{ .name = "add", .func = lAdd },
        .{ .name = "hello", .func = lHello },
        .{ .name = "error", .func = lError },
        .{ .name = "call", .func = lCall },
        .{ .name = "callret1", .func = lCallRet1 },
        .{ .name = "getzig", .func = lGetZig },
    });
    return 1;
}
