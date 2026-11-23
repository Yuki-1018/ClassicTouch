/*
 * QEMU Crypto cipher OpenSSL algorithms
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "cipherpriv.h"

#include <openssl/evp.h>

static const EVP_CIPHER *qcrypto_openssl_evp(QCryptoCipherAlgo alg,
                                             QCryptoCipherMode mode)
{
    switch (mode) {
    case QCRYPTO_CIPHER_MODE_ECB:
        switch (alg) {
        case QCRYPTO_CIPHER_ALGO_AES_128: return EVP_aes_128_ecb();
        case QCRYPTO_CIPHER_ALGO_AES_192: return EVP_aes_192_ecb();
        case QCRYPTO_CIPHER_ALGO_AES_256: return EVP_aes_256_ecb();
        case QCRYPTO_CIPHER_ALGO_3DES:    return EVP_des_ede3_ecb();
        default:                          return NULL;
        }
    case QCRYPTO_CIPHER_MODE_CBC:
        switch (alg) {
        case QCRYPTO_CIPHER_ALGO_AES_128: return EVP_aes_128_cbc();
        case QCRYPTO_CIPHER_ALGO_AES_192: return EVP_aes_192_cbc();
        case QCRYPTO_CIPHER_ALGO_AES_256: return EVP_aes_256_cbc();
        case QCRYPTO_CIPHER_ALGO_3DES:    return EVP_des_ede3_cbc();
        default:                          return NULL;
        }
    case QCRYPTO_CIPHER_MODE_CTR:
        switch (alg) {
        case QCRYPTO_CIPHER_ALGO_AES_128: return EVP_aes_128_ctr();
        case QCRYPTO_CIPHER_ALGO_AES_192: return EVP_aes_192_ctr();
        case QCRYPTO_CIPHER_ALGO_AES_256: return EVP_aes_256_ctr();
        default:                          return NULL;
        }
    case QCRYPTO_CIPHER_MODE_XTS:
        switch (alg) {
        case QCRYPTO_CIPHER_ALGO_AES_128: return EVP_aes_128_xts();
        case QCRYPTO_CIPHER_ALGO_AES_256: return EVP_aes_256_xts();
        default:                          return NULL;
        }
    default:
        return NULL;
    }
}

bool qcrypto_cipher_supports(QCryptoCipherAlgo alg,
                             QCryptoCipherMode mode)
{
    return qcrypto_openssl_evp(alg, mode) != NULL;
}

typedef struct QCryptoCipherOpenSSL QCryptoCipherOpenSSL;
struct QCryptoCipherOpenSSL {
    QCryptoCipher base;
    EVP_CIPHER_CTX *enc_ctx;
    EVP_CIPHER_CTX *dec_ctx;
    size_t blocksize;
};

static void qcrypto_openssl_cipher_free(QCryptoCipher *cipher)
{
    QCryptoCipherOpenSSL *ctx = container_of(cipher, QCryptoCipherOpenSSL, base);
    if (ctx->enc_ctx) {
        EVP_CIPHER_CTX_free(ctx->enc_ctx);
    }
    if (ctx->dec_ctx) {
        EVP_CIPHER_CTX_free(ctx->dec_ctx);
    }
    g_free(ctx);
}

static int qcrypto_openssl_cipher_encrypt(QCryptoCipher *cipher,
                                          const void *in,
                                          void *out,
                                          size_t len,
                                          Error **errp)
{
    QCryptoCipherOpenSSL *ctx = container_of(cipher, QCryptoCipherOpenSSL, base);
    if (len % ctx->blocksize) {
        error_setg(errp, "Length %zu must be a multiple of block size %zu",
                   len, ctx->blocksize);
        return -1;
    }
    int outl = 0;
    if (EVP_EncryptUpdate(ctx->enc_ctx, out, &outl, in, (int)len) != 1) {
        error_setg(errp, "OpenSSL EVP_EncryptUpdate failed");
        return -1;
    }
    return 0;
}

static int qcrypto_openssl_cipher_decrypt(QCryptoCipher *cipher,
                                          const void *in,
                                          void *out,
                                          size_t len,
                                          Error **errp)
{
    QCryptoCipherOpenSSL *ctx = container_of(cipher, QCryptoCipherOpenSSL, base);
    if (len % ctx->blocksize) {
        error_setg(errp, "Length %zu must be a multiple of block size %zu",
                   len, ctx->blocksize);
        return -1;
    }
    int outl = 0;
    if (EVP_DecryptUpdate(ctx->dec_ctx, out, &outl, in, (int)len) != 1) {
        error_setg(errp, "OpenSSL EVP_DecryptUpdate failed");
        return -1;
    }
    return 0;
}

static int qcrypto_openssl_cipher_setiv(QCryptoCipher *cipher,
                                        const uint8_t *iv, size_t niv,
                                        Error **errp)
{
    QCryptoCipherOpenSSL *ctx = container_of(cipher, QCryptoCipherOpenSSL, base);
    if (niv != ctx->blocksize) {
        error_setg(errp, "Expected IV size %zu not %zu",
                   ctx->blocksize, niv);
        return -1;
    }
    if (EVP_EncryptInit_ex(ctx->enc_ctx, NULL, NULL, NULL, iv) != 1 ||
        EVP_DecryptInit_ex(ctx->dec_ctx, NULL, NULL, NULL, iv) != 1) {
        error_setg(errp, "OpenSSL set IV failed");
        return -1;
    }
    EVP_CIPHER_CTX_set_padding(ctx->enc_ctx, 0);
    EVP_CIPHER_CTX_set_padding(ctx->dec_ctx, 0);
    return 0;
}

static const QCryptoCipherDriver qcrypto_cipher_openssl_driver = {
    .cipher_encrypt = qcrypto_openssl_cipher_encrypt,
    .cipher_decrypt = qcrypto_openssl_cipher_decrypt,
    .cipher_setiv = qcrypto_openssl_cipher_setiv,
    .cipher_free = qcrypto_openssl_cipher_free,
};

static QCryptoCipher *qcrypto_cipher_ctx_new(QCryptoCipherAlgo alg,
                                             QCryptoCipherMode mode,
                                             const uint8_t *key,
                                             size_t nkey,
                                             Error **errp)
{
    if (!qcrypto_cipher_validate_key_length(alg, mode, nkey, errp)) {
        return NULL;
    }

    const EVP_CIPHER *evp = qcrypto_openssl_evp(alg, mode);
    if (!evp) {
        error_setg(errp, "Unsupported cipher algorithm %s with mode %s",
                   QCryptoCipherAlgo_str(alg), QCryptoCipherMode_str(mode));
        return NULL;
    }

    QCryptoCipherOpenSSL *ctx = g_new0(QCryptoCipherOpenSSL, 1);
    ctx->base.driver = &qcrypto_cipher_openssl_driver;
    ctx->blocksize = alg_block_len[alg];
    ctx->enc_ctx = EVP_CIPHER_CTX_new();
    ctx->dec_ctx = EVP_CIPHER_CTX_new();
    if (!ctx->enc_ctx || !ctx->dec_ctx) {
        error_setg(errp, "Failed to allocate OpenSSL EVP_CIPHER_CTX");
        qcrypto_openssl_cipher_free(&ctx->base);
        return NULL;
    }

    uint8_t zero_iv[16] = {0};
    const uint8_t *init_iv = mode_need_iv[mode] ? zero_iv : NULL;
    if (EVP_EncryptInit_ex(ctx->enc_ctx, evp, NULL, key, init_iv) != 1 ||
        EVP_DecryptInit_ex(ctx->dec_ctx, evp, NULL, key, init_iv) != 1) {
        error_setg(errp, "Failed to initialize OpenSSL cipher context");
        qcrypto_openssl_cipher_free(&ctx->base);
        return NULL;
    }
    EVP_CIPHER_CTX_set_padding(ctx->enc_ctx, 0);
    EVP_CIPHER_CTX_set_padding(ctx->dec_ctx, 0);
    return &ctx->base;
}
