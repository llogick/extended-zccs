const std = @import("std");
const Allocator = std.mem.Allocator;
const Token = @import("tokenizer.zig").Token;
const TokenIndex = u32;
const Parse = @import("Parse.zig").Parse;

/// Represents different kinds of parse contexts where errors can occur
pub const RecoveryContext = enum {
    // Container level
    container_members,
    container_decl,
    container_field,
    
    // Declaration level
    function_decl,
    var_decl,
    test_decl,
    
    // Statement level
    block_stmt,
    if_stmt,
    while_stmt,
    for_stmt,
    switch_stmt,
    
    // Expression level
    expr,
    assign_expr,
    binary_expr,
    prefix_expr,
    primary_expr,
    
    // Type level
    type_expr,
    error_union,
    pointer_type,
    array_type,
};

/// Recovery synchronization points for each context
pub const SyncPoints = struct {
    /// Token patterns that indicate valid recovery points
    patterns: []const []const Token.Tag,
    
    /// Minimum required token sequence length to consider recovery
    min_length: usize = 1,
    
    /// Whether to require balanced delimiters
    need_balanced: bool = false,
    
    /// Custom validation function for potential sync points
    validator: ?*const fn(p: *Parse, tok: TokenIndex) bool = null,
};

/// Recovery state tracking and management
pub const RecoveryState = struct {
    /// Enhanced context tracking with nesting
    const Context = struct {
        kind: RecoveryContext,
        start_token: TokenIndex,
        indent: u16,
        /// Track parent context for nested structures
        parent_kind: ?RecoveryContext,
        /// Nested level for similar contexts (e.g. nested switches)
        nesting_level: u32,
    };

    /// Stack of recovery contexts with nesting information
    context_stack: std.ArrayList(Context),
    
    /// Tracks delimiter balance
    delimiter_balance: struct {
        paren: isize = 0,
        brace: isize = 0,
        bracket: isize = 0,
        
        fn isBalanced(self: @This()) bool {
            return self.paren == 0 and 
                   self.brace == 0 and 
                   self.bracket == 0;
        }
        
        fn update(self: *@This(), tag: Token.Tag) void {
            switch (tag) {
                .l_paren => self.paren += 1,
                .r_paren => self.paren -= 1,
                .l_brace => self.brace += 1,
                .r_brace => self.brace -= 1,
                .l_bracket => self.bracket += 1,
                .r_bracket => self.bracket -= 1,
                else => {},
            }
        }
    } = .{},

    /// Recovery attempts per token to prevent loops
    recovery_attempts: std.AutoHashMap(TokenIndex, u32),

    /// Maximum recovery attempts per token before giving up
    const max_attempts = 3;

    pub fn init(allocator: Allocator) RecoveryState {
        return .{
            .context_stack = std.ArrayList(Context).init(allocator),
            .recovery_attempts = std.AutoHashMap(TokenIndex, u32).init(allocator),
        };
    }

    pub fn deinit(self: *RecoveryState) void {
        self.context_stack.deinit();
        self.recovery_attempts.deinit();
    }

    /// Get the nearest parent context of a specific kind
    fn findParentContext(self: *RecoveryState, kind: RecoveryContext) ?*const Context {
        var i: isize = @intCast(self.context_stack.items.len - 1);
        while (i >= 0) : (i -= 1) {
            if (self.context_stack.items[@intCast(i)].kind == kind) {
                return &self.context_stack.items[@intCast(i)];
            }
        }
        return null;
    }

    /// Count how deeply nested we are in a specific context type
    fn getNestingLevel(self: *RecoveryState, kind: RecoveryContext) u32 {
        var level: u32 = 0;
        for (self.context_stack.items) |ctx| {
            if (ctx.kind == kind) level += 1;
        }
        return level;
    }

    /// Push context with nesting information
    pub fn pushContext(self: *RecoveryState, p: *Parse, kind: RecoveryContext) !void {
        const parent_kind = if (self.context_stack.items.len > 0)
            self.context_stack.items[self.context_stack.items.len - 1].kind
        else
            null;

        try self.context_stack.append(.{
            .kind = kind,
            .start_token = p.tok_i,
            .indent = p.tokens.items(.indent)[p.tok_i],
            .parent_kind = parent_kind,
            .nesting_level = self.getNestingLevel(kind),
        });
    }

    /// Pop current context
    pub fn popContext(self: *RecoveryState) void {
        _ = self.context_stack.pop();
    }

    /// Enhanced sync point finding with nesting awareness
    pub fn findSyncPoint(self: *RecoveryState, p: *Parse) !?TokenIndex {
        const current = &self.context_stack.items[self.context_stack.items.len - 1];
        const patterns = sync_patterns.get(@tagName(current.kind)) orelse return null;

        var tok = p.tok_i;
        var local_balance = self.delimiter_balance;
        var nesting_level = current.nesting_level;

        while (tok < p.tokens.len) : (tok += 1) {
            const tag = p.tokenTag(tok);
            
            // Track nesting of contexts
            switch (tag) {
                .keyword_switch => {
                    if (current.kind == .switch_stmt) {
                        nesting_level += 1;
                    }
                },
                .r_brace => {
                    if (nesting_level > 0) {
                        nesting_level -= 1;
                        continue;
                    }
                },
                else => {},
            }

            // Update delimiter balance
            local_balance.update(tag);

            // Only consider sync points at correct nesting level
            if (nesting_level > current.nesting_level) continue;

            for (patterns.patterns) |pattern| {
                if (self.matchesPatternWithContext(p, tok, pattern, current)) {
                    // Verify minimum sequence length
                    if (tok - p.tok_i < patterns.min_length) continue;

                    // Check delimiter balance if required
                    if (patterns.need_balanced and !local_balance.isBalanced()) continue;

                    // Run custom validator if any
                    if (patterns.validator) |validate| {
                        if (!validate(p, tok)) continue;
                    }

                    return tok;
                }
            }
        }
        return null;
    }

    /// Enhanced pattern matching with context awareness
    fn matchesPatternWithContext(
        self: *RecoveryState,
        p: *Parse,
        tok: TokenIndex,
        pattern: []const Token.Tag,
        context: *const Context,
    ) bool {
        // Basic pattern matching
        if (!matchesPattern(p, tok, pattern)) return false;

        // Context-specific validation
        switch (context.kind) {
            .switch_stmt => {
                // For switch arms, verify indentation matches the switch
                if (pattern[0] == .equal_angle_bracket_right) {
                    const arm_indent = p.tokens.items(.indent)[tok];
                    if (arm_indent < context.indent) return false;
                }
            },
            .block_stmt => {
                // For blocks, check statement boundaries
                if (pattern[0] == .semicolon) {
                    const stmt_indent = p.tokens.items(.indent)[tok];
                    if (stmt_indent < context.indent) return false;
                }
            },
            else => {},
        }
        return true;
    }

    /// Basic token pattern matching
    fn matchesPattern(p: *Parse, start_idx: TokenIndex, pattern: []const Token.Tag) bool {
        if (start_idx + pattern.len > p.tokens.len) return false;
        
        for (pattern, 0..) |tag, i| {
            if (p.tokenTag(start_idx + i) != tag) return false;
        }
        return true;
    }

    /// Attempt recovery at current error position
    pub fn recover(self: *RecoveryState, p: *Parse, err: anytype) !void {
        // Track recovery attempts
        const gop = try self.recovery_attempts.getOrPut(p.tok_i);
        if (!gop.found_existing) {
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += 1;

        // Too many attempts at this position? Give up
        if (gop.value_ptr.* > max_attempts) return err;

        // Find sync point
        if (try self.findSyncPoint(p)) |sync_tok| {
            // Log recovery attempt
            try p.warnMsg(.{
                .tag = .recovery_attempted,
                .token = p.tok_i,
                .extra = .{
                    .recovery = .{
                        .context = @tagName(self.context_stack.items[self.context_stack.items.len - 1].kind),
                        .distance = sync_tok - p.tok_i,
                    },
                },
            });

            // Skip to sync point
            p.tok_i = sync_tok;
            return;
        }

        // No sync point found - propagate error
        return err;
    }
};

/// Sync point patterns for different contexts
pub const sync_patterns = std.ComptimeStringMap(SyncPoints, .{
    .{ "container_members", .{
        .patterns = &[_][]const Token.Tag{
            &[_]{ .keyword_fn },
            &[_]{ .keyword_const },
            &[_]{ .keyword_var },
            &[_]{ .keyword_test },
            &[_]{ .keyword_pub },
            &[_]{ .identifier, .colon }, // Container field
        },
    }},
    
    .{ "block_stmt", .{
        .patterns = &[_][]const Token.Tag{
            &[_]{ .semicolon },
            &[_]{ .r_brace },
            &[_]{ .keyword_const },
            &[_]{ .keyword_var },
            &[_]{ .keyword_if },
            &[_]{ .keyword_while },
            &[_]{ .keyword_for },
            &[_]{ .keyword_return },
        },
        .need_balanced = true,
    }},
    
    .{ "switch_stmt", .{
        .patterns = &[_][]const Token.Tag{
            &[_]{ .equal_angle_bracket_right },
            &[_]{ .keyword_else },
            &[_]{ .r_brace },
        },
        .min_length = 2,
    }},
    
    .{ "expr", .{
        .patterns = &[_][]const Token.Tag{
            &[_]{ .semicolon },
            &[_]{ .comma },
            &[_]{ .r_paren },
            &[_]{ .r_brace },
            &[_]{ .r_bracket },
            &[_]{ .equal },
        },
    }},
});
