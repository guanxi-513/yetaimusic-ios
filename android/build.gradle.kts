allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// 统一提升插件子工程的 compileSdk：flutter_displaymode 拉入的 androidx 库
// 要求 compileSdk 34+，shared_preferences/sqflite 要求 36+。
// plugins.withId 在插件已应用时也会立即执行（不能用 afterEvaluate：
// evaluationDependsOn(":app") 会让子工程在根脚本执行期间就已求值）
subprojects {
    project.plugins.withId("com.android.library") {
        project.extensions
            .findByType(com.android.build.gradle.LibraryExtension::class.java)
            ?.compileSdk = 36
    }
    // 兜底：bonsoir_android 等老式插件在 apply plugin 之后的脚本体里
    // 用 compileSdkVersion 33 覆盖了上面的值，求值结束后需再覆盖一次
    project.afterEvaluate {
        project.extensions
            .findByType(com.android.build.gradle.LibraryExtension::class.java)
            ?.compileSdk = 36
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
