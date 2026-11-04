import java.security.MessageDigest
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release imzalama anahtarı (git'e girmez: android/key.properties + *.jks).
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    namespace = "com.makay.makay_file_manager"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Tekil paket adı (mağaza kimliği). Uygulama ADI manifest'te:
        // "Makay Dosya Yöneticisi".
        applicationId = "com.makay.filemanager"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Release anahtarı varsa onunla, yoksa (ilk kurulum) debug ile imzala.
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // RAR/7Z bağımlılıklarının R8 "missing class" hatasını önlemek için.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// ---------------------------------------------------------------------------
// Keystore KORUMASI — release imzalama anahtarı hiçbir şekilde değiştirilemez
// veya silinmez.
//
// Beklenen SHA256 özetleri git'e giren `docs/keystore.sha256` içinde tutulur;
// release derlemesinden önce dosya bu özetle karşılaştırılır ve fark varsa
// derleme DURDURULUR. Değişmiş anahtarla imzalanan APK, mevcut kullanıcılara
// kurulamaz (imza parmak izi değişir) — bu yüzden sessizce geçilmez.
//
// Dosyanın yokluğu hata DEĞİLDİR: anahtar git'e girmediği için temiz bir
// klonlamada bulunmayabilir; yalnızca uyarı verilir ve build.gradle.kts'teki
// "yoksa debug ile imzala" akışı çalışmaya devam eder.
val verifyKeystore by tasks.registering {
    group = "verification"
    description = "Release keystore dosyasının değişmediğini doğrular."
    val keystoreFile = file("upload-keystore.jks")
    val manifestFile = rootProject.file("../docs/keystore.sha256")
    doLast {
        if (!manifestFile.exists()) {
            logger.warn("[KESTORE] Beklenen özet dosyası yok: $manifestFile — doğrulama atlandı.")
            return@doLast
        }
        if (!keystoreFile.exists()) {
            logger.warn("[KESTORE] Keystore bulunamadı: $keystoreFile — doğrulama atlandı.")
            return@doLast
        }
        val expected = manifestFile.readLines()
            .map { it.trim() }
            .filter { it.isNotEmpty() && !it.startsWith("#") }
            .mapNotNull { line ->
                val parts = line.split(Regex("\\s+"))
                if (parts.size < 2) null else parts[0].lowercase() to parts[1]
            }
            .firstOrNull { (_, rel) -> rel.endsWith("upload-keystore.jks") }
            ?.first
        if (expected == null) {
            logger.warn("[KESTORE] Özet kaydı bulunamadı — doğrulama atlandı.")
            return@doLast
        }
        val actual = MessageDigest.getInstance("SHA-256")
            .digest(keystoreFile.readBytes())
            .joinToString("") { "%02x".format(it) }
        if (!actual.equals(expected, ignoreCase = true)) {
            throw GradleException(
                "[KESTORE] İmza anahtarı DEĞİŞTİRİLMİŞ veya BOZULMUŞ!\n" +
                    "  beklenen: $expected\n" +
                    "  bulunan : $actual\n" +
                    "  Bu dosya asla değiştirilmez/silinmez. Onarım için:\n" +
                    "  powershell -File tool/keystore_guard.ps1 -Fix",
            )
        }
        logger.lifecycle("[KESTORE] İmza anahtarı doğrulandı.")
    }
}

// Release derlemeleri doğrulamaya bağlıdır; debug derlemeleri etkilenmez.
tasks.configureEach {
    if (name == "assembleRelease" || name == "bundleRelease") {
        dependsOn(verifyKeystore)
    }
}

flutter {
    source = "../.."
}

dependencies {
    // RAR açma (RAR4; RAR5 sınırlı). Yalnızca çıkarma — UnRAR lisansı.
    implementation("com.github.junrar:junrar:7.5.5")
    // 7Z açma / listeleme / çıkarma.
    implementation("org.apache.commons:commons-compress:1.26.2")
    implementation("org.tukaani:xz:1.10")
    // junrar slf4j ister; R8 release'te StaticLoggerBinder eksik diye düşer.
    // nop: log üretmez, yalnızca bağlayıcıyı sağlar.
    implementation("org.slf4j:slf4j-nop:1.7.36")
}
