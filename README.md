# Makay Dosya Yöneticisi

F Dosya Yöneticisi ++ esinlenmesiyle geliştirilen, **Mobil / Tablet / TV** için 3 platformu
tek kod tabanıyla kapsayan dosya yöneticisi uygulaması.

- **Uygulama adı:** Makay Dosya Yöneticisi
- **Paket adı:** `com.makay.filemanager`
- **Teknoloji:** Flutter (Dart)
- **Hedef platformlar:** Android telefon, Android tablet, Android TV (+ Web önizleme)
- **Dil:** Türkçe (arayüz varsayılanı)

## Tüm Özellikler Ücretsiz

Uygulamada **hiçbir premium/satın alma kavramı yoktur** — kategori ayrımı yapılmadan
tüm özellikler her kullanıcıya açıktır:

| Özellik | Açıklama |
|---|---|
| Reklam yok | Uygulamada hiçbir yerde reklam gösterilmez |
| Koyu tema | Açık / koyu / sistem teması seçimi |
| Gelişmiş menüler | Yer imi, ana ekrana ekleme, gizle/gizleme, farklı aç |
| Bellek analizi | Kategori bazlı depolama analizi |
| FTP / Ağ erişimi | Ağdan erişim (FTP sunucu) ve uzak konumlar |
| Bulut bağlantıları | Dropbox, Drive, OneDrive, Box, Nextcloud, pCloud, Yandex |
| Google Drive | Tarayıcı ile OAuth (PKCE) bağlanma; klasör gezinme, indirme, yükleme |
| İlk açılış seçimi | Mobil-Tablet veya TV sürümünü seç; ayarlar otomatik uygulanır |
| İzin onayı | Dosya/medya izinleri kullanıcıdan istenir; onaysız açılmaz |
| Görünüm stili | Otomatik / Dengeli / Geniş / Sık — dikey-yatay sütun sayısı seçilebilir |
| Kategori boyutları | Ana ekran kartlarında başlık altında özet boyut (arka planda hesaplanır; dosya işlemleri sonrası tazelenir) |
| Kartları göster / gizle | İstemediğiniz ana ekran kartlarını gizleyin (ayarlar veya ana ekran menüsünden) |
| Mükerrer dosyalar | Aynı içeriğe sahip kopyaları bulma, tek kopya bırakıp temizleme |
| Görsel harita | Bellek analizinde treemap ile kategori alanlarının görselleştirilmesi |
| Çift panel sürükle-bırak | Tablette listeden klasör ağacına sürükleme ile kopyalama |
| Metin editörü | Düz metin dosyalarını görüntüleme, düzenleyip kaydetme |
| Hex görüntüleyici | Dosyaları offset + hex + ASCII olarak bayt bayt görüntüleme |
| SQLite görüntüleyici | `.db` dosyalarında tablo ve satırları salt okunur görüntüleme |
| Kasa (gizli klasör) | PIN ile korunan AES-256-GCM şifreli dosya kasası; kasaya taşıma, 6–12 hane PIN, kilitlenme geri sayımı |
| Dropbox / OneDrive / Box | Tarayıcı OAuth2 (PKCE) ile bağlanma; gezinme, indirme, yükleme |
| USB / SD kart | Bağlı çıkarılabilir birimleri algılama ve tarayıcıyla açma |
| APK yedekleme | Yüklü uygulamaların kurulum APK'sını Download klasörüne kopyalama |
| Material You | Android 12+ sistem (dinamik) rengi; ayarlar'dan kapatılabilir |
| Kök izinleri (chmod) | Root'lu cihazlarda dosya izinlerini değiştirme; her dosyada izin gösterimi |
| İlerleme ve iptal | Kopyala/taşı için ölçülmüş ilerleme çubuğu, iptal ve kısmi çıktının temizlenmesi |
| Arşivler | `.zip`/`.tar`/`.gz` açma, gezinme, çıkarma; ZIP/TAR oluşturma; Zip-Slip koruması |

## Ekranlar (referans ekranlardan)

1. **Ana Ekran** — kategori ızgarası: Ana bellek, İndirilenler, Bellek Analizi,
   Resimler, Ses, Videolar, Belgeler, Uygulamalar, Yeni Dosyalar, Uzak,
   **Kasa**, **USB / SD**, Ağdan erişim
   (kartların altında özet boyut; görüntü stili ve kartları göster/gizle
   ayarlar'dan değiştirilebilir)
   > **Not:** "Bulut" kartı, Google Drive OAuth doğrulaması tamamlanana
   > kadar listeden **çıkarılmıştır** — kullanıcıya ne ana ekranda ne de
   > göster/gizle listesinde görünmez. Doğrulama bitince tek satır geri
   > eklenir (`lib/models/home_category.dart`).
2. **Çekmece (Drawer)** — Ana Ekran, Ana bellek (%), Geri Dönüşüm Kutusu, **Kasa**,
   **USB / SD Kart**, **Mükerrer dosyalar**, ağ sunucuları,
   hızlı kategoriler (Yeni Dosyalar, Belgeler, Videolar, Ses, Resimler, İndirilenler)
3. **Dosya Tarayıcı** — tek satırlık başlık (geri oku + ad), liste/ızgara,
   sıralama, filtre, arama,
   dosya işlemleri; satır menüsü (metin/hex/SQLite açma, **kasaya taşıma**,
   **chmod**); tablette çift panel **sürükle-bırak kopyalama**
4. **Bellek Analizi** — kullanım yüzdesi, kategori dağılımı, **görsel harita (treemap)**,
   büyük dosyalar, uygulamalar
5. **Uygulamalar** — İndirilenler / Tümü / Dahili sekmeleri, APK bilgisi ve paylaşımı,
   **APK yedekleme**
6. **Ağdan Erişim** — FTP sunucu başlat (rastgele şifre, gizli dosyaları göster)
7. **Uzak** — FTP/SMB/SFTP/WebDAV uzak konum ekleme ve gezinme
8. **Bulut** *(şu an kullanıcıya kapalı)* — bulut sağlayıcı hesapları ekleme;
   Google Drive, **Dropbox**, **OneDrive**, **Box** tarayıcı OAuth2 ile bağlanır.
   Kod ve rota hazırdır; Google Drive doğrulaması tamamlanınca kart açılır
9. **Yeni Dosyalar** — son 7 günde değişen dosyalar, satırlarda (Tarih • Boyut);
   **Temizle** (tek dokunuş) listeyi boşaltır — dosyalar **silinmez** ve bir
   daha listelenmez; cihaza yeni eklenen/değişen dosyalar görünür. Boş
   ekrandaki **Tüm geçmişi tekrar göster** düğmesi temizlemeyi geri alır;
   aşağı kaydırmak ise yalnızca taramayı yeniler (temizlenenler dönmez)
10. **Geçici Dosyalar** — önbellek/.tmp temizliği + **mükerrer dosya taraması**
11. **Kasa** — PIN oluşturma/kilit açma, şifreli dosya listesi, dışa aktarma, silme
12. **USB / SD Kart** — bağlı harici birimlerin listesi ve gezinme
13. **Metin Editörü / Hex / SQLite / Arşiv** — dosya türüne göre açılan
    görüntüleyiciler ve arşiv gezginicisi
14. **Ayarlar** — dosya boyutu birimi, tarih biçimi, **görünüm stili**,
    **ana ekran kartlarını göster/gizle**, **Material You**, **Kasa/USB/Mükerrer**
    kısayolları, gelişmiş ayarlar,
    geri dönüşüm kutusu ayarları, bildirimler, tema (açık/koyu/sistem), izinler

## Geliştirme Aşamaları

Ayrıntılar: [docs/YOL_HARITASI.md](docs/YOL_HARITASI.md)

- **A0** — Ortam kurulumu (Flutter SDK, Android SDK) ✅
- **A1** — Proje iskeleti: tema, navigasyon, ana ekran, çekmece
- **A2** — Dosya tarayıcı (gezinme, sıralama, arama, dosya işlemleri)
- **A3** — Kategori ekranları (Görüntüler/Videolar/Ses/Belgeler/İndirilenler/Yeni Dosyalar)
- **A4** — Bellek analizi + depolama bilgileri
- **A5** — Ayarlar + tema + geri dönüşüm kutusu
- **A6** — Uygulamalar (APK yönetimi)
- **A7** — Ağdan erişim (FTP sunucu), Uzak (FTP/SMB), Bulut
- **A8** — Tablet/TV uyarlaması (D-pad odak, geniş ekran), beta APK üretimi
- **A9–A18** — oynatıcı/önizleme, SMB sunucusu + FTPS + SFTP, TV kanalı,
  uzak konum türleri, marka, Premium kaldırma, GitHub Releases dağıtımı,
  ilk açılış sürüm + izin onayı
- **A19** — geri bildirim serisi: uzak bağlantı kaydı, Google Drive tarayıcı
  bağlanma (OAuth PKCE), kategori boyutları, medya açma, görüntü stili
- **A20** — popüler dosya yöneticileriyle kıyaslanan boşluklar: mükerrer dosya
  tespiti, treemap, çift panel sürükle-bırak, metin editörü, hex/SQLite
  görüntüleyici, chmod, kasa (PIN + AES-256-GCM), Dropbox/OneDrive/Box,
  USB/SD algılama, APK yedekleme, Material You
- **A21** — teknik sağlamlaştırma: GitHub Actions CI + Release, keystore
  yedekleme rehberi, kasa sertleştirilmesi (200.000 PBKDF2 turu, 6–12 hane PIN,
  kilitlenme geri sayımı), bulut ekranının bölünüp ortak OAuth/HTTP katmanına
  taşınması, kopyala/taşı için ilerleme + iptal, iç içe kopyalama hatasının
  düzeltilmesi, cihaz test matrisi
- **A22** — kullanıcı düzeltmeleri: ana ekran kartlarını göster/gizle,
  "Yeni Dosyalar" ekranında dosyaları **silmeden** listeyi temizleme,
  tarayıcı başlığındaki yol (breadcrumb) şeridinin kaldırılması
- **A23** — ilk açılışta/çıkışta "yanıt vermiyor (Bekle)" ANR'ı: uygulama
  listesi ana iş parçacığından arka plana alındı, ikonlar tembel yüklendi;
  "Yeni Dosyalar" temizlemesi kalıcı (okundu/okunmadı mantığı), tek dokunuş

## Otomatik Güncelleme

Uygulama **her açılışında** GitHub **Releases** sayfasını
(`github.com/makaydestek/makay-file-manager/releases`) sorgular
(`releases/latest` API'si). Release etiketi kurulu sürümden **yeni**yse
indirme diyaloğu açılır. Release'deki `.apk` asset'i indirilir ve
**yanındaki `.apk.sha256` asset'iyle zorunlu SHA256 doğrulaması**
yapılır (eşleşmezse dosya silinir), sonra Android kurucusuna açılır.
Release notları diyalogta gösterilir.

Sürüm artışı `Apk Hazırla.bat` ile yapılır; betik **tek yapıda** tek APK
üretir (`flutter build apk --release` — arm64 + arm32 + x86_64 tek
dosyada, kullanıcı mimari seçmez), `*.apk.sha256` yan dosyasını ekler ve
APK + özet ikilisini **otomatik GitHub Release** olarak yayınlar.
Yayın biçimi: release başlığı ve açıklaması **boş bırakılır** — GitHub
sayfada etiketi ve commit mesajını (`Yayin: MakayFileManager v...`)
gösterir. Release oluşturulduğunda **eski sürümler otomatik silinir**
(release + etiket, geriye yalnızca en güncel sürüm kalır) ve yerel
`APK` klasöründeki eski sürüm dosyaları da temizlenir.
APK dosyaları git'e girmez (`APK/` yok sayılır) — dağıtım tamamen
Release üzerinden yapılır, depo hafif kalır.

## CI/CD (GitHub Actions)

Yayın zincirinin tek bilgisayara bağımlılığı iki workflow ile kırıldı:

| Workflow | Dosya | Tetikleyici | Ne yapar |
|---|---|---|---|
| **CI** | `.github/workflows/ci.yml` | `main`'e push, PR | `flutter pub get` → `flutter analyze` → `flutter test` |
| **Release** | `.github/workflows/release.yml` | `*.*.*` etiketi veya elle tetikleme | tek fat APK derle → adlandır → SHA256 → Release oluştur → eski sürümleri sil |

Release workflow, yerel `Apk Hazırla.bat` ile **aynı sözleşmeyi** uygular:
`APK/MakayFileManager-<sürüm>.apk` + `.apk.sha256`, release başlığı/açıklaması
boş, yalnızca en güncel sürüm bırakılır. Sürüm `pubspec.yaml`'dan okunur;
etiket pubspec ile çelişiyorsa pubspec esas alınır ve uyarı verilir.

**Release imzalama anahtarı** repo secret'larından çözülür (depoğa asla girmez):

| Secret | İçerik |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `android/app/upload-keystore.jks` dosyasının base64 kodlaması |
| `ANDROID_KEYSTORE_PASSWORD` | store + key parolası |
| `ANDROID_KEY_ALIAS` | örn. `upload` |

Oluşturma:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("android\app\upload-keystore.jks"))
# çıktıyı ANDROID_KEYSTORE_BASE64 secret'ına yapıştırın
```

Secret yoksa workflow **debug imzasıyla** derleyip uyarı verir — bu durumda
APK kurulur ama **güncelleme dağıtılamaz**, bu yüzden secret'lar zorunludur.
Keystore kaybı senaryosu ve yedekleme adımları: `docs/KEYSTORE YEDEKLEME.md`.

## Çalıştırma

```powershell
# Web önizleme
flutter run -d chrome

# Android (cihaz/emülatör)
flutter run -d android

# Release APK (tek yapı: arm64 + arm32 + x86_64 tek dosyada)
flutter build apk --release

# Tamamlanmış sürüm (sürüm artışı + sha256 + otomatik GitHub Release): Apk Hazırla.bat
# GitHub oturumu yoksa önce bir kez: Gh-Giris.bat
```
