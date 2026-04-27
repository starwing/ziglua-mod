local mod = require "mod"

print(mod.hello())
print(mod.call(function()
    print "hello from Lua!"; return 42
end))
print(mod.callret1(function() return "call from Zig!" end))
print(mod.getzig { zig_version = "0.16.0" })
