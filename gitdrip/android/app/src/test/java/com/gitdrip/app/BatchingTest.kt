package com.gitdrip.app

import com.gitdrip.app.data.*
import org.junit.Assert.*
import org.junit.Test

class BatchingTest {
    private fun f(p: String) = FileEntry(p, 1, "x")

    @Test fun secretsDetected() {
        listOf(".env", "a/.env.local", "id_rsa", "k/server.pem", "app.keystore").forEach { assertTrue(it, isSecretPath(it)) }
        listOf(".env.example", "src/Main.kt", "README.md").forEach { assertFalse(it, isSecretPath(it)) }
    }

    @Test fun skippedDirs() {
        assertTrue(isSkippedPath("a/node_modules/x.js")); assertTrue(isSkippedPath(".git/config"))
        assertFalse(isSkippedPath("src/gitignore.txt"))
    }

    @Test fun sanitize() {
        assertEquals("a/b.txt", sanitizePath("./a//b.txt"))
        listOf("../x", "a/../../x", "/etc/passwd", "a\\b", "", ".").forEach { assertNull(it, sanitizePath(it)) }
    }

    @Test fun groupsByDirAndCaps() {
        val files = (1..7).map { f("src/f$it.kt") } + f("README.md") + f("docs/a.md") + f("docs/b.md")
        val b = suggestBatches(files, 5)
        assertEquals(4, b.size)
        assertTrue(b.all { it.paths.size <= 5 })
        assertEquals(listOf("docs: add project root files", "docs: add docs module", "feat: add src module (part 1/2)", "feat: add src module (part 2/2)"), b.map { it.message })
    }

    @Test fun secretsNeverBatched() {
        val b = suggestBatches(listOf(f(".env"), f("a/key.pem"), f("a/ok.kt")))
        assertEquals(listOf("a/ok.kt"), b.flatMap { it.paths })
    }

    @Test fun testKind() = assertEquals("test: add t module", suggestBatches(listOf(f("t/AppTest.kt"), f("t/b_spec.kt")))[0].message)

    @Test fun noDuplicatesAcrossBatches() {
        val files = (1..12).map { f("m/f$it") }
        val all = suggestBatches(files, 5).flatMap { it.paths }
        assertEquals(all.size, all.toSet().size); assertEquals(12, all.size)
    }

    @Test fun moveSwaps() {
        assertEquals(listOf(2, 1, 3), listOf(1, 2, 3).moved(0, 1))
        assertEquals(listOf(1, 2, 3), listOf(1, 2, 3).moved(0, -1))
        assertEquals(listOf(1, 2, 3), listOf(1, 2, 3).moved(2, 1))
    }
}
