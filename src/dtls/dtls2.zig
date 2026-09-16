const std = @import("std");
const builtin = @import("builtin");
const stun = @import("stun");
const utils = @import("../utils.zig");
const m = @import("c.zig").mtls;

const Sha256 = std.crypto.hash.sha2.Sha256;

const Logger = std.log.scoped(.dtls2);

const srtp_profiles = [_]u16{
    m.MBEDTLS_TLS_SRTP_AES128_CM_HMAC_SHA1_80,
    m.MBEDTLS_TLS_SRTP_AES128_CM_HMAC_SHA1_32,
    m.MBEDTLS_TLS_SRTP_UNSET,
};

const max_srtp_keying_material_size = 30;

const dtls_mtu: u16 = 1400;

pub const ConnectionState = enum { new, connecting, connected, failed, closed };
pub const Role = enum { client, server };

pub const SrtpProfile = struct {
    profile: u16,
    local_keying_material: [max_srtp_keying_material_size]u8,
    remote_keying_material: [max_srtp_keying_material_size]u8,
};

const SessionKeys = struct {
    tls_profile: u32,
    master_secret: []const u8,
    rand_bytes: [64]u8,
};

const max_datagram_size = 1500;

pub const Session = struct {
    const Self = @This();
    const max_events = 6;
    const KEYING_EXTRACTOR_LABEL = "EXTRACTOR-dtls_srtp";

    pub const ReadResult = union(enum) {
        app_data: []const u8,
        consumed: void,
    };

    pub const Event = union(enum) {
        connection_state: ConnectionState,
        srtp_keying_material: SrtpProfile,
    };

    pub const HandshakeError = error{
        /// The handshake failed due to a retransmission timeout.
        Timeout,
        /// The handshake failed due to a certificate error.
        X509Error,
        /// The handshake failed due to an unknown error.
        HandshakeFailed,
    };

    pub const HandleReadError = error{InvalidState} || HandshakeError;

    pub const Config = struct {
        key_pair: []const u8,
        debug_level: u8 = 0,
    };

    random: std.Random,
    connection_state: ConnectionState,
    key: m.mbedtls_pk_context,
    ssl: m.mbedtls_ssl_context,
    ssl_conf: m.mbedtls_ssl_config,
    crt: m.mbedtls_x509_crt,
    received_data: ?[]const u8,
    session_keys: SessionKeys,
    peer_fingerprint: [32]u8,

    now: i64,
    int_deadline: i64,
    int_expired: bool,
    fin_deadline: i64,
    fin_expired: bool,

    events_out: stun.BoundedDeque(Event, max_events),

    direct_out: ?[]u8,
    direct_out_len: usize,

    handshake_out: [max_datagram_size]u8,
    handshake_out_len: usize,
    handshake_needed: bool,
    setup: bool = false,

    pub fn init(random: std.Random, session_config: Config) !Self {
        var session: Self = undefined;

        session.random = random;
        session.connection_state = .new;
        session.received_data = null;
        session.session_keys = undefined;
        session.peer_fingerprint = @splat(0);
        session.now = 0;
        session.int_deadline = std.math.maxInt(i64);
        session.fin_deadline = std.math.maxInt(i64);
        session.int_expired = false;
        session.fin_expired = false;
        session.events_out = .empty;
        session.direct_out = null;
        session.direct_out_len = 0;
        session.handshake_out = undefined;
        session.handshake_out_len = 0;
        session.handshake_needed = false;

        m.mbedtls_pk_init(&session.key);
        m.mbedtls_ssl_init(&session.ssl);
        m.mbedtls_ssl_config_init(&session.ssl_conf);
        m.mbedtls_x509_crt_init(&session.crt);
        errdefer session.deinit();

        if (m.mbedtls_pk_parse_key(
            &session.key,
            session_config.key_pair.ptr,
            session_config.key_pair.len + 1,
            null,
            0,
            mbedtlsRandom,
            &session.random,
        ) != 0) return error.FailedParsePrivateKey;

        try session.createCertificate();
        m.mbedtls_debug_set_threshold(session_config.debug_level);

        return session;
    }

    pub fn setRole(session: *Self, server: bool) !void {
        m.mbedtls_ssl_conf_rng(&session.ssl_conf, mbedtlsRandom, &session.random);

        if (m.mbedtls_ssl_config_defaults(
            &session.ssl_conf,
            if (server) m.MBEDTLS_SSL_IS_SERVER else m.MBEDTLS_SSL_IS_CLIENT,
            m.MBEDTLS_SSL_TRANSPORT_DATAGRAM,
            m.MBEDTLS_SSL_PRESET_DEFAULT,
        ) != 0) return error.SetConfigFailed;

        _ = m.mbedtls_ssl_set_hostname(&session.ssl, null);
        m.mbedtls_ssl_conf_authmode(&session.ssl_conf, m.MBEDTLS_SSL_VERIFY_OPTIONAL);
        m.mbedtls_ssl_conf_dbg(&session.ssl_conf, logDebugMessages, null);
        m.mbedtls_ssl_conf_verify(&session.ssl_conf, verifyCertificateFingerprint, session);
        m.mbedtls_ssl_set_export_keys_cb(&session.ssl, exportSessionKeyDerivation, session);
        m.mbedtls_ssl_conf_ca_chain(&session.ssl_conf, &session.crt, null);
        if (m.mbedtls_ssl_conf_own_cert(&session.ssl_conf, &session.crt, &session.key) != 0) return error.OwnCertConfFailed;
        if (m.mbedtls_ssl_conf_dtls_srtp_protection_profiles(&session.ssl_conf, &srtp_profiles) != 0) return error.SetSrtpProfilesFailed;

        if (m.mbedtls_ssl_setup(&session.ssl, &session.ssl_conf) != 0) return error.SslSetupFailed;

        m.mbedtls_ssl_set_mtu(&session.ssl, dtls_mtu);
        m.mbedtls_ssl_set_bio(&session.ssl, session, sendData, recvData, recvDataTimeout);
        m.mbedtls_ssl_set_timer_cb(&session.ssl, session, setTimer, getTimer);

        session.setup = true;
    }

    pub fn deinit(session: *Self) void {
        m.mbedtls_pk_free(&session.key);
        m.mbedtls_ssl_free(&session.ssl);
        m.mbedtls_ssl_config_free(&session.ssl_conf);
        m.mbedtls_x509_crt_free(&session.crt);
    }

    pub fn setPeerFingerprint(session: *Self, fingerprint: *const [32]u8) void {
        @memcpy(&session.peer_fingerprint, fingerprint);
    }

    pub fn getFingerprint(session: *Self, fingerprint: *[32]u8) void {
        const cert = session.crt.raw.p[0..session.crt.raw.len];
        Sha256.hash(cert, fingerprint, .{});
    }

    pub fn getRole(session: *const Self) Role {
        return if (m.mbedtls_ssl_conf_get_endpoint(&session.ssl_conf) == m.MBEDTLS_SSL_IS_SERVER) .server else .client;
    }

    /// Feed one received datagram into the session. Returns `.app_data` once
    /// the handshake is complete and the datagram carried decrypted
    /// application data (SCTP); otherwise `.consumed`.
    pub fn handleRead(session: *Self, data: []const u8, now: i64, out_buffer: []u8) HandleReadError!ReadResult {
        if (!session.setup) return .consumed;

        session.now = now;
        if (session.connection_state == .new) session.setConnectionState(.connecting);

        switch (session.connection_state) {
            .connecting => {
                session.received_data = data;
                try session.handshakeStep();
                return .consumed;
            },
            .connected => {
                session.received_data = data;

                const ret = m.mbedtls_ssl_read(&session.ssl, out_buffer.ptr, out_buffer.len);
                if (ret > 0) return .{ .app_data = out_buffer[0..@intCast(ret)] };

                switch (ret) {
                    m.MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY => {
                        Logger.warn("Peer closed connection", .{});
                        session.setConnectionState(.closed);
                    },
                    m.MBEDTLS_ERR_SSL_WANT_READ, m.MBEDTLS_ERR_SSL_WANT_WRITE => {},
                    else => |err_code| {
                        m.mbedtls_strerror(err_code, out_buffer.ptr, out_buffer.len);
                        Logger.err("Error: {s}", .{out_buffer});
                        return error.HandshakeFailed;
                    },
                }
                return .consumed;
            },
            else => return error.InvalidState,
        }
    }

    pub fn handleTimeout(session: *Self, now: i64) void {
        session.now = now;
        session.received_data = null;

        if (session.connection_state == .new) {
            session.setConnectionState(.connecting);
            session.handshake_needed = true;
            return;
        }

        if (now >= session.fin_deadline) {
            session.fin_deadline = std.math.maxInt(i64);
            session.fin_expired = true;
            if (session.connection_state == .connecting) session.handshake_needed = true;
        }

        if (now >= session.int_deadline) {
            session.int_deadline = std.math.maxInt(i64);
            session.int_expired = true;
        }
    }

    pub fn writeData(session: *Self, data: []const u8, out_buffer: []u8) !usize {
        session.direct_out = out_buffer;
        session.direct_out_len = 0;
        defer session.direct_out = null;

        var len = data.len;
        var offset: usize = 0;

        while (true) {
            const ret = m.mbedtls_ssl_write(&session.ssl, data.ptr, data.len);
            if (ret < 0) return error.WriteDataFailed;
            if (ret < len) {
                offset += @intCast(ret);
                len -= @intCast(ret);
            } else break;
        }

        return session.direct_out_len;
    }

    pub fn close(session: *Self) void {
        _ = m.mbedtls_ssl_close_notify(&session.ssl);
        session.setConnectionState(.closed);
    }

    pub fn pollEvent(session: *Self) ?Event {
        return session.events_out.popFront();
    }

    pub fn pollTransmit(session: *Self) ?[]const u8 {
        if (session.handshake_out_len == 0 and session.handshake_needed and session.connection_state == .connecting) {
            session.handshakeStep() catch {};
        }

        if (session.handshake_out_len == 0) return null;
        defer session.handshake_out_len = 0;
        return session.handshake_out[0..session.handshake_out_len];
    }

    pub fn pollTimeout(session: *Self) ?i64 {
        const deadline = @min(session.int_deadline, session.fin_deadline);
        return if (deadline == std.math.maxInt(i64)) return null else deadline;
    }

    fn setConnectionState(session: *Self, state: ConnectionState) void {
        session.connection_state = state;
        session.events_out.pushBack(.{ .connection_state = state }) catch |err| {
            Logger.warn("Dropping dtls2 event, queue full: {}", .{err});
        };
    }

    fn createCertificate(session: *Self) !void {
        if (m.psa_crypto_init() != m.PSA_SUCCESS) return error.CryptoInitFailed;

        var cert: m.mbedtls_x509write_cert = undefined;
        m.mbedtls_x509write_crt_init(&cert);
        defer m.mbedtls_x509write_crt_free(&cert);

        m.mbedtls_x509write_crt_set_md_alg(&cert, m.MBEDTLS_MD_SHA256);
        m.mbedtls_x509write_crt_set_issuer_key(&cert, &session.key);
        m.mbedtls_x509write_crt_set_subject_key(&cert, &session.key);
        var ret = m.mbedtls_x509write_crt_set_validity(&cert, "20250101000000", "20350101000000");
        try checkError(ret);

        var serial: [16]u8 = @splat(0);
        session.random.bytes(&serial);
        serial[0] = (serial[0] & 0x7F) | 0x01;
        ret = m.mbedtls_x509write_crt_set_serial_raw(&cert, serial[0..].ptr, serial.len);
        try checkError(ret);

        ret = m.mbedtls_x509write_crt_set_subject_name(&cert, "CN=Zig WebRTC");
        try checkError(ret);
        ret = m.mbedtls_x509write_crt_set_issuer_name(&cert, "CN=Zig WebRTC");
        try checkError(ret);

        var buffer: [4096]u8 = @splat(0);
        ret = m.mbedtls_x509write_crt_der(&cert, buffer[0..].ptr, buffer.len, mbedtlsRandom, &session.random);
        try checkError(ret);

        const len: u32 = @bitCast(ret);
        const certificate = buffer[buffer.len - len ..];
        ret = m.mbedtls_x509_crt_parse_der(&session.crt, certificate.ptr, certificate.len);
        try checkError(ret);
    }

    fn handshakeStep(session: *Self) HandshakeError!void {
        switch (m.mbedtls_ssl_handshake(&session.ssl)) {
            0 => {
                session.handshake_needed = false;
                const profile = session.exportSrtpKeyingMaterial() catch |err| {
                    Logger.err("Failed to export srtp keying material: {}", .{err});
                    return error.HandshakeFailed;
                };
                session.setConnectionState(.connected);
                session.events_out.pushBack(.{ .srtp_keying_material = profile }) catch |err| {
                    Logger.warn("Dropping dtls2 event, queue full: {}", .{err});
                };
            },
            m.MBEDTLS_ERR_SSL_WANT_READ => session.handshake_needed = false,
            m.MBEDTLS_ERR_SSL_WANT_WRITE => session.handshake_needed = true,
            else => |err_code| {
                session.handshake_needed = false;

                var error_buffer: [1024]u8 = undefined;
                m.mbedtls_strerror(err_code, error_buffer[0..].ptr, error_buffer.len);
                if (builtin.is_test) {
                    Logger.debug("Handshake failed: {s}", .{error_buffer});
                } else {
                    Logger.err("Handshake failed: {s}", .{error_buffer});
                }

                session.setConnectionState(.failed);
                return switch (err_code) {
                    m.MBEDTLS_ERR_SSL_TIMEOUT => error.Timeout,
                    m.MBEDTLS_ERR_X509_FATAL_ERROR => error.X509Error,
                    else => error.HandshakeFailed,
                };
            },
        }
    }

    fn sendData(ctx: ?*anyopaque, buf: [*c]const u8, len: usize) callconv(.c) i32 {
        const session: *Self = @ptrCast(@alignCast(ctx.?));

        if (session.direct_out) |dest| {
            if (len > dest.len) return m.MBEDTLS_ERR_SSL_WANT_WRITE;
            @memcpy(dest[0..len], buf[0..len]);
            session.direct_out_len = len;
            return @intCast(len);
        }

        if (session.handshake_out_len != 0 or len > session.handshake_out.len) return m.MBEDTLS_ERR_SSL_WANT_WRITE;

        @memcpy(session.handshake_out[0..len], buf[0..len]);
        session.handshake_out_len = len;

        return @intCast(len);
    }

    fn recvData(ctx: ?*anyopaque, buf: [*c]u8, len: usize) callconv(.c) i32 {
        return recvDataTimeout(ctx, buf, len, 0);
    }

    fn recvDataTimeout(ctx: ?*anyopaque, buf: [*c]u8, len: usize, timeout: u32) callconv(.c) i32 {
        _ = timeout;

        const session: *Self = @ptrCast(@alignCast(ctx.?));
        if (session.received_data) |data| {
            std.debug.assert(data.len <= len);
            @memcpy(buf[0..data.len], data);
            session.received_data = null;
            return @intCast(data.len);
        }

        return m.MBEDTLS_ERR_SSL_WANT_READ;
    }

    fn setTimer(ctx: ?*anyopaque, int_ms: u32, fin_ms: u32) callconv(.c) void {
        const session: *Self = @ptrCast(@alignCast(ctx.?));
        if (fin_ms == 0) {
            session.int_deadline = std.math.maxInt(i64);
            session.fin_deadline = std.math.maxInt(i64);
        } else {
            session.int_deadline = session.now + int_ms;
            session.fin_deadline = session.now + fin_ms;
        }

        session.int_expired = false;
        session.fin_expired = false;
    }

    fn getTimer(ctx: ?*anyopaque) callconv(.c) i32 {
        const session: *Self = @ptrCast(@alignCast(ctx.?));
        if (session.fin_expired) return 2;
        if (session.int_expired) return 1;
        return 0;
    }

    fn exportSrtpKeyingMaterial(session: *Self) !SrtpProfile {
        var profile: m.mbedtls_dtls_srtp_info = .{};
        m.mbedtls_ssl_get_dtls_srtp_negotiation_result(&session.ssl, &profile);
        errdefer {
            _ = m.mbedtls_ssl_close_notify(&session.ssl);
            session.setConnectionState(.failed);
        }

        switch (profile.private_chosen_dtls_srtp_profile) {
            m.MBEDTLS_TLS_SRTP_AES128_CM_HMAC_SHA1_80, m.MBEDTLS_TLS_SRTP_AES128_CM_HMAC_SHA1_32 => |value| {
                var keying_material: [60]u8 = undefined;

                const ret = m.mbedtls_ssl_tls_prf(
                    session.session_keys.tls_profile,
                    session.session_keys.master_secret.ptr,
                    session.session_keys.master_secret.len,
                    KEYING_EXTRACTOR_LABEL,
                    session.session_keys.rand_bytes[0..].ptr,
                    session.session_keys.rand_bytes.len,
                    &keying_material,
                    keying_material.len,
                );
                if (ret != 0) return error.ExportKeyingMaterialFailed;

                var srtp_profile: SrtpProfile = undefined;
                srtp_profile.profile = value;
                if (session.getRole() == .server) {
                    @memcpy(srtp_profile.remote_keying_material[0..16], keying_material[0..16]);
                    @memcpy(srtp_profile.remote_keying_material[16..], keying_material[32..46]);
                    @memcpy(srtp_profile.local_keying_material[0..16], keying_material[16..32]);
                    @memcpy(srtp_profile.local_keying_material[16..], keying_material[46..]);
                } else {
                    @memcpy(srtp_profile.local_keying_material[0..16], keying_material[0..16]);
                    @memcpy(srtp_profile.local_keying_material[16..], keying_material[32..46]);
                    @memcpy(srtp_profile.remote_keying_material[0..16], keying_material[16..32]);
                    @memcpy(srtp_profile.remote_keying_material[16..], keying_material[46..]);
                }

                return srtp_profile;
            },
            else => return error.NoSrtpProfile,
        }
    }

    fn verifyCertificateFingerprint(ctx: ?*anyopaque, crt: [*c]m.mbedtls_x509_crt, flag: c_int, cn: [*c]u32) callconv(.c) i32 {
        _ = flag;
        _ = cn;

        const session: *Self = @ptrCast(@alignCast(ctx.?));
        const cert = crt.*.raw.p[0..crt.*.raw.len];
        var fingerprint: [Sha256.digest_length]u8 = @splat(0);
        Sha256.hash(cert, &fingerprint, .{});

        return if (std.mem.eql(u8, &session.peer_fingerprint, &fingerprint)) 0 else m.MBEDTLS_ERR_X509_CERT_VERIFY_FAILED;
    }

    fn exportSessionKeyDerivation(
        ctx: ?*anyopaque,
        key_type: c_uint,
        secret: [*c]const u8,
        secret_len: usize,
        client_random: [*c]const u8,
        server_random: [*c]const u8,
        tls_prf_type: c_uint,
    ) callconv(.c) void {
        _ = key_type;

        const session: *Self = @ptrCast(@alignCast(ctx.?));
        const max_dtls_random_bytes = 32;

        session.session_keys = .{
            .master_secret = secret[0..secret_len],
            .rand_bytes = @splat(0),
            .tls_profile = tls_prf_type,
        };

        @memcpy(session.session_keys.rand_bytes[0..max_dtls_random_bytes], client_random[0..max_dtls_random_bytes]);
        @memcpy(session.session_keys.rand_bytes[max_dtls_random_bytes..], server_random[0..max_dtls_random_bytes]);
    }

    fn mbedtlsRandom(ctx: ?*anyopaque, data: [*c]u8, len: usize) callconv(.c) c_int {
        const rand: *std.Random = @ptrCast(@alignCast(ctx));
        rand.bytes(data[0..len]);
        return 0;
    }

    fn logDebugMessages(ctx: ?*anyopaque, level: c_int, file: [*c]const u8, len: c_int, str: [*c]const u8) callconv(.c) void {
        _ = ctx;
        _ = len;

        const message = std.mem.sliceTo(str, 0);
        var file_path = std.mem.sliceTo(file, 0);
        file_path = if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |idx| file_path[idx + 1 ..] else file_path;

        switch (level) {
            1 => Logger.err("file={s} {s}", .{ file_path, message[0 .. message.len - 1] }),
            else => Logger.debug("file={s} {s}", .{ file_path, message[0 .. message.len - 1] }),
        }
    }

    fn checkError(ret: i32) !void {
        if (ret < 0) {
            var buffer: [1024]u8 = @splat(0);
            m.mbedtls_strerror(ret, buffer[0..].ptr, buffer.len);
            Logger.err("{s}", .{buffer});
            return error.ParseCertificateFailed;
        }
    }
};

const testing = std.testing;

fn initTestSession(random: std.Random) !Session {
    var buffer: [4096]u8 = @splat(0);
    const der_key = try utils.generateP256KeyPairDer(testing.io, &buffer);
    return Session.init(random, .{ .key_pair = der_key });
}

fn createPeers(peer1: *Session, peer2: *Session, random: std.Random) !void {
    peer1.* = try initTestSession(random);
    peer2.* = try initTestSession(random);

    try peer1.setRole(true);
    try peer2.setRole(false);

    var fingerprint: [32]u8 = @splat(0);
    peer1.getFingerprint(&fingerprint);
    peer2.setPeerFingerprint(&fingerprint);

    peer2.getFingerprint(&fingerprint);
    peer1.setPeerFingerprint(&fingerprint);
}

fn driveHandshake(peer1: *Session, peer2: *Session) !void {
    var now: i64 = 0;
    peer2.handleTimeout(now); // client kicks off the first flight

    var buf: [1500]u8 = undefined;
    while (peer1.connection_state != .connected or peer2.connection_state != .connected) {
        var progressed = false;

        while (peer2.pollTransmit()) |dgram| {
            _ = try peer1.handleRead(dgram, now, &buf);
            progressed = true;
        }
        while (peer1.pollTransmit()) |dgram| {
            _ = try peer2.handleRead(dgram, now, &buf);
            progressed = true;
        }

        if (!progressed) {
            now += 1;
            if (peer1.pollTimeout()) |deadline| if (now >= deadline) peer1.handleTimeout(now);
            if (peer2.pollTimeout()) |deadline| if (now >= deadline) peer2.handleTimeout(now);
        }
    }
}

fn expectSrtpKeyingMaterial(session: *Session) !SrtpProfile {
    while (session.pollEvent()) |event| {
        if (event == .srtp_keying_material) return event.srtp_keying_material;
    }
    return error.NoSrtpKeyingMaterialEvent;
}

test "Dtls2 session: handshake" {
    var peer1: Session = undefined;
    var peer2: Session = undefined;
    var prng = std.Random.DefaultPrng.init(testing.random_seed);
    try createPeers(&peer1, &peer2, prng.random());
    defer peer1.deinit();
    defer peer2.deinit();

    try driveHandshake(&peer1, &peer2);

    try testing.expect(peer1.connection_state == .connected);
    try testing.expect(peer2.connection_state == .connected);
}

test "Dtls2 session: pollEvent reports connected transition" {
    var peer1: Session = undefined;
    var peer2: Session = undefined;
    var prng = std.Random.DefaultPrng.init(testing.random_seed);
    try createPeers(&peer1, &peer2, prng.random());
    defer peer1.deinit();
    defer peer2.deinit();

    try driveHandshake(&peer1, &peer2);

    var saw_connected = false;
    while (peer1.pollEvent()) |event| {
        if (event == .connection_state and event.connection_state == .connected) saw_connected = true;
    }
    try testing.expect(saw_connected);
}

test "Dtls2 session: handshake failed (wrong fingerprint)" {
    var peer1: Session = undefined;
    var peer2: Session = undefined;
    var prng = std.Random.DefaultPrng.init(testing.random_seed);
    try createPeers(&peer1, &peer2, prng.random());
    defer peer1.deinit();
    defer peer2.deinit();

    var fingerprint: [32]u8 = @splat(0);
    testing.io.random(&fingerprint);
    peer1.setPeerFingerprint(&fingerprint);

    var now: i64 = 0;
    peer2.handleTimeout(now);

    var buf: [1500]u8 = undefined;
    while (true) {
        if (peer2.pollTransmit()) |dgram| {
            if (peer1.handleRead(dgram, now, &buf)) |_| {} else |err| {
                try testing.expectEqual(error.X509Error, err);
                try testing.expect(peer1.connection_state == .failed);
                break;
            }
            continue;
        }
        if (peer1.pollTransmit()) |dgram| {
            if (peer2.handleRead(dgram, now, &buf)) |_| {} else |err| {
                try testing.expectEqual(error.X509Error, err);
                try testing.expect(peer2.connection_state == .failed);
                break;
            }
            continue;
        }

        now += 1;
        if (peer1.pollTimeout()) |deadline| if (now >= deadline) peer1.handleTimeout(now);
        if (peer2.pollTimeout()) |deadline| if (now >= deadline) peer2.handleTimeout(now);
    }
}

test "Dtls2 session: export srtp keying material" {
    var peer1: Session = undefined;
    var peer2: Session = undefined;
    var prng = std.Random.DefaultPrng.init(testing.random_seed);
    try createPeers(&peer1, &peer2, prng.random());
    defer peer1.deinit();
    defer peer2.deinit();

    try driveHandshake(&peer1, &peer2);

    const peer1_keying_material = try expectSrtpKeyingMaterial(&peer1);
    const peer2_keying_material = try expectSrtpKeyingMaterial(&peer2);

    try testing.expect(peer1_keying_material.profile == peer2_keying_material.profile);
    try testing.expectEqualSlices(
        u8,
        &peer1_keying_material.local_keying_material,
        &peer2_keying_material.remote_keying_material,
    );
    try testing.expectEqualSlices(
        u8,
        &peer1_keying_material.remote_keying_material,
        &peer2_keying_material.local_keying_material,
    );
}

test "Dtls2 session: close connection" {
    var peer1: Session = undefined;
    var peer2: Session = undefined;
    var prng = std.Random.DefaultPrng.init(testing.random_seed);
    try createPeers(&peer1, &peer2, prng.random());
    defer peer1.deinit();
    defer peer2.deinit();

    try driveHandshake(&peer1, &peer2);

    peer1.close();
    try testing.expect(peer1.connection_state == .closed);

    const dgram = peer1.pollTransmit() orelse return error.ExpectedTransmit;
    var buf: [1500]u8 = undefined;
    _ = try peer2.handleRead(dgram, 0, &buf);
    try testing.expect(peer2.connection_state == .closed);
}
