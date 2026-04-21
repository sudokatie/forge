const std = @import("std");
const Allocator = std.mem.Allocator;
const Pointer = @import("pointer.zig").Pointer;
const http = @import("http.zig");

/// LFS API client for batch operations
pub const Client = struct {
    allocator: Allocator,
    /// Base URL for LFS API (e.g., "https://github.com/owner/repo.git/info/lfs")
    endpoint: []const u8,
    /// Optional auth token
    auth_token: ?[]const u8,

    const Self = @This();

    /// Initialize a new LFS client
    pub fn init(allocator: Allocator, endpoint: []const u8, auth_token: ?[]const u8) Self {
        return Self{
            .allocator = allocator,
            .endpoint = endpoint,
            .auth_token = auth_token,
        };
    }

    /// Object in a batch request
    pub const BatchObject = struct {
        oid: []const u8,
        size: u64,
    };

    /// Action returned in batch response
    pub const Action = struct {
        href: []const u8,
        header: ?std.StringHashMap([]const u8) = null,
        expires_in: ?i64 = null,
        expires_at: ?[]const u8 = null,
    };

    /// Object in a batch response
    pub const ResponseObject = struct {
        oid: []const u8,
        size: u64,
        authenticated: bool = false,
        actions: ?struct {
            download: ?Action = null,
            upload: ?Action = null,
            verify: ?Action = null,
        } = null,
        @"error": ?struct {
            code: i32,
            message: []const u8,
        } = null,
    };

    /// Batch response from LFS server
    pub const BatchResponse = struct {
        transfer: []const u8 = "basic",
        objects: []ResponseObject,
        hash_algo: []const u8 = "sha256",
    };

    /// Request download URLs for objects
    pub fn batchDownload(self: *Self, objects: []const BatchObject) !BatchResponse {
        return self.batch("download", objects);
    }

    /// Request upload URLs for objects
    pub fn batchUpload(self: *Self, objects: []const BatchObject) !BatchResponse {
        return self.batch("upload", objects);
    }

    /// Perform batch API request
    fn batch(self: *Self, operation: []const u8, objects: []const BatchObject) !BatchResponse {
        // Build request body
        var obj_list = std.ArrayListUnmanaged(http.BatchObjectInfo){};
        defer obj_list.deinit(self.allocator);

        for (objects) |obj| {
            try obj_list.append(self.allocator, .{ .oid = obj.oid, .size = obj.size });
        }

        const request_body = try http.buildBatchRequest(self.allocator, operation, obj_list.items);
        defer self.allocator.free(request_body);

        // Build URL
        const url = try std.fmt.allocPrint(self.allocator, "{s}/objects/batch", .{self.endpoint});
        defer self.allocator.free(url);

        // Set up headers
        var headers = http.Headers.init(self.allocator);
        defer headers.deinit();

        try headers.put("Content-Type", "application/vnd.git-lfs+json");
        try headers.put("Accept", "application/vnd.git-lfs+json");

        if (self.auth_token) |token| {
            const auth_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token});
            defer self.allocator.free(auth_value);
            try headers.put("Authorization", auth_value);
        }

        // Make HTTP request
        var client = http.HttpClient.init(self.allocator);
        var response = try client.httpPost(url, &headers, request_body);
        defer response.deinit();

        if (response.status_code != 200) {
            return error.BatchRequestFailed;
        }

        // Parse JSON response
        return try self.parseBatchResponse(response.body);
    }

    /// Parse batch API JSON response
    fn parseBatchResponse(self: *Self, body: []const u8) !BatchResponse {
        var parser = http.JsonParser.init(self.allocator, body);
        var json = try parser.parse();
        defer json.deinit(self.allocator);

        var response_objects = std.ArrayListUnmanaged(ResponseObject){};
        errdefer {
            for (response_objects.items) |*obj| {
                self.allocator.free(obj.oid);
                if (obj.actions) |*acts| {
                    if (acts.download) |*d| self.freeAction(d);
                    if (acts.upload) |*u| self.freeAction(u);
                    if (acts.verify) |*v| self.freeAction(v);
                }
            }
            response_objects.deinit(self.allocator);
        }

        const transfer = if (json.get("transfer")) |t| t.getString() orelse "basic" else "basic";
        const hash_algo = if (json.get("hash_algo")) |h| h.getString() orelse "sha256" else "sha256";

        if (json.get("objects")) |objects_val| {
            if (objects_val.getArray()) |objects_arr| {
                for (objects_arr) |obj| {
                    var resp_obj = ResponseObject{
                        .oid = try self.allocator.dupe(u8, obj.get("oid").?.getString().?),
                        .size = @intCast(obj.get("size").?.getNumber().?),
                        .authenticated = if (obj.get("authenticated")) |a| a.getBool() orelse false else false,
                        .actions = null,
                        .@"error" = null,
                    };

                    if (obj.get("actions")) |actions| {
                        resp_obj.actions = .{
                            .download = try self.parseAction(actions.get("download")),
                            .upload = try self.parseAction(actions.get("upload")),
                            .verify = try self.parseAction(actions.get("verify")),
                        };
                    }

                    try response_objects.append(self.allocator, resp_obj);
                }
            }
        }

        return BatchResponse{
            .transfer = try self.allocator.dupe(u8, transfer),
            .objects = try response_objects.toOwnedSlice(self.allocator),
            .hash_algo = try self.allocator.dupe(u8, hash_algo),
        };
    }

    /// Parse a single action from JSON
    fn parseAction(self: *Self, action_val: ?http.JsonParser.Value) !?Action {
        const action = action_val orelse return null;

        const href = action.get("href").?.getString() orelse return null;

        var header_map: ?std.StringHashMap([]const u8) = null;
        if (action.get("header")) |hdr_obj| {
            if (hdr_obj == .object) {
                header_map = std.StringHashMap([]const u8).init(self.allocator);
                var iter = hdr_obj.object.iterator();
                while (iter.next()) |entry| {
                    if (entry.value_ptr.getString()) |val| {
                        try header_map.?.put(
                            try self.allocator.dupe(u8, entry.key_ptr.*),
                            try self.allocator.dupe(u8, val),
                        );
                    }
                }
            }
        }

        return Action{
            .href = try self.allocator.dupe(u8, href),
            .header = header_map,
            .expires_in = if (action.get("expires_in")) |e| e.getNumber() else null,
            .expires_at = if (action.get("expires_at")) |e| blk: {
                if (e.getString()) |s| {
                    break :blk try self.allocator.dupe(u8, s);
                }
                break :blk null;
            } else null,
        };
    }

    /// Free an action's allocated memory
    fn freeAction(self: *Self, action: *Action) void {
        self.allocator.free(action.href);
        if (action.header) |*hdr| {
            var iter = hdr.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            hdr.deinit();
        }
        if (action.expires_at) |e| self.allocator.free(e);
    }

    /// Download object content from LFS server
    pub fn download(self: *Self, action: *const Action) ![]u8 {
        var headers = http.Headers.init(self.allocator);
        defer headers.deinit();

        // Add action-specific headers
        if (action.header) |action_headers| {
            var iter = action_headers.iterator();
            while (iter.next()) |entry| {
                try headers.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        // Add auth if available and not already in action headers
        if (self.auth_token) |token| {
            if (headers.get("Authorization") == null) {
                const auth_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token});
                defer self.allocator.free(auth_value);
                try headers.put("Authorization", auth_value);
            }
        }

        var client = http.HttpClient.init(self.allocator);
        var response = try client.httpGet(action.href, &headers);
        defer {
            response.headers.deinit();
            // Don't free body - we're returning it
        }

        if (response.status_code != 200) {
            self.allocator.free(response.body);
            return error.DownloadFailed;
        }

        return response.body;
    }

    /// Upload object content to LFS server
    pub fn upload(self: *Self, action: *const Action, content: []const u8) !void {
        var headers = http.Headers.init(self.allocator);
        defer headers.deinit();

        try headers.put("Content-Type", "application/octet-stream");

        // Add action-specific headers
        if (action.header) |action_headers| {
            var iter = action_headers.iterator();
            while (iter.next()) |entry| {
                try headers.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        // Add auth if available and not already in action headers
        if (self.auth_token) |token| {
            if (headers.get("Authorization") == null) {
                const auth_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token});
                defer self.allocator.free(auth_value);
                try headers.put("Authorization", auth_value);
            }
        }

        var client = http.HttpClient.init(self.allocator);
        var response = try client.httpPut(action.href, &headers, content);
        defer response.deinit();

        // Accept 200, 201, or 204 as success
        if (response.status_code != 200 and response.status_code != 201 and response.status_code != 204) {
            return error.UploadFailed;
        }
    }

    /// Verify upload with LFS server
    pub fn verify(self: *Self, action: *const Action, oid: []const u8, size: u64) !void {
        var headers = http.Headers.init(self.allocator);
        defer headers.deinit();

        try headers.put("Content-Type", "application/vnd.git-lfs+json");
        try headers.put("Accept", "application/vnd.git-lfs+json");

        // Add action-specific headers
        if (action.header) |action_headers| {
            var iter = action_headers.iterator();
            while (iter.next()) |entry| {
                try headers.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        if (self.auth_token) |token| {
            if (headers.get("Authorization") == null) {
                const auth_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token});
                defer self.allocator.free(auth_value);
                try headers.put("Authorization", auth_value);
            }
        }

        // Build verify request body
        const body = try std.fmt.allocPrint(self.allocator, "{{\"oid\":\"{s}\",\"size\":{d}}}", .{ oid, size });
        defer self.allocator.free(body);

        var client = http.HttpClient.init(self.allocator);
        var response = try client.httpPost(action.href, &headers, body);
        defer response.deinit();

        if (response.status_code != 200 and response.status_code != 204) {
            return error.VerifyFailed;
        }
    }

    /// Free a BatchResponse
    pub fn freeBatchResponse(self: *Self, response: *BatchResponse) void {
        self.allocator.free(response.transfer);
        self.allocator.free(response.hash_algo);
        for (response.objects) |*obj| {
            self.allocator.free(obj.oid);
            if (obj.actions) |*acts| {
                if (acts.download) |*d| self.freeAction(@constCast(d));
                if (acts.upload) |*u| self.freeAction(@constCast(u));
                if (acts.verify) |*v| self.freeAction(@constCast(v));
            }
        }
        self.allocator.free(response.objects);
    }

    /// Derive LFS endpoint from git remote URL
    pub fn endpointFromRemote(allocator: Allocator, remote_url: []const u8) ![]u8 {
        // Remove .git suffix if present, then add /info/lfs
        var url = remote_url;
        if (std.mem.endsWith(u8, url, ".git")) {
            url = url[0 .. url.len - 4];
        }
        return std.fmt.allocPrint(allocator, "{s}.git/info/lfs", .{url});
    }
};

/// LFS object storage for local cache
pub const ObjectStore = struct {
    allocator: Allocator,
    /// Path to .git/lfs/objects directory
    objects_dir: []const u8,

    const Self = @This();

    /// Initialize object store
    pub fn init(allocator: Allocator, git_dir: []const u8) !Self {
        const objects_dir = try std.fs.path.join(allocator, &.{ git_dir, "lfs", "objects" });
        return Self{
            .allocator = allocator,
            .objects_dir = objects_dir,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.objects_dir);
    }

    /// Get path to object file (creates directories if needed)
    pub fn objectPath(self: *const Self, oid: []const u8) ![]u8 {
        if (oid.len != 64) return error.InvalidOid;

        // LFS stores objects in subdirectories: objects/ab/cd/abcdef...
        const dir1 = oid[0..2];
        const dir2 = oid[2..4];

        return std.fs.path.join(self.allocator, &.{ self.objects_dir, dir1, dir2, oid });
    }

    /// Check if object exists in local store
    pub fn hasObject(self: *const Self, oid: []const u8) bool {
        const path = self.objectPath(oid) catch return false;
        defer self.allocator.free(path);

        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }

    /// Read object from local store
    pub fn readObject(self: *const Self, oid: []const u8) ![]u8 {
        const path = try self.objectPath(oid);
        defer self.allocator.free(path);

        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();

        return file.readToEndAlloc(self.allocator, std.math.maxInt(usize));
    }

    /// Write object to local store
    pub fn writeObject(self: *const Self, oid: []const u8, content: []const u8) !void {
        const path = try self.objectPath(oid);
        defer self.allocator.free(path);

        // Ensure parent directories exist
        const dir = std.fs.path.dirname(path) orelse return error.InvalidPath;
        std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Write atomically by writing to temp then renaming
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(tmp_path);

        const file = try std.fs.createFileAbsolute(tmp_path, .{});
        defer file.close();

        try file.writeAll(content);
        try std.fs.renameAbsolute(tmp_path, path);
    }
};

// Tests
test "endpointFromRemote - HTTPS with .git" {
    const allocator = std.testing.allocator;
    const endpoint = try Client.endpointFromRemote(allocator, "https://github.com/owner/repo.git");
    defer allocator.free(endpoint);
    try std.testing.expectEqualStrings("https://github.com/owner/repo.git/info/lfs", endpoint);
}

test "endpointFromRemote - HTTPS without .git" {
    const allocator = std.testing.allocator;
    const endpoint = try Client.endpointFromRemote(allocator, "https://github.com/owner/repo");
    defer allocator.free(endpoint);
    try std.testing.expectEqualStrings("https://github.com/owner/repo.git/info/lfs", endpoint);
}

test "objectPath format" {
    const allocator = std.testing.allocator;
    var store = try ObjectStore.init(allocator, "/repo/.git");
    defer store.deinit();

    const oid = "4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393";
    const path = try store.objectPath(oid);
    defer allocator.free(path);

    try std.testing.expectEqualStrings(
        "/repo/.git/lfs/objects/4d/7a/4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393",
        path,
    );
}

test "objectPath invalid oid" {
    const allocator = std.testing.allocator;
    var store = try ObjectStore.init(allocator, "/repo/.git");
    defer store.deinit();

    try std.testing.expectError(error.InvalidOid, store.objectPath("short"));
}
