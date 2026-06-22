const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const protocols = b.dependency("protocols", .{ .target = target, .optimize = optimize });
    const mbedtls = b.dependency("mbedtls", .{ .target = target, .optimize = optimize });

    const config_header = mbedtls_config(b);

    const mbedtls_artifact = mbedtls.artifact("mbedtls");
    mbedtls_artifact.root_module.addCMacro("MBEDTLS_CONFIG_FILE", b.fmt("\"{s}\"", .{config_header.include_path}));
    mbedtls_artifact.root_module.addIncludePath(config_header.getOutputDir());

    const mod = b.addModule("webrtc", .{
        .root_source_file = b.path("src/webrtc.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sdp", .module = protocols.module("sdp") },
            .{ .name = "ice", .module = protocols.module("ice") },
            .{ .name = "rtp", .module = protocols.module("rtp") },
            .{ .name = "rtcp", .module = protocols.module("rtcp") },
            .{ .name = "srtp", .module = protocols.module("srtp") },
        },
    });

    mod.linkLibrary(mbedtls_artifact);
    mod.addIncludePath(config_header.getOutputDir());

    if (target.result.os.tag == .windows) {
        mod.linkSystemLibrary("ws2_32", .{});
    }

    {
        const mod_tests = b.addTest(.{ .root_module = mod });
        const run_mod_tests = b.addRunArtifact(mod_tests);

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_mod_tests.step);
    }

fn mbedtls_config(b: *std.Build) *std.Build.Step.ConfigHeader {
    return b.addConfigHeader(.{
        .style = .blank,
        .include_path = "config.h",
    }, .{
        .MBEDTLS_HAVE_ASM = {},
        .MBEDTLS_HAVE_TIME = {},
        .MBEDTLS_HAVE_TIME_DATE = {},

        .MBEDTLS_CIPHER_MODE_CBC = {},
        .MBEDTLS_CIPHER_MODE_CFB = {},
        .MBEDTLS_CIPHER_MODE_CTR = {},
        .MBEDTLS_CIPHER_MODE_OFB = {},
        .MBEDTLS_CIPHER_MODE_XTS = {},

        .MBEDTLS_CIPHER_PADDING_PKCS7 = {},
        .MBEDTLS_CIPHER_PADDING_ONE_AND_ZEROS = {},
        .MBEDTLS_CIPHER_PADDING_ZEROS_AND_LEN = {},
        .MBEDTLS_CIPHER_PADDING_ZEROS = {},

        .MBEDTLS_ECP_DP_SECP192R1_ENABLED = {},
        .MBEDTLS_ECP_DP_SECP224R1_ENABLED = {},
        .MBEDTLS_ECP_DP_SECP256R1_ENABLED = {},
        .MBEDTLS_ECP_DP_SECP384R1_ENABLED = {},
        .MBEDTLS_ECP_DP_SECP521R1_ENABLED = {},
        .MBEDTLS_ECP_DP_SECP192K1_ENABLED = {},
        .MBEDTLS_ECP_DP_SECP224K1_ENABLED = {},
        .MBEDTLS_ECP_DP_SECP256K1_ENABLED = {},
        .MBEDTLS_ECP_DP_BP256R1_ENABLED = {},
        .MBEDTLS_ECP_DP_BP384R1_ENABLED = {},
        .MBEDTLS_ECP_DP_BP512R1_ENABLED = {},
        .MBEDTLS_ECP_DP_CURVE25519_ENABLED = {},
        .MBEDTLS_ECP_DP_CURVE448_ENABLED = {},
        .MBEDTLS_ECP_NIST_OPTIM = {},

        .MBEDTLS_ECDSA_DETERMINISTIC = {},
        .MBEDTLS_KEY_EXCHANGE_PSK_ENABLED = {},
        .MBEDTLS_KEY_EXCHANGE_DHE_PSK_ENABLED = {},
        .MBEDTLS_KEY_EXCHANGE_ECDHE_PSK_ENABLED = {},
        .MBEDTLS_KEY_EXCHANGE_RSA_PSK_ENABLED = {},
        .MBEDTLS_KEY_EXCHANGE_RSA_ENABLED = {},
        .MBEDTLS_KEY_EXCHANGE_DHE_RSA_ENABLED = {},
        .MBEDTLS_KEY_EXCHANGE_ECDHE_RSA_ENABLED = {},
        .MBEDTLS_KEY_EXCHANGE_ECDHE_ECDSA_ENABLED = {},
        .MBEDTLS_KEY_EXCHANGE_ECDH_ECDSA_ENABLED = {},
        .MBEDTLS_KEY_EXCHANGE_ECDH_RSA_ENABLED = {},

        .MBEDTLS_PK_PARSE_EC_EXTENDED = {},
        .MBEDTLS_PK_PARSE_EC_COMPRESSED = {},
        .MBEDTLS_ERROR_STRERROR_DUMMY = {},
        .MBEDTLS_GENPRIME = {},
        .MBEDTLS_FS_IO = {},

        .MBEDTLS_PK_RSA_ALT_SUPPORT = {},
        .MBEDTLS_PKCS1_V15 = {},
        .MBEDTLS_PKCS1_V21 = {},

        .MBEDTLS_SSL_ALL_ALERT_MESSAGES = {},
        .MBEDTLS_SSL_DTLS_CONNECTION_ID = {},
        .MBEDTLS_SSL_DTLS_CONNECTION_ID_COMPAT = 0,

        .MBEDTLS_SSL_CONTEXT_SERIALIZATION = {},

        .MBEDTLS_SSL_ENCRYPT_THEN_MAC = {},
        .MBEDTLS_SSL_EXTENDED_MASTER_SECRET = {},
        .MBEDTLS_SSL_KEYING_MATERIAL_EXPORT = {},
        .MBEDTLS_SSL_RENEGOTIATION = {},
        .MBEDTLS_SSL_MAX_FRAGMENT_LENGTH = {},

        .MBEDTLS_SSL_PROTO_TLS1_2 = {},

        .MBEDTLS_SSL_PROTO_DTLS = {},
        .MBEDTLS_SSL_ALPN = {},
        .MBEDTLS_SSL_DTLS_ANTI_REPLAY = {},
        .MBEDTLS_SSL_DTLS_SRTP = {},

        .MBEDTLS_AESNI_C = {},
        .MBEDTLS_AESCE_C = {},
        .MBEDTLS_AES_C = {},
        .MBEDTLS_ASN1_PARSE_C = {},
        .MBEDTLS_ASN1_WRITE_C = {},
        .MBEDTLS_BASE64_C = {},

        .MBEDTLS_OID_C = {},
        .MBEDTLS_PADLOCK_C = {},
        .MBEDTLS_PEM_PARSE_C = {},
        .MBEDTLS_PEM_WRITE_C = {},
        .MBEDTLS_PK_C = {},
        .MBEDTLS_PK_PARSE_C = {},
        .MBEDTLS_PK_WRITE_C = {},
        .MBEDTLS_PKCS5_C = {},
        .MBEDTLS_PKCS7_C = {},
        .MBEDTLS_PKCS12_C = {},
        .MBEDTLS_PLATFORM_C = {},
        .MBEDTLS_POLY1305_C = {},
        .MBEDTLS_PSA_CRYPTO_C = {},

        .MBEDTLS_BIGNUM_C = {},
        .MBEDTLS_CAMELLIA_C = {},
        .MBEDTLS_ARIA_C = {},
        .MBEDTLS_CCM_C = {},
        .MBEDTLS_CHACHA20_C = {},
        .MBEDTLS_CHACHAPOLY_C = {},
        .MBEDTLS_CIPHER_C = {},
        .MBEDTLS_CMAC_C = {},
        .MBEDTLS_CTR_DRBG_C = {},
        .MBEDTLS_DEBUG_C = {},
        .MBEDTLS_DES_C = {},
        .MBEDTLS_DHM_C = {},
        .MBEDTLS_ECDH_C = {},
        .MBEDTLS_ECDSA_C = {},
        .MBEDTLS_ECJPAKE_C = {},
        .MBEDTLS_ECP_C = {},
        .MBEDTLS_ENTROPY_C = {},
        .MBEDTLS_ERROR_C = {},
        .MBEDTLS_GCM_C = {},

        .MBEDTLS_RIPEMD160_C = {},
        .MBEDTLS_RSA_C = {},
        .MBEDTLS_SHA1_C = {},
        .MBEDTLS_SHA224_C = {},
        .MBEDTLS_SHA256_C = {},
        .MBEDTLS_SHA384_C = {},
        .MBEDTLS_SHA512_C = {},
        .MBEDTLS_SHA3_C = {},

        .MBEDTLS_TIMING_C = {},
        .MBEDTLS_VERSION_C = {},

        .MBEDTLS_HKDF_C = {},
        .MBEDTLS_HMAC_DRBG_C = {},
        .MBEDTLS_LMS_C = {},

        .MBEDTLS_SSL_SESSION_TICKETS = {},
        .MBEDTLS_SSL_SERVER_NAME_INDICATION = {},

        .MBEDTLS_VERSION_FEATURES = {},

        .MBEDTLS_NIST_KW_C = {},
        .MBEDTLS_MD_C = {},
        .MBEDTLS_MD5_C = {},

        .MBEDTLS_PSA_CRYPTO_STORAGE_C = {},
        .MBEDTLS_PSA_ITS_FILE_C = {},

        .MBEDTLS_SSL_CACHE_C = {},
        .MBEDTLS_SSL_COOKIE_C = {},
        .MBEDTLS_SSL_TICKET_C = {},
        .MBEDTLS_SSL_CLI_C = {},
        .MBEDTLS_SSL_SRV_C = {},
        .MBEDTLS_SSL_TLS_C = {},

        .MBEDTLS_X509_USE_C = {},
        .MBEDTLS_X509_CRT_PARSE_C = {},
        .MBEDTLS_X509_CRL_PARSE_C = {},
        .MBEDTLS_X509_CSR_PARSE_C = {},
        .MBEDTLS_X509_CREATE_C = {},
        .MBEDTLS_X509_CRT_WRITE_C = {},
        .MBEDTLS_X509_CSR_WRITE_C = {},
    });
}
