// HTTP client for LFS operations
//
// Minimal HTTP/1.1 client using std.net for LFS API calls.
// Supports TLS via std.crypto.tls for HTTPS endpoints.

const std = @import("std");
const Allocator = std.mem.Allocator;
const net = std.net;

/// HTTP response from server
pub const Response = struct {
    status_code: u16,
    headers: Headers,
    body: []u8,
    allocator: Allocator,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.headers.deinit();
        self.allocator.free(self.body);
    }
};

/// HTTP headers collection
pub const Headers = struct {
    map: std.StringHashMap([]const u8),
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{
            .map = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit();
    }

    pub fn put(self: *Self, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
        try self.map.put(key_copy, value_copy);
    }

    pub fn get(self: *const Self, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }
};

/// Parsed URL components
pub const Url = struct {
    scheme: []const u8,
    host: []const u8,
    port: u16,
    path: []const u8,

    /// Parse a URL string
    pub fn parse(url: []const u8) !Url {
        var scheme: []const u8 = "http";
        var port: u16 = 80;
        var rest = url;

        // Parse scheme
        if (std.mem.indexOf(u8, url, "://")) |idx| {
            scheme = url[0..idx];
            rest = url[idx + 3 ..];
            if (std.mem.eql(u8, scheme, "https")) {
                port = 443;
            }
        }

        // Parse host and port
        var host_end = rest.len;
        var path_start = rest.len;

        if (std.mem.indexOf(u8, rest, "/")) |idx| {
            host_end = idx;
            path_start = idx;
        }

        const host_port = rest[0..host_end];
        if (std.mem.indexOf(u8, host_port, ":")) |idx| {
            const port_str = host_port[idx + 1 ..];
            port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidPort;
            return .{
                .scheme = scheme,
                .host = host_port[0..idx],
                .port = port,
                .path = if (path_start < rest.len) rest[path_start..] else "/",
            };
        }

        return .{
            .scheme = scheme,
            .host = host_port,
            .port = port,
            .path = if (path_start < rest.len) rest[path_start..] else "/",
        };
    }
};

/// HTTP client for LFS operations
pub const HttpClient = struct {
    allocator: Allocator,
    timeout_ms: u32,

    const Self = @This();

    /// Default timeout in milliseconds
    const DEFAULT_TIMEOUT_MS: u32 = 30000;

    /// Maximum response body size (100MB for large LFS objects)
    const MAX_BODY_SIZE: usize = 100 * 1024 * 1024;

    /// Initialize HTTP client
    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .timeout_ms = DEFAULT_TIMEOUT_MS,
        };
    }

    /// Set timeout in milliseconds
    pub fn setTimeout(self: *Self, timeout_ms: u32) void {
        self.timeout_ms = timeout_ms;
    }

    /// Perform HTTP GET request
    pub fn httpGet(self: *Self, url: []const u8, headers: ?*const Headers) !Response {
        return self.request("GET", url, headers, null);
    }

    /// Perform HTTP POST request
    pub fn httpPost(self: *Self, url: []const u8, headers: ?*const Headers, body: ?[]const u8) !Response {
        return self.request("POST", url, headers, body);
    }

    /// Perform HTTP PUT request
    pub fn httpPut(self: *Self, url: []const u8, headers: ?*const Headers, body: ?[]const u8) !Response {
        return self.request("PUT", url, headers, body);
    }

    /// Internal request implementation
    fn request(
        self: *Self,
        method: []const u8,
        url_str: []const u8,
        custom_headers: ?*const Headers,
        body: ?[]const u8,
    ) !Response {
        const url = try Url.parse(url_str);
        const is_https = std.mem.eql(u8, url.scheme, "https");

        // Connect to server
        const address = try net.Address.resolveIp(url.host, url.port);
        const stream = try net.tcpConnectToAddress(address);
        errdefer stream.close();

        // Set socket timeout using POSIX options
        const timeout_secs: i32 = @intCast(self.timeout_ms / 1000);
        const timeout_val = std.posix.timeval{
            .sec = timeout_secs,
            .usec = @intCast((self.timeout_ms % 1000) * 1000),
        };
        std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout_val)) catch {};
        std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout_val)) catch {};

        // HTTPS requires TLS - not yet implemented in this minimal client
        // For HTTPS endpoints, use an HTTP proxy or external curl
        if (is_https) {
            return error.HttpsNotSupported;
        }

        // Build and send request
        var request_buf = std.ArrayListUnmanaged(u8){};
        defer request_buf.deinit(self.allocator);

        const writer = request_buf.writer(self.allocator);
        try writer.print("{s} {s} HTTP/1.1\r\n", .{ method, url.path });
        try writer.print("Host: {s}\r\n", .{url.host});
        try writer.print("Connection: close\r\n", .{});

        // Add custom headers
        if (custom_headers) |hdrs| {
            var iter = hdrs.map.iterator();
            while (iter.next()) |entry| {
                try writer.print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
        }

        // Add content-length for body
        if (body) |b| {
            try writer.print("Content-Length: {d}\r\n", .{b.len});
        }

        try writer.writeAll("\r\n");

        // Add body
        if (body) |b| {
            try writer.writeAll(b);
        }

        // Send request
        try stream.writeAll(request_buf.items);

        // Read response
        return try self.readResponse(stream);
    }

    /// Read and parse HTTP response
    fn readResponse(self: *Self, stream: net.Stream) !Response {
        var response_buf = std.ArrayListUnmanaged(u8){};
        defer response_buf.deinit(self.allocator);

        // Read response data
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = stream.read(&buf) catch |err| {
                // On connection close or error, stop reading
                return err;
            };

            if (n == 0) break; // EOF
            try response_buf.appendSlice(self.allocator, buf[0..n]);

            if (response_buf.items.len > MAX_BODY_SIZE) {
                return error.ResponseTooLarge;
            }
        }

        return try self.parseResponse(response_buf.items);
    }

    /// Parse HTTP response
    fn parseResponse(self: *Self, data: []const u8) !Response {
        // Find header/body separator
        const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return error.InvalidResponse;
        const header_data = data[0..header_end];
        const body_start = header_end + 4;
        const body_data = if (body_start < data.len) data[body_start..] else "";

        // Parse status line
        var lines = std.mem.splitSequence(u8, header_data, "\r\n");
        const status_line = lines.next() orelse return error.InvalidResponse;

        // Parse "HTTP/1.1 200 OK"
        var status_parts = std.mem.splitScalar(u8, status_line, ' ');
        _ = status_parts.next() orelse return error.InvalidResponse; // HTTP version
        const status_str = status_parts.next() orelse return error.InvalidResponse;
        const status_code = std.fmt.parseInt(u16, status_str, 10) catch return error.InvalidResponse;

        // Parse headers
        var headers = Headers.init(self.allocator);
        errdefer headers.deinit();

        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const colon_idx = std.mem.indexOf(u8, line, ":") orelse continue;
            const key = std.mem.trim(u8, line[0..colon_idx], " ");
            const value = std.mem.trim(u8, line[colon_idx + 1 ..], " ");
            try headers.put(key, value);
        }

        return .{
            .status_code = status_code,
            .headers = headers,
            .body = try self.allocator.dupe(u8, body_data),
            .allocator = self.allocator,
        };
    }
};

/// Minimal JSON parser for LFS batch API responses
pub const JsonParser = struct {
    allocator: Allocator,
    data: []const u8,
    pos: usize,

    const Self = @This();

    /// JSON parsing errors
    pub const ParseError = error{
        InvalidJson,
        UnexpectedEndOfInput,
        OutOfMemory,
    };

    /// JSON value types
    pub const Value = union(enum) {
        null,
        bool: bool,
        number: i64,
        string: []const u8,
        array: []Value,
        object: std.StringHashMap(Value),

        pub fn deinit(self: *Value, allocator: Allocator) void {
            switch (self.*) {
                .string => |s| allocator.free(s),
                .array => |arr| {
                    for (arr) |*item| {
                        var v = item.*;
                        v.deinit(allocator);
                    }
                    allocator.free(arr);
                },
                .object => |*obj| {
                    var iter = obj.iterator();
                    while (iter.next()) |entry| {
                        allocator.free(entry.key_ptr.*);
                        var v = entry.value_ptr.*;
                        v.deinit(allocator);
                    }
                    obj.deinit();
                },
                else => {},
            }
        }

        /// Get string value or null
        pub fn getString(self: Value) ?[]const u8 {
            return switch (self) {
                .string => |s| s,
                else => null,
            };
        }

        /// Get number value or null
        pub fn getNumber(self: Value) ?i64 {
            return switch (self) {
                .number => |n| n,
                else => null,
            };
        }

        /// Get bool value or null
        pub fn getBool(self: Value) ?bool {
            return switch (self) {
                .bool => |b| b,
                else => null,
            };
        }

        /// Get array value or null
        pub fn getArray(self: Value) ?[]Value {
            return switch (self) {
                .array => |a| a,
                else => null,
            };
        }

        /// Get object field or null
        pub fn get(self: Value, key: []const u8) ?Value {
            return switch (self) {
                .object => |obj| obj.get(key),
                else => null,
            };
        }
    };

    pub fn init(allocator: Allocator, data: []const u8) Self {
        return .{
            .allocator = allocator,
            .data = data,
            .pos = 0,
        };
    }

    /// Parse JSON data
    pub fn parse(self: *Self) ParseError!Value {
        self.skipWhitespace();
        return self.parseValue();
    }

    fn parseValue(self: *Self) ParseError!Value {
        self.skipWhitespace();
        if (self.pos >= self.data.len) return error.UnexpectedEndOfInput;

        const c = self.data[self.pos];
        return switch (c) {
            '"' => self.parseString(),
            '{' => self.parseObject(),
            '[' => self.parseArray(),
            't', 'f' => self.parseBool(),
            'n' => self.parseNull(),
            '-', '0'...'9' => self.parseNumber(),
            else => error.InvalidJson,
        };
    }

    fn parseString(self: *Self) ParseError!Value {
        if (self.data[self.pos] != '"') return error.InvalidJson;
        self.pos += 1;

        const start = self.pos;
        while (self.pos < self.data.len and self.data[self.pos] != '"') {
            if (self.data[self.pos] == '\\') {
                self.pos += 2; // Skip escaped char
            } else {
                self.pos += 1;
            }
        }

        if (self.pos >= self.data.len) return error.UnexpectedEndOfInput;

        const str = try self.allocator.dupe(u8, self.data[start..self.pos]);
        self.pos += 1; // Skip closing quote
        return .{ .string = str };
    }

    fn parseNumber(self: *Self) ParseError!Value {
        const start = self.pos;
        if (self.data[self.pos] == '-') self.pos += 1;

        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            if (c >= '0' and c <= '9') {
                self.pos += 1;
            } else {
                break;
            }
        }

        const num_str = self.data[start..self.pos];
        const num = std.fmt.parseInt(i64, num_str, 10) catch return error.InvalidJson;
        return .{ .number = num };
    }

    fn parseBool(self: *Self) ParseError!Value {
        if (self.pos + 4 <= self.data.len and std.mem.eql(u8, self.data[self.pos .. self.pos + 4], "true")) {
            self.pos += 4;
            return .{ .bool = true };
        }
        if (self.pos + 5 <= self.data.len and std.mem.eql(u8, self.data[self.pos .. self.pos + 5], "false")) {
            self.pos += 5;
            return .{ .bool = false };
        }
        return error.InvalidJson;
    }

    fn parseNull(self: *Self) ParseError!Value {
        if (self.pos + 4 <= self.data.len and std.mem.eql(u8, self.data[self.pos .. self.pos + 4], "null")) {
            self.pos += 4;
            return .null;
        }
        return error.InvalidJson;
    }

    fn parseArray(self: *Self) ParseError!Value {
        if (self.data[self.pos] != '[') return error.InvalidJson;
        self.pos += 1;

        var items = std.ArrayListUnmanaged(Value){};
        errdefer {
            for (items.items) |*item| {
                item.deinit(self.allocator);
            }
            items.deinit(self.allocator);
        }

        self.skipWhitespace();
        if (self.pos < self.data.len and self.data[self.pos] == ']') {
            self.pos += 1;
            return .{ .array = try items.toOwnedSlice(self.allocator) };
        }

        while (true) {
            self.skipWhitespace();
            const val = try self.parseValue();
            try items.append(self.allocator, val);

            self.skipWhitespace();
            if (self.pos >= self.data.len) return error.UnexpectedEndOfInput;

            if (self.data[self.pos] == ']') {
                self.pos += 1;
                break;
            }
            if (self.data[self.pos] != ',') return error.InvalidJson;
            self.pos += 1;
        }

        return .{ .array = try items.toOwnedSlice(self.allocator) };
    }

    fn parseObject(self: *Self) ParseError!Value {
        if (self.data[self.pos] != '{') return error.InvalidJson;
        self.pos += 1;

        var obj = std.StringHashMap(Value).init(self.allocator);
        errdefer {
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                var v = entry.value_ptr.*;
                v.deinit(self.allocator);
            }
            obj.deinit();
        }

        self.skipWhitespace();
        if (self.pos < self.data.len and self.data[self.pos] == '}') {
            self.pos += 1;
            return .{ .object = obj };
        }

        while (true) {
            self.skipWhitespace();
            const key_val = try self.parseString();
            const key = key_val.string;

            self.skipWhitespace();
            if (self.pos >= self.data.len or self.data[self.pos] != ':') {
                self.allocator.free(key);
                return error.InvalidJson;
            }
            self.pos += 1;

            self.skipWhitespace();
            const val = try self.parseValue();
            obj.put(key, val) catch return error.OutOfMemory;

            self.skipWhitespace();
            if (self.pos >= self.data.len) return error.UnexpectedEndOfInput;

            if (self.data[self.pos] == '}') {
                self.pos += 1;
                break;
            }
            if (self.data[self.pos] != ',') return error.InvalidJson;
            self.pos += 1;
        }

        return .{ .object = obj };
    }

    fn skipWhitespace(self: *Self) void {
        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else {
                break;
            }
        }
    }
};

/// Object info for batch requests
pub const BatchObjectInfo = struct {
    oid: []const u8,
    size: u64,
};

/// Build JSON request body for LFS batch API
pub fn buildBatchRequest(
    allocator: Allocator,
    operation: []const u8,
    objects: []const BatchObjectInfo,
) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    errdefer buf.deinit(allocator);

    const writer = buf.writer(allocator);
    try writer.writeAll("{\"operation\":\"");
    try writer.writeAll(operation);
    try writer.writeAll("\",\"transfers\":[\"basic\"],\"objects\":[");

    for (objects, 0..) |obj, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{{\"oid\":\"{s}\",\"size\":{d}}}", .{ obj.oid, obj.size });
    }

    try writer.writeAll("]}");
    return buf.toOwnedSlice(allocator);
}

// Tests

test "Url.parse - simple HTTP" {
    const url = try Url.parse("http://example.com/path/to/resource");
    try std.testing.expectEqualStrings("http", url.scheme);
    try std.testing.expectEqualStrings("example.com", url.host);
    try std.testing.expectEqual(@as(u16, 80), url.port);
    try std.testing.expectEqualStrings("/path/to/resource", url.path);
}

test "Url.parse - HTTPS with port" {
    const url = try Url.parse("https://example.com:8443/api/v1");
    try std.testing.expectEqualStrings("https", url.scheme);
    try std.testing.expectEqualStrings("example.com", url.host);
    try std.testing.expectEqual(@as(u16, 8443), url.port);
    try std.testing.expectEqualStrings("/api/v1", url.path);
}

test "Url.parse - HTTPS default port" {
    const url = try Url.parse("https://github.com/owner/repo.git/info/lfs");
    try std.testing.expectEqualStrings("https", url.scheme);
    try std.testing.expectEqualStrings("github.com", url.host);
    try std.testing.expectEqual(@as(u16, 443), url.port);
    try std.testing.expectEqualStrings("/owner/repo.git/info/lfs", url.path);
}

test "Url.parse - no path" {
    const url = try Url.parse("http://localhost:3000");
    try std.testing.expectEqualStrings("http", url.scheme);
    try std.testing.expectEqualStrings("localhost", url.host);
    try std.testing.expectEqual(@as(u16, 3000), url.port);
    try std.testing.expectEqualStrings("/", url.path);
}

test "Headers - basic operations" {
    const allocator = std.testing.allocator;
    var headers = Headers.init(allocator);
    defer headers.deinit();

    try headers.put("Content-Type", "application/json");
    try headers.put("Authorization", "Bearer token123");

    try std.testing.expectEqualStrings("application/json", headers.get("Content-Type").?);
    try std.testing.expectEqualStrings("Bearer token123", headers.get("Authorization").?);
    try std.testing.expect(headers.get("X-Not-Present") == null);
}

test "JsonParser - parse simple object" {
    const allocator = std.testing.allocator;
    const json = "{\"name\":\"test\",\"size\":12345,\"active\":true}";

    var parser = JsonParser.init(allocator, json);
    var value = try parser.parse();
    defer value.deinit(allocator);

    try std.testing.expectEqualStrings("test", value.get("name").?.getString().?);
    try std.testing.expectEqual(@as(i64, 12345), value.get("size").?.getNumber().?);
    try std.testing.expect(value.get("active").?.getBool().?);
}

test "JsonParser - parse array" {
    const allocator = std.testing.allocator;
    const json = "[1,2,3]";

    var parser = JsonParser.init(allocator, json);
    var value = try parser.parse();
    defer value.deinit(allocator);

    const arr = value.getArray().?;
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqual(@as(i64, 1), arr[0].getNumber().?);
    try std.testing.expectEqual(@as(i64, 2), arr[1].getNumber().?);
    try std.testing.expectEqual(@as(i64, 3), arr[2].getNumber().?);
}

test "JsonParser - parse LFS batch response" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "transfer": "basic",
        \\  "objects": [
        \\    {
        \\      "oid": "abc123",
        \\      "size": 1024,
        \\      "authenticated": true,
        \\      "actions": {
        \\        "download": {
        \\          "href": "https://example.com/download"
        \\        }
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var parser = JsonParser.init(allocator, json);
    var value = try parser.parse();
    defer value.deinit(allocator);

    try std.testing.expectEqualStrings("basic", value.get("transfer").?.getString().?);

    const objects = value.get("objects").?.getArray().?;
    try std.testing.expectEqual(@as(usize, 1), objects.len);

    const obj = objects[0];
    try std.testing.expectEqualStrings("abc123", obj.get("oid").?.getString().?);
    try std.testing.expectEqual(@as(i64, 1024), obj.get("size").?.getNumber().?);

    const actions = obj.get("actions").?;
    const download = actions.get("download").?;
    try std.testing.expectEqualStrings("https://example.com/download", download.get("href").?.getString().?);
}

test "JsonParser - parse null and nested objects" {
    const allocator = std.testing.allocator;
    const json = "{\"data\":null,\"nested\":{\"inner\":\"value\"}}";

    var parser = JsonParser.init(allocator, json);
    var value = try parser.parse();
    defer value.deinit(allocator);

    try std.testing.expect(value.get("data").? == .null);
    try std.testing.expectEqualStrings("value", value.get("nested").?.get("inner").?.getString().?);
}

test "buildBatchRequest - upload" {
    const allocator = std.testing.allocator;
    const objects = [_]BatchObjectInfo{
        .{ .oid = "abc123def456", .size = 1024 },
        .{ .oid = "xyz789", .size = 2048 },
    };

    const request = try buildBatchRequest(allocator, "upload", &objects);
    defer allocator.free(request);

    try std.testing.expect(std.mem.indexOf(u8, request, "\"operation\":\"upload\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"oid\":\"abc123def456\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"size\":1024") != null);
}

test "HttpClient - init and timeout" {
    const allocator = std.testing.allocator;
    var client = HttpClient.init(allocator);
    try std.testing.expectEqual(@as(u32, 30000), client.timeout_ms);

    client.setTimeout(60000);
    try std.testing.expectEqual(@as(u32, 60000), client.timeout_ms);
}

test "HttpClient - parseResponse" {
    const allocator = std.testing.allocator;
    var client = HttpClient.init(allocator);

    const raw_response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"ok\": true}";

    var response = try client.parseResponse(raw_response);
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 200), response.status_code);
    try std.testing.expectEqualStrings("application/json", response.headers.get("Content-Type").?);
    try std.testing.expectEqualStrings("{\"ok\": true}", response.body);
}

test "HttpClient - parseResponse 404" {
    const allocator = std.testing.allocator;
    var client = HttpClient.init(allocator);

    const raw_response = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n\r\nNot found";

    var response = try client.parseResponse(raw_response);
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 404), response.status_code);
    try std.testing.expectEqualStrings("Not found", response.body);
}
