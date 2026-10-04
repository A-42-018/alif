package com.gitdrip.app.data

import org.json.JSONArray
import org.json.JSONObject

class GhRepo(val fullName: String, val isPrivate: Boolean, val fork: Boolean, val archived: Boolean, val defaultBranch: String, val push: Boolean) {
    val url get() = "https://github.com/$fullName"
    /** Contributions only count on writable, non-archived, non-fork repos. */
    val eligible get() = !fork && !archived && push
}
class GhAccount(val login: String, val noreplyEmail: String, val tokenKind: String, val userMatches: Boolean)
class GhBranches(val defaultBranch: String, val names: List<String>)
/** [data] != null = success; otherwise [error]/[errorClass] (auth|ratelimit|notfound|transient|fatal) from the engine. */
class GhResult<T>(val data: T?, val error: String, val errorClass: String)

/** results/<req>.json written by `gitdrip bridge <req> gh-*`; null = not final / unparsable yet. */
private fun <T> envelope(json: String, f: (Any) -> T): GhResult<T>? = try {
    val o = JSONObject(json)
    when (o.optString("state")) {
        "OK" -> GhResult(f(o.get("data")), "", "")
        "ERROR" -> GhResult(null, o.optString("reason").ifEmpty { "GitHub request failed" }, o.optString("error_class"))
        else -> null
    }
} catch (e: Exception) { null }

fun parseAccount(json: String): GhResult<GhAccount>? = envelope(json) { d ->
    val o = d as JSONObject
    GhAccount(o.getString("login"), o.optString("noreply_email"), o.optString("token_kind"), o.optBoolean("user_matches", true))
}

fun parseRepos(json: String): GhResult<List<GhRepo>>? = envelope(json) { d ->
    val a = d as JSONArray
    (0 until a.length()).map { i ->
        val r = a.getJSONObject(i)
        GhRepo(r.getString("full_name"), r.optBoolean("private"), r.optBoolean("fork"), r.optBoolean("archived"),
            r.optString("default_branch", "main"), r.optBoolean("push"))
    }
}

fun parseBranches(json: String): GhResult<GhBranches>? = envelope(json) { d ->
    val o = d as JSONObject; val a = o.getJSONArray("branches")
    GhBranches(o.optString("default_branch"), (0 until a.length()).map { a.getJSONObject(it).getString("name") })
}

/** Search box + "show forks / read-only" switch: by default only repos where commits can count. */
fun filterRepos(all: List<GhRepo>, query: String, eligibleOnly: Boolean): List<GhRepo> =
    all.filter { (!eligibleOnly || it.eligible) && it.fullName.contains(query.trim(), ignoreCase = true) }

fun ghHint(errorClass: String) = when (errorClass) {
    "auth" -> "Check the token in Termux: echo TOKEN | gitdrip auth set --user NAME"
    "ratelimit" -> "GitHub rate limit reached; try again later"
    "notfound" -> "Repository not found, or the token cannot see it"
    "transient" -> "Network problem; try again"
    else -> "See the Termux log (gitdrip logs)"
}
