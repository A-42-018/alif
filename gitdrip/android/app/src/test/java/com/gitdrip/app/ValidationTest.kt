package com.gitdrip.app

import com.gitdrip.app.data.validateProject
import org.junit.Assert.*
import org.junit.Test

class ValidationTest {
    @Test fun validOk() = assertNull(validateProject("my-app", "https://github.com/me/my-app", "main"))
    @Test fun emptyRepoOk() = assertNull(validateProject("a", "", "main"))
    @Test fun upperNameRejected() = assertNotNull(validateProject("MyApp", "", "main"))
    @Test fun credsInUrlRejected() =
        assertNotNull(validateProject("a", "https://user:tok@github.com/me/x", "main"))
    @Test fun nonGithubRejected() = assertNotNull(validateProject("a", "https://evil.com/me/x", "main"))
    @Test fun badBranchRejected() = assertNotNull(validateProject("a", "", "bad branch"))
}
