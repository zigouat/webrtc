const std = @import("std");
const m = @import("c.zig").mtls;

const P256 = std.crypto.ecc.P256;
const Sha256 = std.crypto.hash.sha2.Sha256;

const Logger = std.log.scoped(.dtls);

const srtp_profiles = [_]u16{
    m.MBEDTLS_TLS_SRTP_AES128_CM_HMAC_SHA1_80,
    m.MBEDTLS_TLS_SRTP_AES128_CM_HMAC_SHA1_32,
    m.MBEDTLS_TLS_SRTP_UNSET,
};

const max_srtp_keying_material_size = 30;

pub const P256KeyPair = struct {
    priv_key: [32]u8,
    pub_key: P256,

    pub fn init(io: std.Io) !P256KeyPair {
        const priv_key = P256.scalar.random(io, .big);
        const pub_key = try P256.basePoint.mul(priv_key, .big);
        return .{ .priv_key = priv_key, .pub_key = pub_key };
    }

    pub fn toDer(key_pair: *const P256KeyPair, buffer: []u8) ![]const u8 {
        var w = std.Io.Writer.fixed(buffer);
        try w.writeAll(&[_]u8{ 0x30, 0x77, 0x02, 0x01, 0x01, 0x04, 0x20 });
        try w.writeAll(&key_pair.priv_key);
        try w.writeAll(&[_]u8{ 0xA0, 0x0A, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07 });
        try w.writeAll(&[_]u8{ 0xA1, 0x44, 0x03, 0x42, 0x00 });
        try w.writeAll(&key_pair.pub_key.toUncompressedSec1());
        return w.buffered();
    }
};

pub const ConnectionState = enum { new, connecting, connected, failed, closed };

pub const SrtpProfile = struct {
    profile: u16,
    local_keying_material: [max_srtp_keying_material_size]u8,
    remote_keying_material: [max_srtp_keying_material_size]u8,
};

pub const Session = struct {
    const KEYINIG_EXTRACTOR_LABEL = "EXTRACTOR-dtls_srtp";

    io: std.Io,
    connection_state: ConnectionState,
    key: m.mbedtls_pk_context,
    entropy: m.mbedtls_entropy_context,
    ssl: m.mbedtls_ssl_context,
    ssl_conf: m.mbedtls_ssl_config,
    crt: m.mbedtls_x509_crt,
    received_data: ?[]const u8,
    handshake_timer_value: struct { u32, u32 },
    session_keys: SessionKeys,
    peer_fingerprint: [32]u8,

    // Callbacks
    on_send_data: *const fn (*Session, []const u8) i32,
    on_set_timer: *const fn (*Session, u32, u32) void,
    on_get_timer_state: *const fn (*Session) i32,

    const SessionKeys = struct {
        tls_profile: u32,
        master_secret: []const u8,
        rand_bytes: [64]u8,
    };

    pub const Config = struct {
        key_pair: []const u8,
        on_send_data: *const fn (*Session, []const u8) i32,
        on_set_timer: *const fn (*Session, u32, u32) void,
        on_get_timer_state: *const fn (*Session) i32,
        debug_level: u8 = 1,
    };

    pub fn init(io: std.Io, config: Config) !Session {
        var session: Session = undefined;

        session.io = io;
        session.connection_state = .new;
        session.on_send_data = config.on_send_data;
        session.on_set_timer = config.on_set_timer;
        session.on_get_timer_state = config.on_get_timer_state;
        session.received_data = null;
        session.handshake_timer_value = .{ 0, 0 };
        session.session_keys = undefined;
        session.peer_fingerprint = @splat(0);

        m.mbedtls_pk_init(&session.key);
        m.mbedtls_entropy_init(&session.entropy);
        m.mbedtls_ssl_init(&session.ssl);
        m.mbedtls_ssl_config_init(&session.ssl_conf);
        m.mbedtls_x509_crt_init(&session.crt);
        errdefer session.deinit();

        if (m.mbedtls_pk_parse_key(
            &session.key,
            config.key_pair.ptr,
            config.key_pair.len + 1,
            null,
            0,
            random,
            &session.io,
        ) != 0) return error.FailedParsePrivateKey;

        try session.createCertificate(io);
        m.mbedtls_debug_set_threshold(config.debug_level);

        return session;
    }

    pub fn setRole(session: *Session, server: bool) !void {
        m.mbedtls_ssl_conf_rng(&session.ssl_conf, random, &session.io);

        if (m.mbedtls_ssl_config_defaults(
            &session.ssl_conf,
            if (server) m.MBEDTLS_SSL_IS_SERVER else m.MBEDTLS_SSL_IS_CLIENT,
            m.MBEDTLS_SSL_TRANSPORT_DATAGRAM,
            m.MBEDTLS_SSL_PRESET_DEFAULT,
        ) != 0) return error.SetConfigFailed;

        m.mbedtls_ssl_conf_authmode(&session.ssl_conf, m.MBEDTLS_SSL_VERIFY_NONE);
        m.mbedtls_ssl_conf_dbg(&session.ssl_conf, logDebugMessages, null);
        m.mbedtls_ssl_conf_verify(&session.ssl_conf, verifyCertificateFingerprint, session);
        m.mbedtls_ssl_set_export_keys_cb(&session.ssl, exportSessionKeyDerivation, session);
        m.mbedtls_ssl_conf_ca_chain(&session.ssl_conf, &session.crt, null);
        if (m.mbedtls_ssl_conf_own_cert(&session.ssl_conf, &session.crt, &session.key) != 0) return error.OwnCertConfFailed;
        if (m.mbedtls_ssl_conf_dtls_srtp_protection_profiles(&session.ssl_conf, &srtp_profiles) != 0) return error.SetSrtpProfilesFailed;

        if (m.mbedtls_ssl_setup(&session.ssl, &session.ssl_conf) != 0) return error.SslSetupFailed;

        m.mbedtls_ssl_set_bio(&session.ssl, session, sendData, recvData, recvDataTimeout);
        m.mbedtls_ssl_set_timer_cb(&session.ssl, session, setTimer, getTimer);
    }

    pub fn deinit(session: *Session) void {
        m.mbedtls_pk_free(&session.key);
        m.mbedtls_entropy_free(&session.entropy);
        m.mbedtls_ssl_free(&session.ssl);
        m.mbedtls_ssl_config_free(&session.ssl_conf);
        m.mbedtls_x509_crt_free(&session.crt);
    }

    pub fn setPeerFingerprint(session: *Session, fingerprint: *const [32]u8) void {
        @memcpy(&session.peer_fingerprint, fingerprint);
    }

    pub fn handleData(session: *Session, data: ?[]const u8) !void {
        switch (session.connection_state) {
            .new => {
                session.connection_state = .connecting;
                try session.handleData(data);
            },
            .connecting => {
                session.received_data = data;
                try session.handshake();
            },
            .connected => {
                if (data == null) return;
                session.received_data = data;

                var buffer: [1400]u8 = @splat(0);
                const ret = m.mbedtls_ssl_read(&session.ssl, (&buffer).ptr, buffer.len);
                if (ret > 0) {
                    // Received answer
                } else switch (ret) {
                    m.MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY => {
                        Logger.warn("Peer closed connection", .{});
                        session.connection_state = .closed;
                    },
                    m.MBEDTLS_ERR_SSL_WANT_READ, m.MBEDTLS_ERR_SSL_WANT_WRITE => {},
                    else => |err_code| {
                        m.mbedtls_strerror(err_code, buffer[0..].ptr, buffer.len);
                        Logger.err("Error: {s}", .{buffer});
                    },
                }
            },
            else => return error.InvalidState,
        }
    }

    pub fn handleTimeout(session: *Session) !void {
        try session.handshake();
    }

    pub fn exportSrtpKeyingMaterial(session: *Session) !SrtpProfile {
        var profile: m.mbedtls_dtls_srtp_info = .{};
        m.mbedtls_ssl_get_dtls_srtp_negotiation_result(&session.ssl, &profile);
        errdefer {
            _ = m.mbedtls_ssl_close_notify(&session.ssl);
            session.connection_state = .failed;
        }

        switch (profile.private_chosen_dtls_srtp_profile) {
            m.MBEDTLS_TLS_SRTP_AES128_CM_HMAC_SHA1_80, m.MBEDTLS_TLS_SRTP_AES128_CM_HMAC_SHA1_32 => |value| {
                var keying_material: [60]u8 = undefined;

                const ret = m.mbedtls_ssl_tls_prf(
                    session.session_keys.tls_profile,
                    session.session_keys.master_secret.ptr,
                    session.session_keys.master_secret.len,
                    KEYINIG_EXTRACTOR_LABEL,
                    session.session_keys.rand_bytes[0..].ptr,
                    session.session_keys.rand_bytes.len,
                    &keying_material,
                    keying_material.len,
                );
                if (ret != 0) return error.ExportKeyingMaterialFailed;

                var srtp_profile: SrtpProfile = undefined;
                srtp_profile.profile = value;
                if (m.mbedtls_ssl_conf_get_endpoint(&session.ssl_conf) == m.MBEDTLS_SSL_IS_SERVER) {
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

    pub fn getFingerprint(session: *Session, fingerprint: *[32]u8) void {
        const cert = session.crt.raw.p[0..session.crt.raw.len];
        Sha256.hash(cert, fingerprint, .{});
    }

    pub fn close(session: *Session) void {
        _ = m.mbedtls_ssl_close_notify(&session.ssl);
    }

    fn createCertificate(session: *Session, io: std.Io) !void {
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
        io.random(&serial);
        serial[0] = (serial[0] & 0x7F) | 0x01;
        ret = m.mbedtls_x509write_crt_set_serial_raw(&cert, serial[0..].ptr, serial.len);
        try checkError(ret);

        ret = m.mbedtls_x509write_crt_set_subject_name(&cert, "CN=Zig WebRTC");
        try checkError(ret);
        ret = m.mbedtls_x509write_crt_set_issuer_name(&cert, "CN=Zig WebRTC");
        try checkError(ret);

        var buffer: [4096]u8 = @splat(0);
        ret = m.mbedtls_x509write_crt_der(&cert, buffer[0..].ptr, buffer.len, random, &session.io);
        try checkError(ret);

        const len: u32 = @bitCast(ret);
        const certificate = buffer[buffer.len - len ..];
        ret = m.mbedtls_x509_crt_parse_der(&session.crt, certificate.ptr, certificate.len);
        try checkError(ret);
    }

    fn handshake(session: *Session) !void {
        const result = switch (m.mbedtls_ssl_handshake(&session.ssl)) {
            0 => session.connection_state = .connected,
            m.MBEDTLS_ERR_SSL_WANT_READ, m.MBEDTLS_ERR_SSL_WANT_WRITE => error.WantData,
            else => |err_code| {
                var error_buffer: [1024]u8 = undefined;
                m.mbedtls_strerror(err_code, error_buffer[0..].ptr, error_buffer.len);
                Logger.err("Handshake failed: {s}", .{error_buffer});

                session.connection_state = .failed;
                return if (err_code == m.MBEDTLS_ERR_SSL_TIMEOUT) error.Timeout else error.HandshakeFailed;
            },
        };

        session.on_set_timer(session, session.handshake_timer_value.@"0", session.handshake_timer_value.@"1");
        return result;
    }

    fn sendData(ctx: ?*anyopaque, buf: [*c]const u8, len: usize) callconv(.c) i32 {
        const session: *Session = @ptrCast(@alignCast(ctx.?));
        return session.on_send_data(session, buf[0..len]);
    }

    fn recvData(ctx: ?*anyopaque, buf: [*c]u8, len: usize) callconv(.c) i32 {
        return recvDataTimeout(ctx, buf, len, 0);
    }

    fn recvDataTimeout(ctx: ?*anyopaque, buf: [*c]u8, len: usize, timeout: u32) callconv(.c) i32 {
        _ = timeout;

        const session: *Session = @ptrCast(@alignCast(ctx.?));
        if (session.received_data) |data| {
            std.debug.assert(data.len <= len);
            @memcpy(buf[0..data.len], data);
            session.received_data = null;
            return @intCast(data.len);
        }

        return m.MBEDTLS_ERR_SSL_WANT_READ;
    }

    fn setTimer(ctx: ?*anyopaque, int_ms: u32, fin_ms: u32) callconv(.c) void {
        const session: *Session = @ptrCast(@alignCast(ctx.?));
        session.handshake_timer_value = .{ int_ms, fin_ms };
    }

    fn getTimer(ctx: ?*anyopaque) callconv(.c) i32 {
        const session: *Session = @ptrCast(@alignCast(ctx.?));
        return session.on_get_timer_state(session);
    }

    fn verifyCertificateFingerprint(ctx: ?*anyopaque, crt: [*c]m.mbedtls_x509_crt, flag: c_int, cn: [*c]u32) callconv(.c) i32 {
        _ = flag;
        _ = cn;

        const session: *Session = @ptrCast(@alignCast(ctx.?));
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

        const session: *Session = @ptrCast(@alignCast(ctx.?));
        const max_dtls_random_bytes = 32;

        session.session_keys = .{
            .master_secret = secret[0..secret_len],
            .rand_bytes = @splat(0),
            .tls_profile = tls_prf_type,
        };

        @memcpy(session.session_keys.rand_bytes[0..max_dtls_random_bytes], client_random[0..max_dtls_random_bytes]);
        @memcpy(session.session_keys.rand_bytes[max_dtls_random_bytes..], server_random[0..max_dtls_random_bytes]);
    }

    fn random(ctx: ?*anyopaque, data: [*c]u8, len: usize) callconv(.c) c_int {
        const io: *std.Io = @ptrCast(@alignCast(ctx));
        io.randomSecure(data[0..len]) catch return m.PSA_ERROR_INSUFFICIENT_ENTROPY;
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
