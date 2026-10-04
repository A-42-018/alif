package com.gitdrip.app

import android.app.Application
import com.gitdrip.app.data.AppDb

class GitDripApp : Application() {
    val db: AppDb by lazy { AppDb.build(this) }
}
