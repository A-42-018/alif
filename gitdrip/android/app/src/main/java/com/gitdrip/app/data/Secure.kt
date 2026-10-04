package com.gitdrip.app.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/**
 * One-time token handoff app -> Termux (P14). Pure JVM, no Android.
 * The app writes `<GitDrip>/handoff/<req>.enc` (shared storage, so ciphertext only) and sends the random 256-bit key
 * to Termux as the Intent argument of `bridge <req> auth-handoff <user> <key>`. Engine decrypts with
 * `openssl enc -d -aes-256-cbc -pbkdf2 -md sha256 -iter 10000`, stores the token (chmod 600) and deletes the file.
 * The key is useless once the file is gone; the token itself never appears in argv, results, logs or shared storage.
 */
object Handoff {
    const val ITER = 10_000
    private val TOKEN_RE = Regex("^(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,})$")   // same as engine _token_valid
    private val USER_RE = Regex("^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$")                                // same as engine auth_set

    fun validToken(t: String) = TOKEN_RE.matches(t)
    fun validUser(u: String) = USER_RE.matches(u)

    fun newKeyHex(rnd: SecureRandom = SecureRandom()): String =
        ByteArray(32).also(rnd::nextBytes).joinToString("") { "%02x".format(it) }

    /** openssl `enc` file format: "Salted__" + 8-byte salt + AES-256-CBC(PKCS7) with key/iv = PBKDF2-HMAC-SHA256(keyHex, salt, 10000)[0..48). */
    fun encrypt(token: String, keyHex: String, salt: ByteArray = ByteArray(8).also { SecureRandom().nextBytes(it) }): ByteArray {
        require(salt.size == 8 && Regex("^[0-9a-f]{64}$").matches(keyHex) && validToken(token)) { "bad handoff input" }
        val dk = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(PBEKeySpec(keyHex.toCharArray(), salt, ITER, 48 * 8)).encoded
        val c = Cipher.getInstance("AES/CBC/PKCS5Padding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(dk, 0, 32, "AES"), IvParameterSpec(dk, 32, 16))
        return "Salted__".toByteArray(Charsets.US_ASCII) + salt + c.doFinal(token.toByteArray(Charsets.UTF_8))
    }

    fun handoffFile(c: Context, req: String) = File(Importer.baseDir(c), "handoff/$req.enc")
}

/**
 * Optional "remember on this device": token encrypted with a non-exportable AndroidKeyStore AES-256-GCM key, blob in app-private
 * filesDir (iv(12) + ciphertext). No user-auth requirement on purpose: alarms run unattended and only Termux needs the token.
 * allowBackup=false, so the blob never leaves the device; the key never leaves the Keystore.
 */
object Vault {
    private const val ALIAS = "gitdrip_token_v1"
    private fun blob(c: Context) = File(c.filesDir, "vault.bin")

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val g = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        g.init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).build())
        return g.generateKey()
    }

    fun has(c: Context) = blob(c).isFile

    fun save(c: Context, token: String) {
        val ci = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val tmp = File(c.filesDir, "vault.tmp")
        tmp.writeBytes(ci.iv + ci.doFinal(token.toByteArray(Charsets.UTF_8))); tmp.renameTo(blob(c))
    }

    /** Null when absent or undecryptable (key lost after a lock-screen reset / restore): the user simply re-enters the token. */
    fun load(c: Context): String? = try {
        val b = blob(c).readBytes()
        val ci = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, b.copyOfRange(0, 12))) }
        String(ci.doFinal(b, 12, b.size - 12), Charsets.UTF_8)
    } catch (e: Exception) { null }

    fun clear(c: Context) {
        blob(c).delete()
        try { KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(ALIAS) } catch (e: Exception) { }
    }
}
