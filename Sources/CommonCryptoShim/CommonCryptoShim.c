#include "CommonCryptoShim.h"

#include <CommonCrypto/CommonCryptor.h>
#include <CommonCrypto/CommonKeyDerivation.h>

int cq_pbkdf2_sha1(
    const uint8_t *password,
    size_t passwordLength,
    const uint8_t *salt,
    size_t saltLength,
    unsigned int rounds,
    uint8_t *derivedKey,
    size_t derivedKeyLength) {
    return CCKeyDerivationPBKDF(
        kCCPBKDF2,
        (const char *)password,
        passwordLength,
        salt,
        saltLength,
        kCCPRFHmacAlgSHA1,
        rounds,
        derivedKey,
        derivedKeyLength);
}

int cq_aes_128_cbc_decrypt_pkcs7(
    const uint8_t *key,
    const uint8_t *iv,
    const uint8_t *ciphertext,
    size_t ciphertextLength,
    uint8_t *plaintext,
    size_t plaintextCapacity,
    size_t *plaintextLength) {
    return CCCrypt(
        kCCDecrypt,
        kCCAlgorithmAES,
        kCCOptionPKCS7Padding,
        key,
        kCCKeySizeAES128,
        iv,
        ciphertext,
        ciphertextLength,
        plaintext,
        plaintextCapacity,
        plaintextLength);
}
