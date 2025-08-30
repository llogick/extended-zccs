const std = @import("std");
const Allocator = std.mem.Allocator;
const RecoveryState = @import("recovery.zig").RecoveryState;
const Diagnostic = @import("diagnostics.zig").Diagnostic;

pub const Parse = struct {
    // Preserve all existing fields...
    
    /// Add recovery state 
    recovery: RecoveryState,
    
    pub fn init(gpa: Allocator, source: []const u8) Parse {
        // Preserve existing init...
        var p = Parse{
            // Keep all existing init fields...
            .recovery = RecoveryState.init(gpa),
        };
        return p;
    }

    pub fn deinit(p: *Parse) void {
        // Keep existing deinit...
        p.recovery.deinit();
    }

    // Keep all existing parse methods...

    /// Enhance block parsing with recovery
    fn parseBlock(p: *Parse) !Node.Index {
        try p.recovery.pushContext(p, .block_stmt);
        defer p.recovery.popContext();

        // Preserve existing block parsing logic
        const l_brace = try p.expectToken(.l_brace);
        
        var statements = std.ArrayList(Node.Index).init(p.gpa);
        defer statements.deinit();

        while (true) {
            switch (p.tokenTag(p.tok_i)) {
                .eof, .r_brace => break,
                else => {
                    const stmt = p.parseStatement() catch |err| {
                        try p.recovery.recover(p, err);
                        continue; 
                    };
                    try statements.append(stmt);
                },
            }
        }

        _ = p.eatToken(.r_brace) orelse {
            try p.warn(.missing_r_brace);
        };

        return p.addNode(.{
            .tag = .block,
            .main_token = l_brace,
            .data = .{ .statements = try statements.toOwnedSlice() },
        });
    }

    // Keep all other existing methods...
}