import java.util.Properties
import java.net.URI
import java.security.MessageDigest

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val signingPropertiesFile = rootProject.file("key.properties")
val signingProperties = signingPropertiesFile.takeIf { it.isFile }?.let { file ->
    Properties().apply { file.inputStream().use { load(it) } }
}

abstract class BundleMandarinModel : DefaultTask() {
    @get:Optional
    @get:InputFile
    abstract val localArchive: RegularFileProperty

    @get:OutputDirectory
    abstract val assets: DirectoryProperty

    @TaskAction
    fun bundle() {
        val name = "vosk-model-small-cn-0.22.zip"
        val archive = temporaryDir.resolve(name)
        val selected = localArchive.orNull?.asFile
        if (selected == null) {
            val connection = URI("https://alphacephei.com/vosk/models/$name").toURL().openConnection()
            connection.connectTimeout = 20_000
            connection.readTimeout = 30_000
            connection.getInputStream().use { input ->
                archive.outputStream().use { input.copyTo(it) }
            }
        }
        val source = selected ?: archive
        val sha256 = MessageDigest.getInstance("SHA-256")
        source.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                sha256.update(buffer, 0, count)
            }
        }
        val hash = sha256.digest().joinToString("") { "%02x".format(it) }
        check(hash == "3af8b0e7e0f835ae9d414ce5df580237a3cfb08d586c9fbbb0f7ff29ad5b14ba") {
            "Unexpected checksum for the Robot Eyes Mandarin speech model."
        }
        source.copyTo(assets.get().asFile.resolve(name), overwrite = true)
    }
}

val bundleMandarinModel = tasks.register<BundleMandarinModel>("bundleMandarinModel") {
    val suppliedArchive = providers.gradleProperty("robotEyesSpeechModelArchive")
        .orElse(providers.environmentVariable("ROBOT_EYES_SPEECH_MODEL_ARCHIVE"))
    localArchive.set(layout.file(suppliedArchive.map { file(it) }))
    assets.set(layout.buildDirectory.dir("generated/mandarinSpeechAssets"))
}

androidComponents.onVariants { variant ->
    variant.sources.assets?.addGeneratedSourceDirectory(bundleMandarinModel, BundleMandarinModel::assets)
}

android {
    namespace = "com.reareyes.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    val nativeSources = rootProject.file("../../reareyes/app/src/main")
    sourceSets.named("main") {
        java.srcDir(nativeSources.resolve("java"))
        aidl.srcDir(nativeSources.resolve("aidl"))
        res.srcDir(nativeSources.resolve("res"))
    }
    buildFeatures {
        aidl = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.reareyes.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = 34
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    val portableSigning = signingProperties?.let { properties ->
        signingConfigs.create("portable") {
            storeFile = rootProject.file(properties.getProperty("storeFile"))
            storePassword = properties.getProperty("storePassword")
            keyAlias = properties.getProperty("keyAlias")
            keyPassword = properties.getProperty("keyPassword")
        }
    }
    buildTypes {
        release {
            proguardFiles("proguard-rules.pro")
            signingConfig = portableSigning
        }
        if (portableSigning != null) {
            configureEach { signingConfig = portableSigning }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("dev.rikka.shizuku:api:13.1.5")
    implementation("dev.rikka.shizuku:provider:13.1.5")
    implementation("net.java.dev.jna:jna:5.18.1@aar")
    implementation("com.alphacephei:vosk-android:0.3.75@aar")
}
