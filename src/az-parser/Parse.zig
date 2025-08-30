pub const Parse = struct {
    /// Previous fields remain unchanged ...
    
    /// Error recovery state
    recovery: RecoveryState,
    
    pub fn init(gpa: Allocator, source: []const u8) Parse {
        var p = Parse{
            // ... existing init fields ...
            .recovery = RecoveryState.init(gpa),
        };
        return p;
    }

    pub fn deinit(p: *Parse) void {
        // ... existing deinit ...
        p.recovery.deinit();
    }

    /// Parse a block with error recovery
    fn parseBlock(p: *Parse) !Node.Index {
        try p.recovery.pushContext(p, .block_stmt);
        defer p.recovery.popContext();

        const l_brace = try p.expectToken(.l_brace);
        
        var statements = std.ArrayList(Node.Index).init(p.gpa);
        defer statements.deinit();

        while (true) {
            switch (p.tokenTag(p.tok_i)) {
                .eof, .r_brace => break,
                else => {
                    // Try to parse statement with recovery
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
            // Continue parsing even with missing brace
        };

        return p.addNode(.{
            .tag = .block,
            .main_token = l_brace,
            .data = .{ .statements = try statements.toOwnedSlice() },
        });
    }

    /// Parse switch with error recovery
    fn parseSwitch(p: *Parse) !Node.Index {
        try p.recovery.pushContext(p, .switch_stmt);
        defer p.recovery.popContext();

        const switch_token = try p.expectToken(.keyword_switch);
        _ = try p.expectToken(.l_paren);
        const condition = try p.parseExpr();
        _ = try p.expectToken(.r_paren);
        
        _ = try p.expectToken(.l_brace);
        
        var cases = std.ArrayList(Node.Index).init(p.gpa);
        defer cases.deinit();

        var seen_else = false;
        while (true) {
            switch (p.tokenTag(p.tok_i)) {
                .eof, .r_brace => break,
                .keyword_else => {
                    if (seen_else) {
                        try p.warn(.duplicate_else);
                        try p.recovery.recover(p, error.DuplicateElse);
                        continue;
                    }
                    seen_else = true;
                    
                    const else_token = try p.expectToken(.keyword_else);
                    _ = try p.expectToken(.equal_angle_bracket_right);
                    const body = try p.parseExpr();
                    _ = try p.expectToken(.comma);

                    const else_case = try p.addNode(.{
                        .tag = .switch_else,
                        .main_token = else_token,
                        .data = .{ .switch_else = body },
                    });
                    try cases.append(else_case);
                },
                else => {
                    const case = p.parseSwitchCase() catch |err| {
                        try p.recovery.recover(p, err);
                        continue;
                    };
                    try cases.append(case);
                },
            }
        }

        _ = p.eatToken(.r_brace) orelse {
            try p.warn(.missing_r_brace);
        };

        return p.addNode(.{
            .tag = .switch_expr,
            .main_token = switch_token,
            .data = .{
                .switch_expr = .{
                    .condition = condition,
                    .cases = try cases.toOwnedSlice(),
                },
            },
        });
    }

    /// Parse container with error recovery
    fn parseContainer(p: *Parse) !Node.Index {
        try p.recovery.pushContext(p, .container_members);
        defer p.recovery.popContext();

        var members = std.ArrayList(Node.Index).init(p.gpa);
        defer members.deinit();

        while (true) {
            switch (p.tokenTag(p.tok_i)) {
                .eof, .r_brace => break,
                else => {
                    // Try parse member with recovery
                    const member = p.parseContainerMember() catch |err| {
                        try p.recovery.recover(p, err);
                        continue;
                    };
                    try members.append(member);
                },
            }
        }

        return p.addNode(.{
            .tag = .container,
            .main_token = p.tok_i,
            .data = .{ .members = try members.toOwnedSlice() },
        });
    }

    /// Parse expression with error recovery
    fn parseExpr(p: *Parse) !Node.Index {
        try p.recovery.pushContext(p, .expr);
        defer p.recovery.popContext();

        return p.parseExprInner() catch |err| {
            try p.recovery.recover(p, err);
            
            // Return a placeholder node
            return p.addNode(.{
                .tag = .invalid_expr,
                .main_token = p.tok_i,
                .data = undefined,
            });
        };
    }

    /// Enhanced error reporting
    fn warnMsg(p: *Parse, msg: Diagnostic) !void {
        // ... existing warning logic ...
        
        // Add recovery context if available
        if (msg.extra == .recovery and p.recovery.context_stack.items.len > 0) {
            const ctx = p.recovery.context_stack.items[p.recovery.context_stack.items.len - 1];
            try p.diagnostics.append(.{
                .tag = .recovery_context,
                .token = msg.token,
                .extra = .{
                    .recovery_context = .{
                        .context = @tagName(ctx.kind),
                        .nesting_level = ctx.nesting_level,
                    },
                },
            });
        }
    }
};