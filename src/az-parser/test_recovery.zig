const std = @import("std");
const testing = std.testing;
const Parse = @import("Parse.zig").Parse;

test "basic error recovery in block" {
    const source =
        \\{
        \\    const x = 1;
        \\    invalid_syntax here;
        \\    const y = 2;
        \\}
    ;
    
    var parse = Parse.init(testing.allocator, source);
    defer parse.deinit();
    
    const node = try parse.parseBlock();
    try testing.expect(node != .invalid);
    try testing.expectEqual(@as(usize, 2), parse.ast.nodes.items(.data)[node].statements.len);
    
    const diags = parse.diagnostics.items;
    try testing.expect(diags.len > 0);
    try testing.expectEqual(DiagnosticTag.recovery_attempted, diags[0].tag);
}

test "error recovery in nested switch" {
    const source =
        \\switch (x) {
        \\    1 => {
        \\        switch (y) {
        \\            invalid syntax here,
        \\            2 => value,
        \\        }
        \\    },
        \\    else => default,
        \\}
    ;
    
    var parse = Parse.init(testing.allocator, source);
    defer parse.deinit();
    
    const node = try parse.parseSwitch();
    try testing.expect(node != .invalid);
    
    const diags = parse.diagnostics.items;
    try testing.expect(diags.len > 0);
    
    // Verify recovery context nesting
    var found_nested = false;
    for (diags) |diag| {
        if (diag.tag == .recovery_context and diag.extra.recovery_context.nesting_level > 0) {
            found_nested = true;
            break;
        }
    }
    try testing.expect(found_nested);
}

test "recovery from missing delimiters" {
    const source =
        \\{
        \\    const x = (1 + 2;
        \\    const y = [1, 2, 3;
        \\    const z = {a: 1, b: 2;
        \\}
    ;
    
    var parse = Parse.init(testing.allocator, source);
    defer parse.deinit();
    
    const node = try parse.parseBlock();
    try testing.expect(node != .invalid);
    
    const diags = parse.diagnostics.items;
    try testing.expectEqual(@as(usize, 3), countDiagnosticsOfType(diags, .recovery_attempted));
}

fn countDiagnosticsOfType(diags: []const Diagnostic, tag: DiagnosticTag) usize {
    var count: usize = 0;
    for (diags) |diag| {
        if (diag.tag == tag) count += 1;
    }
    return count;
}