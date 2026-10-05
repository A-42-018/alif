package com.gitdrip.app

import com.gitdrip.app.data.*
import org.junit.Assert.*
import org.junit.Test

class GitHubTest {
    private fun repoJson(n: String, fork: Boolean = false, arch: Boolean = false, push: Boolean = true) =
        """{"full_name":"alif/$n","private":true,"fork":$fork,"archived":$arch,"default_branch":"main","push":$push}"""

    @Test fun parsesAccount() {
        val r = parseAccount("""{"state":"OK","data":{"login":"alif","noreply_email":"42+alif@users.noreply.github.com","token_kind":"classic","user_matches":false}}""")!!
        assertEquals("alif", r.data!!.login); assertFalse(r.data!!.userMatches); assertEquals("classic", r.data!!.tokenKind)
    }
    @Test fun errorResultCarriesClassAndReason() {
        val r = parseRepos("""{"state":"ERROR","reason":"bad or expired token","error_class":"auth"}""")!!
        assertNull(r.data); assertEquals("auth", r.errorClass); assertEquals("bad or expired token", r.error)
        assertTrue(ghHint(r.errorClass).contains("gitdrip auth set"))
    }
    @Test fun notFinalOrGarbageIsNull() {
        assertNull(parseRepos("""{"state":"RUNNING"}""")); assertNull(parseRepos("{half")); assertNull(parseAccount(""))
    }
    @Test fun parsesReposAndEligibility() {
        val l = parseRepos("""{"state":"OK","data":[${repoJson("a")},${repoJson("f", fork = true)},${repoJson("o", arch = true)},${repoJson("r", push = false)}]}""")!!.data!!
        assertEquals(listOf(true, false, false, false), l.map { it.eligible })
        assertEquals("https://github.com/alif/a", l[0].url); assertTrue(l[0].isPrivate)
    }
    @Test fun filterHidesIneligibleUnlessAsked() {
        val l = parseRepos("""{"state":"OK","data":[${repoJson("site")},${repoJson("site-fork", fork = true)},${repoJson("blog")}]}""")!!.data!!
        assertEquals(listOf("alif/site", "alif/blog"), filterRepos(l, "", true).map { it.fullName })
        assertEquals(listOf("alif/site", "alif/site-fork"), filterRepos(l, " SITE ", false).map { it.fullName })
    }
    @Test fun parsesBranchesDefaultFirst() {
        val b = parseBranches("""{"state":"OK","data":{"default_branch":"main","branches":[{"name":"main","default":true},{"name":"dev","default":false}]}}""")!!.data!!
        assertEquals("main", b.defaultBranch); assertEquals(listOf("main", "dev"), b.names)
    }
}
