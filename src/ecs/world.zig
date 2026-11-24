//! Bounded archetype ECS. Component values are shallow, non-owning Zig values.
//! World/command-buffer owners are noncopyable by convention; no escaped views.
const std = @import("std");
const SlotMap = @import("../memory/slot_map.zig").SlotMap;

pub const Mask = u64;
const Location = struct { archetype: usize, row: usize };
const Directory = SlotMap(Location);
pub const Entity = Directory.Handle;
pub const ArchetypeConfig = struct { mask: Mask, capacity: usize };
pub const MutationError = error{
    QueryActive,
    InvalidEntity,
    MissingComponent,
    AlreadyPresent,
    MissingArchetype,
    ArchetypeFull,
    EntityCapacity,
};
pub const ConfigError = error{ UnknownComponent, DuplicateArchetype, InvalidDomain, CapacityOverflow };

fn bit(i: usize) Mask {
    return @as(Mask, 1) << @as(u6, @intCast(i));
}
fn maskForCount(n: usize) Mask {
    return if (n == 64) std.math.maxInt(Mask) else if (n == 0) 0 else bit(n) - 1;
}
fn equalEntity(a: Entity, b: Entity) bool {
    return a.domain == b.domain and a.index == b.index and a.generation == b.generation;
}

/// Fixed registry (1..64 distinct, nonzero-sized component types). Explicitly
/// configured archetypes allocate only their present columns during init.
/// No structural operations allocate after init. Masks are local to registry order.
pub fn World(comptime components: []const type) type {
    if (components.len == 0 or components.len > 64) @compileError("ECS registry must contain 1..64 types");
    var max_payload: usize = 0;
    for (components, 0..) |T, i| {
        max_payload = std.math.add(usize, max_payload, @sizeOf(T)) catch @compileError("ECS component payload size overflow");
        if (@sizeOf(T) == 0) @compileError("ECS MVP requires nonzero-sized component types");
        for (components[0..i]) |U| if (T == U) @compileError("duplicate component type");
    }
    const registry_mask = maskForCount(components.len);
    return struct {
        const Self = @This();
        pub const EntityId = Entity;
        pub const component_count = components.len;
        pub const all_components = registry_mask;

        const Archetype = struct {
            mask: Mask,
            ids: []Entity,
            columns: [components.len]?[*]u8 = @splat(null),
            len: usize = 0,

            fn init(a: std.mem.Allocator, config: ArchetypeConfig) !Archetype {
                var self: Archetype = .{ .mask = config.mask, .ids = try a.alloc(Entity, config.capacity) };
                errdefer self.deinit(a);
                inline for (components, 0..) |T, i| {
                    if ((config.mask & bit(i)) != 0) {
                        const col = try a.alloc(T, config.capacity);
                        self.columns[i] = @ptrCast(col.ptr);
                    }
                }
                return self;
            }
            fn deinit(self: *Archetype, a: std.mem.Allocator) void {
                inline for (components, 0..) |T, i| {
                    if (self.columns[i]) |raw| {
                        const typed: [*]T = @ptrCast(@alignCast(raw));
                        a.free(typed[0..self.ids.len]);
                    }
                }
                a.free(self.ids);
                self.* = undefined;
            }
            fn column(self: *const Archetype, comptime T: type) []T {
                const idx = componentIndex(T);
                // Only called after membership is checked, or from a matching query.
                const typed: [*]T = @ptrCast(@alignCast(self.columns[idx].?));
                return typed[0..self.ids.len];
            }
            fn full(self: *const Archetype) bool {
                return self.len == self.ids.len;
            }
        };

        allocator: std.mem.Allocator,
        directory: Directory,
        archetypes: []Archetype,
        query_active: bool = false,

        pub fn componentIndex(comptime T: type) usize {
            inline for (components, 0..) |U, i| if (comptime T == U) return i;
            @compileError("component is not registered: " ++ @typeName(T));
        }
        pub fn mask(comptime types: []const type) Mask {
            return comptime blk: {
                var m: Mask = 0;
                for (types) |T| {
                    const b = bit(componentIndex(T));
                    if ((m & b) != 0) @compileError("duplicate component in set");
                    m |= b;
                }
                break :blk m;
            };
        }
        fn valueMask(comptime values_type: type) Mask {
            // This accepts an anonymous tuple of already typed values, not an
            // anonymous struct with untyped numeric literals.
            const info = switch (@typeInfo(values_type)) {
                .@"struct" => |s| s,
                else => @compileError("expected tuple of component values"),
            };
            if (!info.is_tuple and info.field_types.len != 0) @compileError("expected tuple of component values");
            return mask(info.field_types);
        }
        pub fn init(a: std.mem.Allocator, entity_capacity: usize, world_domain: u64, configs: []const ArchetypeConfig) !Self {
            for (configs, 0..) |config, i| {
                if ((config.mask & ~registry_mask) != 0) return error.UnknownComponent;
                for (configs[0..i]) |previous| if (previous.mask == config.mask) return error.DuplicateArchetype;
            }
            var directory = try Directory.init(a, entity_capacity, world_domain);
            errdefer directory.deinit();
            const archetypes = try a.alloc(Archetype, configs.len);
            errdefer a.free(archetypes);
            var initialized: usize = 0;
            errdefer {
                for (archetypes[0..initialized]) |*arch| arch.deinit(a);
            }
            for (configs, 0..) |config, i| {
                archetypes[i] = try Archetype.init(a, config);
                initialized += 1;
            }
            return .{ .allocator = a, .directory = directory, .archetypes = archetypes };
        }
        pub fn deinit(self: *Self) error{QueryActive}!void {
            if (self.query_active) return error.QueryActive;
            for (self.archetypes) |*arch| arch.deinit(self.allocator);
            self.allocator.free(self.archetypes);
            self.directory.deinit();
            self.* = undefined;
        }
        pub fn domain(self: *const Self) u64 {
            return self.directory.domain;
        }
        pub fn count(self: *const Self) usize {
            return self.directory.count();
        }
        pub fn contains(self: *const Self, e: Entity) bool {
            return self.directory.contains(e);
        }
        pub fn archetypeCount(self: *const Self) usize {
            return self.archetypes.len;
        }
        pub fn countIn(self: *const Self, signature_mask: Mask) ?usize {
            const i = self.find(signature_mask) orelse return null;
            return self.archetypes[i].len;
        }
        fn find(self: *const Self, signature_mask: Mask) ?usize {
            for (self.archetypes, 0..) |arch, i| if (arch.mask == signature_mask) return i;
            return null;
        }
        fn checkIdle(self: *const Self) MutationError!void {
            if (self.query_active) return error.QueryActive;
        }
        fn location(self: *const Self, e: Entity) MutationError!Location {
            return self.directory.get(e) orelse return error.InvalidEntity;
        }
        pub fn signature(self: *const Self, e: Entity) MutationError!Mask {
            try self.checkIdle();
            return self.archetypes[(try self.location(e)).archetype].mask;
        }
        pub fn get(self: *const Self, e: Entity, comptime T: type) MutationError!T {
            try self.checkIdle();
            const loc = try self.location(e);
            const arch = &self.archetypes[loc.archetype];
            if ((arch.mask & bit(componentIndex(T))) == 0) return error.MissingComponent;
            return arch.column(T)[loc.row];
        }
        pub fn set(self: *Self, e: Entity, value: anytype) MutationError!void {
            try self.checkIdle();
            const T = @TypeOf(value);
            const loc = try self.location(e);
            const arch = &self.archetypes[loc.archetype];
            if ((arch.mask & bit(componentIndex(T))) == 0) return error.MissingComponent;
            arch.column(T)[loc.row] = value;
        }
        fn spawnAt(self: *Self, signature_mask: Mask) MutationError!struct { entity: Entity, loc: Location } {
            try self.checkIdle();
            const idx = self.find(signature_mask) orelse return error.MissingArchetype;
            const arch = &self.archetypes[idx];
            if (arch.full()) return error.ArchetypeFull;
            const loc: Location = .{ .archetype = idx, .row = arch.len };
            const e = self.directory.insert(loc) catch return error.EntityCapacity;
            arch.ids[loc.row] = e;
            arch.len += 1;
            // Every caller initializes all present components without fallible
            // operations before returning control to application code.
            return .{ .entity = e, .loc = loc };
        }
        pub fn spawn(self: *Self, values: anytype) MutationError!Entity {
            const m = comptime valueMask(@TypeOf(values));
            const placement = try self.spawnAt(m);
            const arch = &self.archetypes[placement.loc.archetype];
            inline for (values) |v| arch.column(@TypeOf(v))[placement.loc.row] = v;
            return placement.entity;
        }
        fn eraseRow(self: *Self, loc: Location) void {
            const arch = &self.archetypes[loc.archetype];
            const last = arch.len - 1;
            if (loc.row != last) {
                const moved = arch.ids[last];
                arch.ids[loc.row] = moved;
                inline for (components, 0..) |T, i| {
                    if ((arch.mask & bit(i)) != 0) {
                        const col = arch.column(T);
                        col[loc.row] = col[last];
                    }
                }
                if (!self.directory.set(moved, loc)) unreachable; // internal invariant
            }
            arch.len -= 1;
        }
        pub fn despawn(self: *Self, e: Entity) MutationError!void {
            try self.checkIdle();
            const loc = try self.location(e);
            self.eraseRow(loc);
            if (self.directory.remove(e) == null) unreachable;
        }
        /// Preflight all fallible conditions before copying; identity remains stable.
        /// The caller initializes any newly introduced column before returning.
        fn migrate(self: *Self, e: Entity, old: Location, destination: Mask) MutationError!Location {
            const idx = self.find(destination) orelse return error.MissingArchetype;
            const from = &self.archetypes[old.archetype];
            const to = &self.archetypes[idx];
            if (to.full()) return error.ArchetypeFull;
            const row = to.len;
            inline for (components, 0..) |T, i| {
                if (((from.mask & to.mask) & bit(i)) != 0) {
                    to.column(T)[row] = from.column(T)[old.row];
                }
            }
            to.ids[row] = e;
            to.len += 1;
            const loc: Location = .{ .archetype = idx, .row = row };
            if (!self.directory.set(e, loc)) unreachable;
            self.eraseRow(old);
            return loc;
        }
        pub fn add(self: *Self, e: Entity, value: anytype) MutationError!void {
            try self.checkIdle();
            const T = @TypeOf(value);
            const old = try self.location(e);
            const before = self.archetypes[old.archetype].mask;
            const b = bit(componentIndex(T));
            if ((before & b) != 0) return error.AlreadyPresent;
            const loc = try self.migrate(e, old, before | b);
            self.archetypes[loc.archetype].column(T)[loc.row] = value;
        }
        pub fn remove(self: *Self, e: Entity, comptime T: type) MutationError!void {
            try self.checkIdle();
            const old = try self.location(e);
            const before = self.archetypes[old.archetype].mask;
            const b = bit(componentIndex(T));
            if ((before & b) == 0) return error.MissingComponent;
            _ = try self.migrate(e, old, before & ~b);
        }

        /// Query chunk views borrow columns only for the callback. Zig does not
        /// enforce nonescape: retaining pointers/slices outside it violates API.
        pub fn Chunk(comptime reads: []const type, comptime writes: []const type) type {
            const rm = comptime mask(reads);
            const wm = comptime mask(writes);
            if ((rm & wm) != 0) @compileError("read/write query sets must be disjoint");
            return struct {
                const C = @This();
                arch: *Archetype,
                pub fn ids(self: C) []const Entity {
                    return self.arch.ids[0..self.arch.len];
                }
                pub fn count(self: C) usize {
                    return self.arch.len;
                }
                pub fn read(self: C, comptime T: type) []const T {
                    if (comptime ((rm | wm) & bit(componentIndex(T))) == 0) @compileError("component not declared by query");
                    return self.arch.column(T)[0..self.arch.len];
                }
                pub fn write(self: C, comptime T: type) []T {
                    if (comptime (wm & bit(componentIndex(T))) == 0) @compileError("component not declared writable");
                    return self.arch.column(T)[0..self.arch.len];
                }
            };
        }
        /// Sequential traversal in configuration order; rows may change at the
        /// next structural barrier. Callbacks return an error union with void.
        /// The guard is released on error. Prior writes are not rolled back.
        pub fn forEach(self: *Self, comptime reads: []const type, comptime writes: []const type, comptime without: []const type, context: anytype, comptime callback: anytype) !void {
            const C = Chunk(reads, writes);
            const required = comptime (mask(reads) | mask(writes));
            const forbidden = comptime mask(without);
            if ((required & forbidden) != 0) @compileError("required and forbidden components overlap");
            try self.checkIdle();
            self.query_active = true;
            defer self.query_active = false;
            for (self.archetypes) |*arch| {
                if (arch.len != 0 and (arch.mask & required) == required and (arch.mask & forbidden) == 0) {
                    try callback(context, C{ .arch = arch });
                }
            }
        }

        /// O(archetypes + live entities + directory capacity) invariant audit.
        /// Checks both directions of row-directory correspondence.
        pub fn validate(self: *const Self) bool {
            if (self.query_active) return false;
            var total: usize = 0;
            for (self.archetypes, 0..) |arch, ai| {
                if (arch.len > arch.ids.len) return false;
                total += arch.len;
                for (arch.ids[0..arch.len], 0..) |e, row| {
                    const loc = self.directory.get(e) orelse return false;
                    if (loc.archetype != ai or loc.row != row) return false;
                }
            }
            if (total != self.count()) return false;
            var cursor: usize = 0;
            while (self.directory.next(&cursor)) |entry| {
                const loc = entry.value;
                if (loc.archetype >= self.archetypes.len) return false;
                const arch = &self.archetypes[loc.archetype];
                if (loc.row >= arch.len or !equalEntity(arch.ids[loc.row], entry.handle)) return false;
            }
            return true;
        }

        // Command payloads are PRIVATE IN-PROCESS shallow value copies, NOT
        // persistent binary formats. memcpy avoids misaligned typed loads.
        fn payloadSize(m: Mask) usize {
            var size: usize = 0;
            inline for (components, 0..) |T, i| {
                if ((m & bit(i)) != 0) size += @sizeOf(T);
            }
            return size;
        }
        fn copyIn(comptime T: type, dest: []u8, value: T) void {
            const bytes: *const [@sizeOf(T)]u8 = @ptrCast(&value);
            @memcpy(dest[0..@sizeOf(T)], bytes);
        }
        fn copyOut(comptime T: type, source: []const u8) T {
            var value: T = undefined;
            const bytes: *[@sizeOf(T)]u8 = @ptrCast(&value);
            @memcpy(bytes, source[0..@sizeOf(T)]);
            return value;
        }
        fn spawnFromBytes(self: *Self, m: Mask, bytes: []const u8) MutationError!Entity {
            const p = try self.spawnAt(m);
            var offset: usize = 0;
            inline for (components, 0..) |T, i| {
                if ((m & bit(i)) != 0) {
                    self.archetypes[p.loc.archetype].column(T)[p.loc.row] = copyOut(T, bytes[offset..]);
                    offset += @sizeOf(T);
                }
            }
            return p.entity;
        }

        pub const CommandBuffer = struct {
            const Buffer = @This();
            const Kind = enum { spawn, add, remove, despawn };
            const Command = struct { kind: Kind, entity: ?Entity, mask: Mask, offset: usize, size: usize };
            pub const Failure = struct { index: usize, reason: MutationError };
            pub const Report = struct {
                applied: usize = 0,
                rejected: usize = 0,
                spawned: usize = 0,
                first_failure: ?Failure = null,
            };
            pub const QueueError = error{ CommandCapacity, PayloadCapacity, WrongDomain };
            allocator: std.mem.Allocator,
            entries: []Command,
            bytes: []u8,
            owner_domain: u64,
            len: usize = 0,
            used: usize = 0,

            pub fn init(a: std.mem.Allocator, owner_domain: u64, command_capacity: usize, payload_capacity: usize) !Buffer {
                if (owner_domain == 0) return error.InvalidDomain;
                const entries = try a.alloc(Command, command_capacity);
                errdefer a.free(entries);
                return .{ .allocator = a, .entries = entries, .bytes = try a.alloc(u8, payload_capacity), .owner_domain = owner_domain };
            }
            pub fn deinit(self: *Buffer) void {
                self.allocator.free(self.bytes);
                self.allocator.free(self.entries);
                self.* = undefined;
            }
            pub fn clear(self: *Buffer) void {
                self.len = 0;
                self.used = 0;
            }
            pub fn count(self: *const Buffer) usize {
                return self.len;
            }
            pub fn payloadUsed(self: *const Buffer) usize {
                return self.used;
            }
            fn reserve(self: *Buffer, kind: Kind, entity: ?Entity, m: Mask, n: usize) QueueError![]u8 {
                if (entity) |e| if (e.domain != self.owner_domain) return error.WrongDomain;
                if (self.len == self.entries.len) return error.CommandCapacity;
                if (n > self.bytes.len - self.used) return error.PayloadCapacity;
                const start = self.used;
                self.entries[self.len] = .{ .kind = kind, .entity = entity, .mask = m, .offset = start, .size = n };
                self.len += 1;
                self.used += n;
                return self.bytes[start..self.used];
            }
            /// Spawn IDs are assigned at flush time; report counts successful
            /// spawns, but no same-batch references to newly spawned IDs in v0.2.
            pub fn spawn(self: *Buffer, values: anytype) QueueError!void {
                const m = comptime valueMask(@TypeOf(values));
                const bytes = try self.reserve(.spawn, null, m, payloadSize(m));
                // Encode in registry order, independent of input tuple order.
                inline for (components, 0..) |T, i| {
                    if (comptime (m & bit(i)) != 0) {
                        const offset = comptime payloadSize(m & (bit(i) - 1));
                        inline for (values) |v| {
                            if (comptime @TypeOf(v) == T) copyIn(T, bytes[offset..], v);
                        }
                    }
                }
            }
            pub fn add(self: *Buffer, e: Entity, value: anytype) QueueError!void {
                const T = @TypeOf(value);
                const bytes = try self.reserve(.add, e, bit(componentIndex(T)), @sizeOf(T));
                copyIn(T, bytes, value);
            }
            pub fn remove(self: *Buffer, e: Entity, comptime T: type) QueueError!void {
                _ = try self.reserve(.remove, e, bit(componentIndex(T)), 0);
            }
            pub fn despawn(self: *Buffer, e: Entity) QueueError!void {
                _ = try self.reserve(.despawn, e, 0, 0);
            }
            fn apply(world: *Self, cmd: Command, bytes: []const u8) MutationError!void {
                switch (cmd.kind) {
                    .spawn => {
                        _ = try world.spawnFromBytes(cmd.mask, bytes);
                    },
                    .despawn => try world.despawn(cmd.entity.?),
                    .add => {
                        inline for (components, 0..) |T, i| {
                            if (cmd.mask == bit(i)) return world.add(cmd.entity.?, copyOut(T, bytes));
                        }
                        unreachable;
                    },
                    .remove => {
                        inline for (components, 0..) |T, i| {
                            if (cmd.mask == bit(i)) return world.remove(cmd.entity.?, T);
                        }
                        unreachable;
                    },
                }
            }
            /// Deterministic FIFO, best-effort per-command transaction. Rejects
            /// a stale or impossible command without modifying that entity and
            /// continues. Wrong-world/active-query errors preserve the queue.
            pub fn flush(self: *Buffer, world: *Self) error{ WrongDomain, QueryActive }!Report {
                if (world.domain() != self.owner_domain) return error.WrongDomain;
                if (world.query_active) return error.QueryActive;
                var report: Report = .{};
                for (self.entries[0..self.len], 0..) |cmd, index| {
                    apply(world, cmd, self.bytes[cmd.offset..][0..cmd.size]) catch |reason| {
                        report.rejected += 1;
                        if (report.first_failure == null) report.first_failure = .{ .index = index, .reason = reason };
                        continue;
                    };
                    report.applied += 1;
                    if (cmd.kind == .spawn) report.spawned += 1;
                }
                self.clear();
                return report;
            }
        };
    };
}
