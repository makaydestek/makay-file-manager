# ---------------------------------------------------------------------------
# RAR / 7Z native bağımlılıkları (junrar, commons-compress)
# Bu kütüphaneler isteğe bağlı sınıf referansları taşır; APK'da yoktur.
# R8 bunları "Missing class" diye hata sayar → dontwarn ile bastırılır.
# ---------------------------------------------------------------------------

# slf4j (junrar)
-dontwarn org.slf4j.impl.StaticLoggerBinder
-dontwarn org.slf4j.**

# Zstd / Brotli (commons-compress opsiyonel sıkıştırıcılar — kullanmıyoruz)
-dontwarn com.github.luben.zstd.**
-dontwarn org.brotli.dec.**

# Pack200 / ASM (commons-compress harmony — kullanmıyoruz)
-dontwarn org.objectweb.asm.**
-dontwarn org.apache.commons.compress.harmony.**

# XZ (tukaani — 7z için gerekli; yine de uyarı bastır)
-dontwarn org.tukaani.xz.**

# Çalışma zamanında gerçekten kullandığımız sınıfları koru
-keep class com.github.junrar.** { *; }
-keep class org.apache.commons.compress.archivers.sevenz.** { *; }
-keep class org.tukaani.xz.** { *; }
