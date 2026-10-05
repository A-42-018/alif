package com.gitdrip.app

import com.gitdrip.app.data.Handoff
import com.gitdrip.app.data.redact
import org.junit.Assert.*
import org.junit.Test
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

class HandoffTest {
    private val tok = "ghp_" + "a".repeat(36)
    private val key = "0123456789abcdef".repeat(4)
    private val salt = byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8)

    @Test fun matchesOpensslKnownAnswer() {   // vector produced by: openssl enc -aes-256-cbc -pbkdf2 -md sha256 -iter 10000 -S 0102030405060708
        val blob = Handoff.encrypt(tok, key, salt)
        assertEquals("Salted__", String(blob, 0, 8, Charsets.US_ASCII))
        assertArrayEquals(salt, blob.copyOfRange(8, 16))
        assertEquals("AG8rVV9dwDr0o/l4KO5LErVqcEBualVY6xnbeKQ8066N1cgPpq5P7cCoT7ufMpql", Base64.getEncoder().encodeToString(blob.copyOfRange(16, blob.size)))
    }
    @Test fun roundTripsAndHidesToken() {
        val blob = Handoff.encrypt(tok, key)
        assertFalse(String(blob, Charsets.ISO_8859_1).contains(tok))
        val dk = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(PBEKeySpec(key.toCharArray(), blob.copyOfRange(8, 16), Handoff.ITER, 384)).encoded
        val c = Cipher.getInstance("AES/CBC/PKCS5Padding").apply { init(Cipher.DECRYPT_MODE, SecretKeySpec(dk, 0, 32, "AES"), IvParameterSpec(dk, 32, 16)) }
        assertEquals(tok, String(c.doFinal(blob, 16, blob.size - 16)))
    }
    @Test fun saltIsRandomPerCall() = assertFalse(Handoff.encrypt(tok, key).contentEquals(Handoff.encrypt(tok, key)))
    @Test fun keysAre256BitHexAndUnique() {
        val a = Handoff.newKeyHex(); val b = Handoff.newKeyHex()
        assertTrue(Regex("^[0-9a-f]{64}$").matches(a)); assertNotEquals(a, b)
    }
    @Test fun validatesLikeTheEngine() {
        assertTrue(Handoff.validToken(tok)); assertTrue(Handoff.validToken("github_pat_" + "A1_".repeat(20)))
        assertFalse(Handoff.validToken("ghp_short")); assertFalse(Handoff.validToken("$tok\n")); assertFalse(Handoff.validToken(" $tok"))
        assertTrue(Handoff.validUser("octo-cat")); assertFalse(Handoff.validUser("-bad")); assertFalse(Handoff.validUser("a b")); assertFalse(Handoff.validUser(""))
    }
    @Test fun refusesBadInput() {
        assertThrows(IllegalArgumentException::class.java) { Handoff.encrypt("nope", key) }
        assertThrows(IllegalArgumentException::class.java) { Handoff.encrypt(tok, "xyz") }
        assertThrows(IllegalArgumentException::class.java) { Handoff.encrypt(tok, key, ByteArray(4)) }
    }
    @Test fun redactHidesHandoffKeyOnACommandLine() {
        assertFalse(redact("gitdrip bridge r1 auth-handoff octocat $key").contains(key))
    }
}
