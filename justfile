demo:
    cd examples/demo && zig build -Dstrip --release=fast
    cd examples/demo/zig-out && lua test.lua

# Default test (linksys, lang=lua55)
t:
    zig build test --summary all

# Embedded Lua
t-embed ver:
    zig build test --summary all -Dembed={{ ver }}

# Per-version embedded tests
t-lua51:
    zig build test -Dembed=lua51 --summary all

t-lua52:
    zig build test -Dembed=lua52 --summary all

t-lua53:
    zig build test -Dembed=lua53 --summary all

t-lua53-32bit:
    zig build test -Dembed=lua53 -D32bit --summary all

t-lua54:
    zig build test -Dembed=lua54 --summary all

t-lua55:
    zig build test -Dembed=lua55 --summary all

t-lua55-32bit:
    zig build test -Dembed=lua55 -D32bit --summary all

# Run tests for all embedded versions
t-all: t-lua51 t-lua52 t-lua53 t-lua53-32bit t-lua54 t-lua55 t-lua55-32bit
