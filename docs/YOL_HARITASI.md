# Makay Dosya Yöneticisi — Yol Haritası

## Teknik Altyapı

| Konu | Karar |
|---|---|
| Framework | Flutter 3.47.7 (stable) / Dart 3.13 |
| Minimum SDK | Android 7.0 (API 24), hedef API 36 |
| Paket adı | `com.makay.filemanager` |
| Durum yönetimi | `ChangeNotifier` + `Provider` (basit, yeterli) |
| Ayarlar kalıcılığı | `shared_preferences` |
| Dosya erişimi | `dart:io` + `path_provider` (Android 11+ MANAGE_MEDIA / SAF notları A2'de) |
| Medya tarama | `photo_manager` (görüntü/video), kategori taraması `dart:io` |
| Grafikler | elle çizilen yüzdelik çubuklar (ek paket yok) |
| Arşiv | `archive` (zip/rar açma) |
| FTP sunucu | saf Dart soket tabanlı mini FTP sunucu (A7) + implicit TLS/FTPS (A10) |
| FTP istemci | `ftpconnect` (A7) |
| SMB sunucu | saf Dart SMB2 (2.0.2) mini sunucu, salt okunur paylaşım (A10) |
| SFTP istemci | `dartssh2` (A10) |
| Oynatıcı | `video_player` (video + ses) (A9) |
| Paylaşım | `share_plus` (A9) |
| Tema | açık / koyu / sistem — tümü ücretsiz |

## Aşamalar

### A0 — Ortam Kurulumu ✅
- [x] Android SDK doğrulandı (`C:\android\sdk`, API 36, build-tools 34/35)
- [x] Java 21 (OpenJDK), Git, Node mevcut
- [x] Flutter SDK 3.47.7 indirildi → `D:\flutter` PATH'e eklendi
- [x] `flutter doctor` temizlendi (lisanslar kabul edildi)

### A1 — Proje İskeleti ✅
- [x] `flutter create --org com.makay --project-name makay_file_manager`
- [x] Renk/tema sistemi (turkuaz vurgu rengi, açık+koyu)
- [x] `HomeScreen`: kategori ızgarası (12 karo, resimdeki sırayla)
- [x] `AppDrawer`: çekmece (resimdeki liste + %bellek satırı + alt künye)
- [x] Üst app bar: başlık, 3 nokta menü (Ayarlar/Analiz et/Yenile)
- [x] Boş ekran bileşeni ("Boş Klasör")
- [x] Türkçe yerelleştirme (flutter_localizations, locale: tr)

### A2 — Dosya Tarayıcı ✅
- [x] Klasör/liste görünümü, breadcrumb (Ana > klasör), yatay kaydırma
- [x] Sıralama (ad/tarih, artan/azalan, klasörler önce)
- [x] Arama (app bar içinde filtreleme)
- [x] Dosya işlemleri: kopyala, taşı, sil, yapıştır, yeniden adlandır, yeni klasör
- [x] Çoklu seçim modu (uzun basma) + bilgi diyaloğu
- [x] Geri dönüşüm kutusu: taşı/geri yükle/kalıcı sil/boşalt (manifest ile)
- [x] Birim testleri (file_service, formats, file entry) — 7/7 geçiyor

### A3 — Kategori Ekranları ✅
- [x] photo_manager ile MediaStore tarama (izin akışı + reddedildiğinde izin ekranı)
- [x] Görüntüler/Videolar: albüm ızgarası (küçük resim + "Ad (adet)")
- [x] Ses: liste görünümü (küçük resim + ad + adet)
- [x] Albüm içi ızgara + tam ekran görüntüleyici (yakınlaştırma, kaydırma)
- [x] Videolar için oynat simgesi katmanı
- [x] Web/masaüstü fallback: klasik dosya tarayıcısı

### A4 — Bellek Analizi ✅
- [x] Kotlin platform kanalı (StatFs): toplam/boş depolama
- [x] Kategori dağılımı: Görüntüler/Videolar/Ses/Belgeler/Arşivler/Diğerleri
- [x] Kullanım yüzdesi + ilerleme çubuğu + "Boş X GB"
- [x] Büyük dosyalar kartı (10 MB+) + tam liste ekranı ("DAHA FAZLA")
- [x] Uygulamalar kartı → Uygulamalar ekranına bağlantı
- [x] Önbellek dosyaları kartı

### A5 — Ayarlar Entegrasyonu ✅
- [x] Tarih biçimi seçimi gerçekten uygulanıyor (4 desen, Türkçe aylar)
- [x] Dosya boyutu birimi ayarı (B/KB/MB/GB/otomatik)
- [x] Tema seçimi (Açık/Koyu/Sistem) kalıcı
- [x] Geri dönüşüm kutusu/bildirim/Gelişmiş ayarları kalıcı (shared_preferences)

### A6 — Uygulamalar ✅
- [x] Kotlin kanalı: yüklü uygulama listesi (ad, paket, sürüm, ikon PNG, boyut)
- [x] İndirilenler sekmesi: Download klasöründeki APK'lar
- [x] Tümü sekmesi: boyuta göre sıralama + arama

### A7 — Ağ ve Bulut ✅
- [x] Ağdan erişim: gömülü mini FTP sunucusu (saf Dart, PASV mod, gerçek protokol testi 4/4)
- [x] Rastgele şifre, gizli dosyaları göster, BAŞLAT/DURDUR + canlı sunucu günlüğü
- [x] Otomatik yerel IP bulma (Wi-Fi öncelikli) + FTP istemci ipuçları
- [x] Uzak: FTP bağlantısı ekleme (ad/host/port/kimlik) + bağlantı testi + gezinme + indirme
- [x] Bulut: sağlayıcı diyaloğu (Nextcloud/ownCloud/pCloud/Yandex/WebDAV + OAuth sağlayıcılar bilgi)
- [x] Gerçek WebDAV gezinme (PROPFIND, Basic auth, dizin ağacı)

### A8 — Tablet / TV Uyarlaması ✅
- [x] Tablet: ≥900 px genişlikte iki panel (sol klasör ağacı + sağ liste, lazy yükleme)
- [x] Android TV: leanback launcher intent-filter, `tv_banner` drawable (320x180 XML)
- [x] Dokunmatik/leanback `uses-feature` required=false (TV mağaza uyumu)
- [x] D-pad/klavye odak vurgusu (tema: focus/hover/highlight renkleri, buton köşe teması)
- [x] Release APK üretildi (54.4 MB) — A7/A8 dahil güncel sürüm
- [x] Birim+entegrasyon testleri: 11/11 geçiyor (FTP sunucu uçtan uca protokol testi dahil)

### A9 — Oynatıcı, Önizleme, Paylaşım ✅
- [x] `video_player` ile yerleşik medya oynatıcı (video: tam ekran + gizlenen
      denetimler, seek; ses: sanat alanı + zaman çubuğu)
- [x] Tam ekran resim görüntüleyici (dosya/bellek, çift dokunma + yakınlaştırma)
- [x] Tarayıcıda dosya türüne göre otomatik önizleme (resim/video/ses açılır,
      diğerleri bilgi diyaloğu)
- [x] Albüm ekranından görüntü/video yerleşik görüntüleyicilerle açılıyor
- [x] Çoklu seçimden `share_plus` ile sistem paylaşım sayfası ("Paylaş")

### A10 — SMB Sunucusu, FTPS, SFTP ✅
- [x] Saf Dart SMB2 (dialect 2.0.2) sunucu: negotiate, NTLM (tüm şifreler
      kabul), tree connect, create/read/close, query directory (5 bilgi
      sınıfı), query info (dosya + dosya sistemi), salt okunur paylaşım
- [x] SMB gerçek uçtan uca protokol testi 2/2 (tam oturum + hata durumu)
- [x] FTPS: gömülü kendi kendine imzalı sertifika (RSA-2048, 10 yıl) +
      implicit TLS portu 2123 + PROT P veri bağlantısı şifrelemesi
- [x] SFTP istemci (dartssh2): Uzak ekranında FTP/SFTP tür seçimi,
      bağlantı testi, gezinme, indirme ekranı
- [x] Ağdan erişim ekranında SMB bölümü (\\IP\makay, BAŞLAT/DURDUR)
- [x] Testler: FTP 6/6 (FTPS el sıkışma + PROT reddi dahil), SMB 2/2

### A11 — TV'ye Özel Kanal ✅
- [x] Kotlin `isTv` kanalı (leanback veya dokunmatik ekran yok)
- [x] `TvHomeScreen`: odaklı büyük kart ızgarası (vurgu + ölçek + gölge),
      odaklanan kartın adı üstte büyük, kumanda ipuçları şeridi
- [x] Ayarlar → "Arayüz modu": Otomatik / TV (zorla) / Telefon-tablet
- [x] Kök rota TV moduna göre otomatik seçiliyor (_HomeLauncher)

### A12 — Uzak Konum Türleri + APK Derleme Yapısı ✅
- [x] "Uzak konum ekle" ekranı yenilendi: tür seçici (Yerel Ağ / SMB / FTP /
      SFTP / WebDAV) + türe göre dinamik form (SMB'de paylaşım adı, WebDAV'da URL)
- [x] SMB2 istemcisi (saf Dart, salt okunur): NTLMv2 kimlik doğrulama
      (saf Dart MD4 + NTOWFv2 HMAC-MD5, MS-NLMP 4.2.4 resmi vektörleriyle
      doğrulandı), negotiate → session setup → tree connect → liste → indirme;
      Windows/Samba paylaşımlarına `\\sunucu\paylaşım` gezinme + indirme
- [x] Yerel ağ taraması: alt ağ (192.168/10/172.16-31) taranır; 445/21/22/
      80/443/5005 portları sınanır, bulunan cihazlar tek dokunuşla
      SMB/FTP/SFTP/WebDAV konumu olarak eklenir
- [x] WebDAV konumları artık uzak konum olarak eklenebilir (URL + Basic auth,
      PROPFIND gezinme + GET indirme)
- [x] Uzak liste: türe göre ikon + özet (SMB: \\host\paylaşım, WebDAV: URL)
- [x] APK derleme yapısı: `Apk Hazırla.bat` (sürüm otomatik artırır —
      version.properties + pubspec senkron —, release APK derler, `APK\`
      klasörüne `MakayFileManager-<sürüm>.apk` + `latest.apk` kopyalar,
      SHA256 + latest.json üretir); bundan sonraki TÜM derlemeler APK
      klasörüne aktarılır
- [x] SMB sunucu CREATE yanıt düzeltmesi (FileId MS-SMB2 ofseti 64) +
      37. sınıf dizin girdisi MS-FSCC'ye uyarlandı (reserved u16)
- [x] Testler 30/30: MD4 7 vektör + NTLMv2 resmi vektör + SMB istemci↔sunucu
      tam oturum (liste + alt dizin + indirme + hata) + FTP 6 + SMB sunucu 2
      + servis/format/widget

### A13 — Marka: Logo & Uygulama İkonu ✅
- [x] Makay ailesi stiline özel ikon tasarımı (GDI+ ile üretilir):
      koyu petrol→teal diagonal degrade, cam parlaklığı, üstte "Makay"
      logosu, ortada beyaz klasör + teal doküman çizgileri
- [x] Android klasik mipmap'ler (48/72/96/144/192 — mdpi…xxxhdpi) üretildi
      ve `ic_launcher.png` olarak yerleştirildi
- [x] TV banner'ı PNG olarak yenilendi (640×360, sol ikon + "Makay /
      Dosya Yöneticisi" yazısı, drawable-xhdpi)
- [x] Web ikonları güncellendi: Icon-192/512 + maskable sürümler + favicon
      (sadeleştirilmiş klasör)
- [x] Üretim betiği: `tool/make_icon.ps1` (çalıştırınca `tool/generated/`
      içine tüm boyutları üretir — yeni boyut/lar kolayca eklenebilir)

### A14 — Premium Kavramının Tamamen Kaldırılması ✅
- [x] `PremiumScreen` silindi (`lib/screens/premium_screen.dart`) + `/premium` rota kaldırıldı
- [x] Ana ekran app bar'ındaki premium taç ikonu kaldırıldı
- [x] Çekmece altındaki "PREMIUM'A YÜKSELT" bağlantısı → sabit künye
      ("Reklamsız • Tüm özellikler ücretsiz") olarak değiştirildi
- [x] Ayarlar'daki "Premium" bölümü tamamen silindi
- [x] Tema seçimi dahil tüm özellikler zaten herkese açıktı; kavram olarak
      hiçbir ekranda "premium/satın alma/ücretli" ibaresi kalmadı
- [x] README + bu yol haritası güncel

### A15 — Yayınlama Altyapısı & Otomatik Güncelleme ✅
- [x] **Release keystore**: `android/app/upload-keystore.jks` (RSA-2048,
      10.000 gün) + `android/key.properties` (git'e girmez) + Gradle'da
      release imzalama yapılandırması — release APK artık kendi imzamızla
      çıkar
- [x] **Paket adı**: `applicationId = com.makay.filemanager` (uygulama ADI
      manifestte "Makay Dosya Yöneticisi" — ikisi farklı alanlar)
- [x] **Git deposu**: `https://github.com/makaydestek/makay-file-manager`
      (2026-10'da `makay-file-mamager` yazım hatası düzeltildi; GitHub eski
      adı kalıcı olarak yönlendirir, kurulu uygulamalar etkilenmez)
      (main) — ilk commit + uzak; `.gitignore` ile keystore ve sürüm
      APK'ları koruma altında, yalnızca güncelleme üçlüsü yayılır
- [x] **Otomatik güncelleme** (`UpdateService` + `update_dialog`):
      her açılışta depodaki `APK/latest.json` sorgulanır → yeni sürüm
      varsa indirme diyaloğu (ilerleme çubuğu) → **SHA256 doğrulama**
      (eşleşmezse dosya silinir) → FileProvider ile Android kurucusu
- [x] **SHA256 yayını**: `Apk Hazırla.bat` artık `*.apk.sha256` yan
      dosyalarını (sürümü + latest) ve `url` alanlı `latest.json` üretir
- [x] Kanal/metot: `installApk` (FileProvider + REQUEST_INSTALL_PACKAGES),
      `openDefaultAppsSettings` (Ayarlar → Varsayılan uygulamalar)
- [x] Ayarlar'daki 3 yarım özellik tamamlandı:
      • **Varsayılan uygulamalar** → Android'in varsayılan uygulama ayarı
      • **Dahili uygulamalar** → Uygulamalar ekranında "DAHİLİ" sekmesi
        (cihazla gelen uygulamalar, `/apps/system` rotası)
      • **Geçici dosyalar** → önbellek + .thumbnails + .tmp/.part
        temizleyici ekranı (`/temp` rotası)
- [x] Ayarlar → Hakkında: gerçek sürüm (PackageInfo) + "Güncelleme
      kontrolü" (elle sorgulama)
- [x] `package_info_plus` eklendi; analiz temiz, testler 30/30

### A16 — APK Boyut Optimizasyonu ✅
> **Not (kullanıcı kararı)**: split-per-abi denemesi geri alındı —
> kullanıcı mimariyi bilemeyeceği için **tek yapı** sürdürülecek.
> Dağıtım güncellemesi A17'ye taşındı: tek APK + GitHub Releases.
- [x] Ölçüm: 61 MB'ın %97'si `lib/` — **3 mimari tek APK'da** geliyordu
      (arm64 19,9 + arm32 17,9 + x86_64 21,4 MB)
- [x] `flutter build apk --release --split-per-abi` → tek cihaz yalnızca
      kendi mimarisini indirir (**~20 MB**, 3 kat küçülme) — *sonradan
      kullanıcı kararıyla iptal edildi*
- [x] Kullanılmayan `installed_apps` bağımlılığı kaldırıldı

### A17 — GitHub Releases Tabanlı Güncelleme & Tek Yapı ✅
- [x] **Tek APK yapısı** (kullanıcı kararı): `--split-per-abi` geri
      alındı → `flutter build apk --release` tek fat APK (~61 MB);
      kullanıcı mimari seçmez, tek yapı dağıtılmaya devam eder
- [x] **UpdateService** → GitHub **Releases API**
      (`releases/latest`): `tag_name` (baştaki `v` atılır) kurulu
      sürümden yeniyse → Release'deki `.apk` asset'i indirilir,
      **`.apk.sha256` asset'i okunup zorunlu SHA256 doğrulaması**
      yapılır, Release notları (`body`) diyalogta gösterilir
- [x] **Betik**: tek APK + `*.apk.sha256` yan dosyası üretir →
      `gh api` ile Release'ı **otomatik yayınlar**; APK'lar git'e
      girmez (`APK/` gitignore) — depo hafif, dağıtım Release üzerinden
- [x] **Release biçimi** (kullanıcı isteği, referans: makay-video-player):
      başlık/açıklama boş → GitHub sayfada etiketi ve commit mesajını
      (`Yayin: MakayFileManager v...`) gri kutuda gösterir; betik commit
     'i release'ten önce atar ki etiket doğru mesaja işaret etsin
- [x] **Otomatik eski sürüm temizliği** (kullanıcı isteği): yeni release
      oluşturulduğunda diğer tüm release'lar **etiketiyle birlikte**
      silinir (`gh release delete --cleanup-tag`), yerel `APK`
      klasöründeki eski sürüm dosyaları da kaldırılır — geriye yalnızca
      güncel sürüm kalır
- [x] Eski `latest.json`/split dosyaları/`make_release_json.ps1`
      temizlendi (sürüm ayrıştırma artık regex değil `jsonDecode`)
- [x] **Kurulum hatası düzeltmesi**: indirilen APK `app_flutter`
      dizinine yazılıyordu, FileProvider bu kökü tanımlamıyordu
      ("Failed to find configured root") → indirme artık
      `getApplicationSupportDirectory()` (`files/`, `<files-path>` kapsamı)
      dizinine yapılır; kurulum hataları ham `PlatformException` yerine
      okunabilir mesajla gösterilir
- [x] `flutter analyze` temiz

### A18 — İlk Açılış Sürüm Seçimi (Mobil-Tablet / TV) ✅
- [x] **DeviceModeScreen**: uygulama ilk açıldığında iki kart —
      "Mobil-Tablet Sürümü" (dokunmatik klasik arayüz) ve
      "TV Sürümü" (kumanda odaklı, büyük kart arayüz); tek dokunuş/D-pad
      ile seçim kalıcılaşır, ekran bir daha gösterilmez
- [x] **Otomatik ayarlar**: seçim `SettingsProvider.applyDeviceMode`
      ile uygulanır — TV → `tvMode=tv` + koyu tema + TV ana ekran
      (TvHomeScreen); Mobil-Tablet → `tvMode=phone` + klasik HomeScreen
- [x] **Güncelleme kontrolü** iki adımlı: sürüm seçimi yapılmadan
      güncelleme sormaz, seçim yapıldıktan hemen sonra sorgular
- [x] Ayarlar → **"Sürüm seçimini göster"**: seçim ekranı yeniden açılır
- [x] **İzin onay ekranı** (`PermissionsScreen`): sürüm seçiminden sonra
      "Tüm dosyalara erişim" (Android ayar ekranı) ve "Medya erişimi"
      (çalışma zamanı diyaloğu) istenir; sistem ayar ekranından dönüldüğünde
      durum otomatik tazelenir, en az bir izin verilmeden "Devam et" açılmaz
      → kullanıcı onay vermeden uygulama açılmaz
- [x] Kotlin kanalı: `checkPermissions`, `requestAllFilesAccess`,
      `requestMediaPermissions` + `PermissionService` (Dart)
- [x] Ayarlar → **"İzinler"**: durum görüntülenir / yeniden istenir
- [x] **Ana ekran kart taşması** düzeltildi: "Depolama alanı" ve
      "Yeni Dosyalar" etiketleri kart dışına taşıyordu → ikon/küçük kart,
      `FittedBox(scaleDown)` ve oran 0.88 ile taşma imkânsız; 360×640
      regresyon testi eklendi
- [x] 7 yeni widget testi; analiz temiz, testler 37/37

### A19 — Kullanıcı Geri Bildirimi Serisi (Sürüm 1.0.9) ✅
Beş maddelik kullanıcı paketi: FTP kaydı, Google Drive bağlantısı,
kategori boyutları, medya açma ve görüntü stili.

- [x] **Uzak bağlantı kaydı**: "Test" başarılı oluyordu ama "Kaydet"
      kaydetmiyordu → `_persist()` akışı (kaydet → depodan yeniden yükle
      → birleşik yedek → başarı/hata SnackBar), `_friendlyError()` ile
      anlaşılır Türkçe hata metinleri, test sonrası rehber SnackBar
      ve mounted korumaları
- [x] **Bağlantı türleri tek tek doğrulandı**: `test/remote_connections_e2e_test.dart`
      gerçek yerel sunucularla (saf Dart mini FTP + SMB2) FTP/SMB kaydının
      kalıcılığını, SFTP/WebDAV'da hata → kaydet yolunu test eder; FTP PASV
      artık döngüsel arayüzde `127.0.0.1` duyurur (aynı cihaz veri bağlantısı)
      WebDAV adresleri `normalizeUrl` ile (şema/son çizgi) düzeltilir
- [x] **Google Drive — tarayıcı ile bağlanma**: OAuth 2.0 authorization-code
      + PKCE, `http://127.0.0.1:<port>/callback` geri çağrısı ile yerel
      HttpServer; kullanıcı "Masaüstü uygulaması" istemci kimliğini oluşturup
      uygulamaya yapıştırır → sistem tarayıcısı açılır, oturum sonrası
      `makayfm://oauth` derin bağlantısıyla uygulamaya dönülür
      (`url_launcher` externalApplication + AndroidManifest intent-filter)
- [x] `oauth_service.dart` (genel amaçlı PKCE/loopback akışı),
      `google_drive_service.dart` (liste/indir/yükle/klasör/çöp/ hakkında +
      jeton yenileme), `google_drive_screen.dart` (gezinme, ilerleme
      çubuklu indirme, bilgi, çöp kutusu), `cloud_screen.dart`'ta adım adım
      rehber paneli ve "Bağlan" düğmesi
- [x] **Kategori boyutları**: `CategorySizeService` — izolatta (arka plan)
      tarama + 30 dk SharedPreferences önbelleği; her ana ekran kartında
      başlık altında boyut ("1,5 GB"), çekmecede iç/dış depolama ve çöp
      kutusu özeti; "Görüntüler" → **"Resimler"** olarak yeniden adlandırıldı
- [x] **Yeni Dosyalar ekranı**: `/browse/recent` yerine `/recent` →
      `RecentFilesScreen` (son 7 gün, büyükten küçüğe, satırlarda
      `(Tarih • Boyut)`), tür ikonları ve önizleme açılışı
- [x] **Medya açma**: Albüm ekranında resme/videoya dokununca ilerleme
      göstergesiyle dosya çözümlenir (`file`/`originFile` + varlık kontrolü),
      resim için küçük resim yedeği, hata SnackBar'ları; artık sessiz dönme yok
- [x] **Görüntü stili değiştirilebilir**: Ayarlar → "Görünüm stili" —
      Otomatik (genişliğe göre 3/4/5), Dengeli (dikey 3 / yatay 4),
      Geniş (dikey 2 / yatay 3), Sık (dikey 4 / yatay 6); `SettingsProvider.viewStyle`
      telefon ve TV ana ekranında `context.watch` ile anında uygulanır
- [x] Teknik düzeltmeler: dizin adı çıkarımı `uri.pathSegments` yerine yol
      sonundan (dizinlerde segment boş geliyordu), `Isolate.run` kapanış
      yerine `Isolate.spawn` + `ReceivePort` (test/sanal alan Zone'larında
      kapanış gönderilemez), `Formats.date` 'tr' verisi yoksa varsayılan
      locale'e düşer
- [x] Yeni/güncellenen testler: `remote_connections_e2e_test`,
      `remote_save_test`, `remote_services_test`, `category_size_service_test`,
      `recent_files_screen_test`, `google_drive_service_test`,
      `view_style_test`; analiz temiz, testler 61/61

### A20 — Popüler Dosya Yöneticileriyle Kıyaslama Boşlukları (Sürüm 1.0.10) ✅
Cx File Explorer / X-plore / Samsung Dosya Yöneticisi / F-Files ile kıyaslanıp
eksik bulunan "ayırt edici" özelliklerin tamamı, öncelik sırasına göre eklendi.

**Temizleyici & analiz**
- [x] **Mükerrer dosya tespiti**: `DuplicateService` — izolatta boyut
      gruplaması + 64 KB parça MD5 (aynı boyut–farklı içerik ayrışır), gizli
      dosyalar ve `Android/` atlanır; `DuplicateFilesScreen` grup kartları,
      "TEMİZLE" (her gruptan bir kopya korunur), kazanılan alan özeti ve
      SnackBar; Geçici Dosyalar, Ayarlar ve çekmece'den erişilir
- [x] **Görsel depolama haritası (treemap)**: `TreemapView` — Squarified
      algoritması (Bruls vd.), kare orana en yakın dikdörtgenler, kategori
      renkleri, etikette ad + boyut; Bellek Analizi ekranına "Görsel harita"
      bölümü olarak eklendi

**Tarayıcı & dosya işlemleri**
- [x] **Çift panel sürükle-bırak**: satırlar `LongPressDraggable`, tablet
      klasör ağacı düğümleri `DragTarget` → üzerine bırakınca kopyalama
      (`FileService.copyPath`); hedef klasör ekrandaysa liste tazelenir
- [x] **Metin editörü**: düz metin uzantıları `TextEditorScreen`'de açılır;
      düzenleme + kaydetme, kaydedilmemiş değişiklik onayı, 1 MB üstünde
      salt-okunur uyarı bandı, görünüm 120 KB'da kırpılır (performans)
- [x] **Hex görüntüleyici**: 16 bayt/satır (offset + hex + ASCII), sanal
      liste, bayt ve Future önbellekleri (sonsuz rebuild döngüsü önlendi)
- [x] **SQLite görüntüleyici**: `.db/.sqlite` dosyalarında tablo listesi +
      ilk 500 satır (salt okunur); Android'de sistem `libsqlite.so` bağlanır
      (ekstra native paket yükü yok), tablo adı kaçışı yapılır
- [x] **İzinler (chmod)**: bilgi diyaloğunda POSIX izin metni; satır
      menüsünde "İzinleri değiştir (chmod)" — `RootService` `su -c id` ile
      root'u doğrular, root yoksa anlaşılır mesaj; mod girdisi sekizlik
      olarak doğrulanır ve yol tırnak kaçışı yapılır

**Kasa (gizli klasör)**
- [x] `VaultService` — PIN'den **PBKDF2-HMAC-SHA256** ile anahtar,
      **AES-256-GCM** dosya şifreleme (12 bayt nonce + 16 bayt etiket); meta
      SharedPreferences'ta, dosyalar uygulama özel dizininde `.enc`
      (tur sayısı meta'da sürüm olarak saklanır: yeni kasalar **200.000**,
      1.0.10 ve öncesi kasalar 20.000 ile açılmaya devam eder)
- [x] `VaultScreen` — PIN oluşturma / kilit açma / açık kasa listesi,
      dışa aktarma (Download/Kasa), onaylı silme, PIN değiştirme ve sıfırlama
- [x] Tarayıcı satır menüsünde **"Kasaya taşı"** (kaynak dosya yerinde kalır,
      kopya şifrelenip kasaya alınır); kilitliyse önce kasa ekranı açılır

**Bulut sağlayıcıları**
- [x] **Dropbox / OneDrive / Box** gerçek bağlantısı: tarayıcı OAuth2 + PKCE
      (mevcut `OAuthService` akışının yeniden kullanımı); ücretsiz developer
      hesabı → uygulama → client ID uygulamaya yapıştırılır
- [x] Servislerde liste/indir/yükle/klasör oluşturma/silme/hakkında, proaktif
      ve 401/403'te tetiklenen jeton yenileme (olmazsa bağlantı kesme),
      sağlayıcı bazlı Türkçe hata çevirisi; ortak `CloudOAuthBrowseScreen`
      gezinme ekranı; Google Drive davranışı aynen korundu

**Cihaz & sistem**
- [x] **USB OTG / SD kart algılama**: Kotlin kanalında `getStorageVolumes`
      (`StorageManager`: açıklama, çıkarılabilir, emüle, durum, yol);
      `UsbStorageScreen` mounted birimleri listeler ve tarayıcıyla açar
- [x] **APK yedekleme**: uygulama satırı → "APK'yı yedekle" (kaynak yol
      `sourceDir` ile uygulamadan alınır) → `Download/<ad>-<sürüm>.apk`
- [x] **Material You**: Android 12+ dinamik sistem rengi (`dynamic_color`);
      Ayarlar'dan kapatılabilir, kapatılınca turkuaz tohum rengine döner

**Testler**: `duplicate_service_test`, `duplicate_files_screen_test`,
`treemap_view_test`, `vault_service_test`, `vault_screen_test`,
`cloud_providers_test` (ağsız), `root_service_test`, `viewer_screens_test`;
`widget_test` kaydırmalı doğrulamaya geçirildi. Analiz temiz, testler **110/110**.

### A21 — Kıyaslama Sonrası Teknik Sağlamlaştırma (Sürüm 1.0.11) ✅
A20'deki özellik ekleme turundan sonra sıra **projenin sürdürülebilirliğine**
geldi: yayın zinciri tek bilgisayardan kurtarıldı, kasa güvenliği sertleştirildi,
kod tekrarı azaltıldı ve uzun dosya işlemlerine ilerleme/iptal eklendi.

**Yayın altyapısı**
- [x] **GitHub Actions CI**: `.github/workflows/ci.yml` — her push/PR'da
      `flutter analyze` + `flutter test`. Release'in yalnızca yerel
      `Apk Hazırla.bat`'tan yapılabildiği riski kırıldı.
- [x] **GitHub Actions Release**: `.github/workflows/release.yml` — etiket
      push'ında (veya elle) tek fat APK derler, adlandırır, SHA256 üretir,
      release'i **boş ad/açıklama** ile açar ve eski sürümleri siler; yani
      yerel betikle **aynı sözleşmeyi** uygular. Sürüm `pubspec.yaml`'dan
      okunur (etiket çelişirse pubspec esas + uyarı).
- [x] İmza anahtarı repo **secret**'larından çözülür
      (`ANDROID_KEYSTORE_BASE64` / `ANDROID_KEYSTORE_PASSWORD` /
      `ANDROID_KEY_ALIAS`); secret yoksa bilgilendirme ile debug imzasına düşer.
- [x] **Keystore yedekleme rehberi**: `docs/KEYSTORE YEDEKLEME.md` — SHA256
      özeti, 3 farklı yere yedek kuralı, geri yükleme adımları. `.gitignore`
      doğrulandı (`*.jks`, `*.keystore`, `android/key.properties`).
- [x] **Depo adı yazımı düzeltildi**: `makay-file-mamager` →
      **`makay-file-manager`**; GitHub eski adı kalıcı yönlendirir (kurulu
      uygulamalar etkilenmez), `Apk Hazırla.bat` ve `UpdateService` URL'leri,
      README ve yol haritası güncellendi.
- [x] **Cihaz test matrisi**: `docs/CIHAZ TEST MATRISI.md` — 12 bölüm / ~80
      adım; otomasyonun kapsayamadığı izin, OTG/SD, root, ağ, performans ve
      güncelleme akışları 5 cihaz sınıfında koşulur.

**Kasa (gizli klasör) sertleştirilmesi**
- [x] **PBKDF2 tur sayısı 20.000 → 200.000** (yeni kasa/PIN). Tur sayısı
      artığı **meta veride saklanır**; 1.0.10 ve öncesi kasalar 20.000 ile
      açılmaya devam eder (geriye uyumluluk testi ile kanıtlandı).
- [x] **PIN uzunluğu 6–12 hane** (eski 6 haneli PIN'ler geçerli, unlock
      uzunluk doğrulaması yapmaz — 4 haneli eski kasalar bile açılır).
- [x] **Kilitlenme + üstel geri çekilme**: 0 → 5 → 15 → 60 → 300 → **1800 sn**
      tavan; `vault_lockout` prefs anahtarıyla kalıcı, sayım başarıda sıfırlanır.
      Arayüzde saniye saniye geri sayım ve **devre dışı KİLİT AÇ** butonu;
      saate enjeksiyon (`VaultService.now`) ile test edilebilir.

**Kod tekrarı ve yapı**
- [x] **Bulut ekranı bölündü**: `cloud_screen.dart` **1.592 → 276 satır**;
      `cloud_add_dialog`, `cloud_oauth_browse_screen`,
      `cloud_webdav_browse_screen`, `cloud_common`, `cloud_utils` olarak ayrıldı.
- [x] **Ortak OAuth/HTTP katmanı**: `services/cloud/cloud_types.dart`,
      `cloud_http_client.dart`, `cloud_oauth_flow.dart` — PKCE, kod değişimi,
      jeton yenileme, 401/403 → yenile → tekrar dene, Türkçe hata çevirisi
      artık tek yerde. Sağlayıcı başına kod **2.154 → 1.327 satır (−827)**.
- [x] Google Drive davranışı **bit bit korundu** (prefs anahtarları,
      `DriveException`, `http://127.0.0.1:<port>/callback` akışı); sayfalama
      döngüleri (Drive `q=`, Dropbox imleç, Box offset) bilinçli olarak
      sağlayıcıda bırakıldı — ortak soyutlama okunurluğu azaltırdı.

**Arşivler (ZIP / TAR / GZ)**
- [x] **`ArchiveService`** (`archive` 4.x): `.zip`, `.tar`, `.gz`, `.tgz`,
      `.tar.gz` okuma; `.zip`/`.tar` oluşturma. ZIP disk tabanlı
      (`InputFileStream`/`OutputFileStream`) — bellek tüm arşivi yüklemez;
      tar.gz tek geçişte akış (`decodeLazy`), geçici dosya yok.
- [x] **Zip-Slip (path traversal) koruması**: mutlak yol ve `..` içeren
      girdiler reddedilir; sözdizimsel normalizasyon + en derin mevcut
      atasının `resolveSymbolicLinks` denetimi ile **sembolik bağlantı
      kaçışı** da engellenir. Sembolik bağlantı girdisi hiç oluşturulmaz.
      İhlalde hiçbir şey yazılmadan `ArchiveSecurityException` fırlatılır.
- [x] **Dürüst hata durumları**: kütüphane `.zip` uzantılı sahte dosyayı
      sessizce boş arşive çeviriyor → EOCD (`PK\x05\x06`) imzası
      önden denetimi eklendi. RAR/7z için "desteklenmez" mesajı.
- [x] **`ArchiveScreen`**: arşiv içi klasör ağacı (sentetik klasörlerle),
      dosya bazlı "Buraya çıkar" / "Dışa aktar-Paylaş" / "Bilgiler",
      "TÜMÜNÜ ÇIKAR" ilerleme diyaloğu + dosya/bayt özeti; bozuk arşivde
      anlaşılır hata ekranı.
- [x] **Tarayıcı entegrasyonu**: arşiv dosyasına dokununca arşiv ekranı
      açılır; satır menüsünde "Arşivi görüntüle"; herhangi bir dosya/klasör
      için **"Buraya sıkıştır"** (geçerli dizine ZIP) ve seçim modunda
      **"Arşive ekle"**.

**Uzun dosya işlemleri**
- [x] **İlerleme + iptal**: `transfer.dart` (`CancelToken`,
      `TransferProgress`, `TransferResult`) ve `FileService`'e
      `onProgress`/`cancelToken`; 256 KB'lık parçalı kopyalama (bellek sabit,
      iptal mümkün), 100 ms'lik bildirim hız sınırı, ölçüm fazı,
      `estimate()` ile "X dosya, Y GB" onayı.
- [x] **İptalde kısmi çıktı temizlenir** — ancak hedef **önceden varsa asla
      silinmez** (kullanıcı verisi korunur).
- [x] **`showTransferProgress`** diyaloğu: belirsiz ölçüm çubuğu, dosya/bayt
      sayacı, "İptal ediliyor…", hata ekranı; iptal `TransferCancelled`
      fırlatır, hata **yeniden fırlatılır**.
- [x] **HATA DÜZELTMESİ (önceden var)**: iç içe kopyalamada alt klasör adı
      `uri.pathSegments`'ten alınıyordu — `Directory.uri` sonuna `/` eklediği
      için son segment **boş** geliyordu ve tüm dosyalar düz klasöre
      iniyordu. A19'da `listDirectory` için düzeltildi, bu turda `_copyDir`
      da yol tabanlı ad çıkarmaya geçirildi.

**Testler**: `archive_service_test` (24), `archive_screen_test` (4),
`file_transfer_test` (14), `transfer_progress_dialog_test` (5),
`vault_service_test` (14), `vault_screen_test` (3),
`cloud_providers_test` (19) — analiz temiz, tam paket **167/167**.

### A22 — Kullanıcı Düzeltmeleri (Sürüm 1.0.13–1.0.15) ✅
Kullanıcı ekran görüntülerinden gelen dört maddelik düzeltme turu.
(Kodun depoya girişi için bölüm sonundaki **Depo notu**'na bakın.)

- [x] **Ana ekran kartlarını göster/gizle**: `SettingsProvider`
      `hiddenHomeCategories` (SharedPreferences `hidden_home_categories`,
      sıralı liste) + `isCategoryVisible` / `setCategoryVisible` /
      `resetHiddenHomeCategories`; yeni `HomeCategoriesScreen`
      (her kategori için anahtar + "Tümünü göster"). Erişim yolları:
      Ayarlar → "Ana ekran kartları" ve ana ekran üç nokta menüsündeki
      "Kartları göster / gizle" (TV ana ekranında ayrıca kanal ikonu).
      `HomeScreen` + `TvHomeScreen` gizlenen kartları filtreler; tümü
      gizlenirse boş ekran + yönlendirme düğmesi gösterilir. **Gizleme
      yalnızca ızgarayı etkiler** — çekmece, ayarlar ve rotalar aynen kalır,
      yani hiçbir özellik erişilemez olmaz.
- [x] **"Yeni Dosyalar" temizleme**: app bar'da **Temizle** (süpürge)
      düğmesi; yalnızca liste doluyken görünür. Onay diyaloğu açıkça
      "dosyalarınız SİLİNMEZ" der; onaydan sonra `_files` boşaltılır ve
      `_cleared` ile ayrı boş ekran mesajı gösterilir. Boş ekran artık
      `AlwaysScrollableScrollPhysics` kullandığı için **aşağı kaydırınca
      tarama yeniden çalışır** (yeni dosyalar doğru görülür).
- [x] **Tarayıcı başlığındaki yol şeridi kaldırıldı**: `İndirilenler`,
      `Belgeler` gibi tarayıcı ekranlarında `storage > emulated > 0 > …`
      breadcrumb satırı silindi; başlık çubuğu artık albüm ekranlarıyla
      aynı tek satırlık görünüm (geri oku + ad + arama/sıralama/menü).
      Kaybolan "Ana dizin" kısayolu taşma menüsünde "Ana ekrana dön" olarak
      korunur; üst klasörler sistem geri okuyla, tablette sol klasör ağacıyla
      gezilir.
- [x] **Bulut kartı geçici olarak kullanıcıya kapatıldı**: Google Drive
      `drive` scope'u **restricted** olduğu için OAuth doğrulaması
      (marka doğrulaması + CASA değerlendirmesi) tamamlanana kadar herkesin
      kendi client ID'siyle geçici bir çözüm sunmak yerine kart
      `kHomeCategories`'ten **tamamen çıkarıldı** — kullanıcı ne ana ekranda
      ne de Ayarlar → "Ana ekran kartları" listesinde göremiyor; yanlışlıkla
      açıp çalışmayan bir özelliğe düşme riski yok. `/cloud` rotası, ekranlar
      ve servisler **yerinde duruyor**; geri açmak tek satırlık bir iş
      (tanım `home_category.dart` başındaki notta hazır).
- [x] **Testler**: `home_categories_test` (5 — gizleme kalıcılığı, menüden
      açma, tümü gizli boş ekran, sıfırlama), `recent_files_screen_test`
      (+2 — temizle dosyayı silmez, vazgeçince liste korunur),
      `browser_screen_test` (2 — breadcrumb yok, alt satır yok).
      Analiz temiz, tam paket **177/177**.

### A23 — ANR Düzeltmesi + "Yeni Dosyalar" Geçmişi (Sürüm 1.0.13–1.0.15) ✅

**1. İlk açılışta/çıkışta "yanıt vermiyor (Bekle)" uyarısı**

- **Kök neden**: `MainActivity.kt`'deki `getInstalledApps` platform çağrısı
  **Android ana iş parçacığında** çalışıyordu. `packageSize()` her paket için
  `StorageStatsManager` binder çağrısı, `iconPng()` her paket için bitmap
  rasterleştirme + PNG sıkıştırma yapıyordu. 150-250 uygulamalık bir cihazda
  bu 10-60 saniyelik blok → sistem ANR diyaloğu ("Uygulama yanıt vermiyor —
  Kapat / **Bekle**"). Ana ekran her açılışta `CategorySizeService.refresh()`
  → `installedApps()` çağırdığı için ilk açılışta da tetikleniyordu.
- **Düzeltme**:
  - `_bg` tek iş parçacıklı yürütücüsü: `getInstalledApps` artık arka planda,
    sonuç `Handler(Looper.getMainLooper())` ile ana iş parçacığına teslim
    ediliyor (`result.success` yalnızca oradan çağrılmalı).
  - Liste çağrısından **ikonlar çıkarıldı** (asıl maliyet buydu).
  - Yeni `getAppIcon` kanalı: ikon **tek tek ve yalnızca ekrana gelen satır
    için** istenir; `PlatformService` önbelleğinde tutulur.
  - Ortak `widgets/app_icon.dart` (`AppIcon`) → Uygulamalar ve Bellek Analizi
    ekranları tembel yüklemeyi kullanır.
  - `onDestroy` ile yürütücü kapatılır (sızıntı yok).

**2. "Yeni Dosyalar" — Temizle kalıcı olsun**

- `RecentSeenStore` (`services/recent_seen_store.dart`): "görüldü" kayıtları
  SharedPreferences'ta `yol|değiştirmeZamanı` anahtarıyla tutulur (üst sınır
  3000, en eskiler atılır).
- Tarama sonucu bu kayıtlara göre filtrelenir → temizlenen dosyalar **bir
  daha listelenmez**. Dosya **değiştirilirse** zaman damgası değişir ve
  "yeni dosya" olarak yeniden görünür.
- **Temizle butonu tek dokunuştur** (onay diyaloğu yok): listedekileri
  işaretler, listeyi boşaltır, SnackBar ile "dosyalarınız silinmedi" der.
  Veri kaybı olmadığı için ikinci adım gereksizdir.
- Boş ekran kaydırılabilir (`AlwaysScrollableScrollPhysics`) → aşağı
  kaydırınca **yalnızca tarama yenilenir**: okundu işaretleri durduğu için
  temizlenen dosyalar **geri gelmez**, yalnızca sonradan eklenen/değişen
  dosyalar görünür.
- **Geri dönüş yolu** boş ekrandaki *"Tüm geçmişi tekrar göster"* düğmesidir:
  `RecentSeenStore.forgetAll()` ile okundu işaretlerini siler ve listeyi
  baştan doldurur. Düğme yalnızca kullanıcı Temizle dedikten sonra görünür
  (`_cleared`) ve yenilemeden sonra da **ekranda kalır** — `_load()`
  bilinçli olarak `_cleared`'i sıfırlamaz.

**Testler**: `recent_seen_store_test` (5), `recent_files_screen_test` (5 —
tek dokunuş temizleme, dosya silinmiyor, geçmiş kalıcı, değişen dosya yeniden
listelenir, aşağı kaydırma geçmişi getirmez / düğme getirir). Analiz temiz,
tam paket **184/184**.

> **Depo notu**: A22 ve A23'ün kodu, 1.0.13–1.0.15 sürümleri yayınlanırken
> çalışma ağacında duruyordu ve **hiç commit edilmemişti** — yayın commit'leri
> (`Yayin: …`) yalnızca `pubspec.yaml` ile `version.properties` dosyalarını
> değiştiriyordu, dolayısıyla bu iki maddenin kodu depoda yoktu. Kod bu
> düzeltme turuyla (yanlış "aşağı kaydırınca geçmiş geri gelir" metni,
> `RecentSeenStore.forgetAll`'ın ölü kod olması, `settings_provider` içindeki
> var olmayan sembollere doküman referansları, test dosyasının eksik son
> satır sonu) birlikte commit edilerek depoya girmiştir. Bu not, kodun hangi
> sürümde çıkarıldığına dair tek doğrulanan kaynaktır: sürüm numaraları
> git geçmişiyle eşleştirilemiyordu.

### A24 — Depolama Bilgisi Doğruluğu (Sürüm 1.0.16 sonrası) ✅

**Kullanıcı raporu**: "Yeni Dosyalar"da 630 MB'lık dosya içeriğinden
temizlenince hâlâ 630 MB görünüyor; yeni eklenen 2 MB dosya da 630 MB
görünüyordu.

**Kök neden**: boyutlar **doğru hesaplanıyordu**, ama gösterilen değer
bayattı. Üç ayrı yerde tazelik kopmuştu:

1. `CategorySizeService` kategori önbelleğini **30 dakika** taze sayıyor ve
   **hiçbir dosya işlemi önbelleği geçersiz kılmıyordu** → ana ekran kartı
   silinmiş dosyanın boyutunu göstermeye devam ediyordu.
2. `RecentFilesScreen`, dosyayı açıp geri dönünce ve uygulama öne çıkınca
   **yeniden taramıyordu** → satırlar bayat kalıyordu.
3. `refresh()` sürerken gelen zorunlu istek **yutuluyor** ve hesaptan dönen
   **boş/kısmi** sonuç (izin hatası, izolat düşüşü) ekrandaki tüm değerleri
   **siliyor** ve 30 dakika "taze" yazıyordu.

**Düzeltmeler**

- `CategorySizeService.invalidate()`: içerik değiştiren **her** işlem sonrası
  önbelleği siler. Bağlandığı yerler: `FileService` (oluşturma, yeniden
  adlandırma, kopyalama, taşıma, silme), `RecycleBinService` (taşıma, geri
  yükleme, kalıcı silme, boşaltma), `DuplicateService.delete`,
  `temp_cleaner_screen` (3 temizlik), `text_editor_screen._save` (dosya
  içeriği düzenlenince), `vault_service.exportTo`.
- Ana ekran (telefon + TV) her görünür olduğunda `refresh()` çağrır →
  önbellek silindiyse bayat etiket anında tazelenir.
- `RecentFilesScreen`: görüntüleyiciden dönünce ve uygulama öne çıkınca
  tarama yenilenir (içerik temizlenmişse satır 0 B olur).
- `refresh()`: sürerken gelen force istek artık **biriktirilip** hesap
  bitiminde çalıştırılır; boş hesap sonucu etiketleri **silmez**, önceki
  değerlerle birleştirilir ve önbelleğe **yazılmaz**; yutulan hatalar
  `logSwallowed` ile izlenebilir. Önbellek ömrü 30 → **10 dk**.

**Bulunan ve düzeltilen diğer boyut hataları**

- **Dizin boyutu karışması**: `FileService.listDirectory` dizinler için
  `stat.size` yazıyordu (Linux/Android'te bu **inode boyutudur**, 0 ya da
  4096 B — içerik toplamı değildir) → klasörler çöpe taşınınca "0 B / 4,1 KB"
  görünüyordu. Dizinler için artık 0 yazılır ve `RecycleBinService` içerik
  toplamını taşınmadan önce ayrı hesaplar.
- **Silmeden önce boyut sayımı**: `DuplicateService.delete` ve
  `temp_cleaner_screen` boyutu silmeden **önce** ekliyordu → kilitli/silinemeyen
  dosyanın boyutu da "kazanılan alan / temizlendi" rakamına giriyordu. Artık
  boyut yalnızca silme **başarılıysa** sayılır.
- **Bellek Analizi çift sayımı**: 'Arşivler' tüm kökü tarayıp `Download`
  altındaki zip'i 'Belgeler'e de yazıyor; 'Diğerleri' ise WhatsApp'ın tamamını
  sayıp 'Videolar'/'Ses' ile çakışıyordu → yüzde/treemap kullanılan alandan
  büyük çıkabiliyordu. Kategoriler artık **karşılıklı dışlayıcı**;
  'Arşivler' yalnızca diğer kategorilere girmeyen köklerde aranır ve
  **'Diğerleri' = kullanılan alanın kalanı** alınır (toplam %100'ü aşmaz).
- **Sınırlı örneğin toplamı**: "Büyük dosyalar" başlığındaki rakam en fazla
  300 dosyalık (artık 2.000) örneğin toplamıydı ama gerçek toplam sanılıyordu;
  alt başlıkta örnekleme açıkça belirtiliyor.

**Testler**: `category_size_cache_test` (6 — silme/renamede önbellek silinir,
okumalar bozmaz, boş hesap etiketleri silmez/önbelleğe yazılmaz, süren
hesapta force yutulmaz). Analiz temiz, tam paket **190/190**.

> **Not**: `ftp_server_test` "PWD, CWD, LIST ve RETR" testi paralel koşumda
> seyrek biçimde başarısız olabiliyor (port/timing); tek başına hep geçiyor
> ve FTP sunucusu `FileService`/`CategorySizeService` kullanmıyor — bilinen
> kararsızlık, bu maddeden bağımsız.

### A25 — Yerel Ağ Taramasından Eklenen Bağlantı Kaydedilmiyordu ✅

**Kullanıcı raporu**: "Yerel Ağ Taraması" sonrası seçim yapılıp bilgiler
girilip "Kaydet"e basılınca işlem tamamlanmıyor; aynı akış FTP ile
eklendiğinde sorunsuzdu.

**Kök neden**: `RemoteScreen._add` içinde "Yerel Ağ" (LAN) akışında tarama
ekranının döndürdüğü konum **kalıcı olarak hiç kaydedilmiyordu**:

```dart
if (type == 'lan') {
  final added = await Navigator.push<...LanScanScreen>(...);
  if (added != null) await _load();  // ← yalnızca YENİDEN OKUYOR
}
```

`_load()` sadece `RemoteLocationStore.load()` çağırıyordu; `save()` hiç
çağrılmadığı için konum listeye hiç gelmiyordu. Doğrudan eklemede (tür
seç → form → Kaydet) ise `_persist` vardı — bu yüzden FTP/SMB/WebDAV elle
eklenirken sorunsuzdu.

**Düzeltme**: LAN akışında `added != null` durumunda artık `_persist(...)`
çağrılıyor — konum `RemoteLocationStore`'a yazılıyor, listede görünüyor ve
"kaydedildi ✅" geri bildirimi gösteriliyor.

**Test**: `remote_connections_e2e_test.dart` → "Yerel Ağ akışı: tarama
sonucundaki konum KAYDEDİLİR" (regresyon testi: tarama ekranı `pop(loc)`
ile kapanır gibi davranılıp kalıcılık ve geri bildirim doğrulanır). Analiz
temiz, tam paket **191/191**.

### A26 — photo_manager KGP Uyarısı: Built-in Kotlin'e Geçiş ✅

`flutter build` sırasında çıkan *"Your app uses the following plugins that
apply Kotlin Gradle Plugin (KGP): photo_manager"* uyarısı denetlendi.

**Bulgular**

- `photo_manager` **3.12.0 zaten en yeni sürüm** (2026-08-09); AGP 9'un
  yerleşik (built-in) Kotlin derlemesini **destekliyor** — KGP'yi yalnızca
  `android.builtInKotlin=false` iken uyguluyor.
- Uyarı büyük ölçüde **yanlış pozitiftir**: Flutter'ın dedektörü eklentinin
  `build.gradle` dosyasını **metin olarak tarayıp** `apply plugin:
  'kotlin-android'` satırını regex ile bulur; satır hiç çalışmayan
  `if (!useBuiltInKotlin)` dalının içinde olsa da işaretlenir. Upstream:
  fluttercandies/flutter_photo_manager **#1450** + **PR #1451** (açık; bu
  satır `pluginManager.apply(...)` biçimine çevrilecek).
- **Asıl risk bizim tarafımızdaydı**: `android/gradle.properties` içinde
  `android.builtInKotlin=false` yazıyordu → photo_manager **gerçekten KGP
  uyguluyordu** (legacy mod). Flutter, "KGP uygulayan eklentilerle geleceği
  build'i reddedeceğini" bildirdiği için bu, zamanla build kırardı.

**Yapılan**: `android.builtInKotlin=true` yapıldı; photo_manager artık KGP
uygulamıyor ve derleme AGP 9'un yerleşik Kotlin'iyle yapılıyor.
`builtInKotlin=true` ile `flutter build apk --debug` doğrulandı ✅.

**İzleme**: Kalan metin-uyarısı, PR #1451 yayınlandığında (photo_manager
3.12.1+) `flutter pub upgrade photo_manager` ile tamamen kaybolacak —
**bir sonraki sürümlerde `pub outdated`'a bakıp photo_manager sürümünü
yükseltmek yeterli.** `gradle.properties`'taki `builtInKotlin=true`
ayarının `false` yapılmaması gerekir (false, photo_manager'ı KGP'ye geri
döndürür); ayrıca `kotlin.incremental=false` ayarı Windows'ta bilinen bir
Gradle kilitlenmesi nedeniyle korunuyor.

### A27 — Görünüm Preset'leri (Tema'dan Bağımsız Görsel Tarz) ✅

Kullanıcı önerisi: Tema seçimi yalnızca zemini değiştiriyordu; yazı fontu,
ikonlar ve arka plan da seçimle değişmeli.

**Tasarım**: Yeni `AppAppearance` enum'u (`lib/theme/app_appearance.dart`) —
5 preset; **Tema** (açık/koyu/sistem) ile **bağımsız** iki boyut:

| Preset | Yazı | İkon | Köşe | Zemin/gradyan |
|---|---|---|---|---|
| **Klasik** | platform | standart | 12 | düz (mevcut davranış) |
| **Sade & İnce** | +harf/satır aralığı | ince (300), dolgusuz | 6 | soluk gradyan |
| **Canlı & Yuvarlak** | sıkı harf aralığı | kalın (700), dolu | 20 | renkli gradyan |
| **Teknolojik** | **monospace** | keskin (72 optical) | 4 | camgöbeği gradyan |
| **Büyük & Okunaklı** | **×1.15 ölçek** + yüksek kontrast | iri (28) | 10 | düz, yüksek kontrast |

- Her preset kendi `ColorScheme`'ini üretir (`DynamicSchemeVariant`:
  neutral/vibrant/expressive/fidelity + `contrastLevel`); **dinamik Material
  You rengi yalnız Klasik'te** dikkate alınır (diğer tarzlar ezilmesin).
- **Yazı boyutu** bu Flutter sürümünde `ThemeData`'da taşınmadığı için
  (`textTheme` fontSize'ları null) büyüme `MaterialApp.builder`'daki
  `MediaQuery.textScaler` ile uygulanır — sistem ölçeği korunarak çarpılır.
  Yazı ailesi `_textTheme` içinde `TextTheme.apply(fontFamily:)` ile.
- **İkon stili** `IconThemeData(fill, weight, opticalSize, size)` ile
  Material Symbols gliflerine yansır — tüm uygulamadaki ikonlar tek seçimle
  değişir.
- **Gradyan zemin** yalnız **ana ekranda** (telefon + TV) `DecoratedBox`
  ile çizilir; `gradient == null` ise hiçbir şey değişmez. Diğer ekranlar
  preset'in zemin rengini kullanır.
- **Ayarlar → Görünüm**: önizlemeli seçim diyaloğu
  (`lib/widgets/appearance_picker.dart`) — her preset'in renk, köşe, ikon ve
  yazı örneği gerçek temayla üretilir; seçim kalıcı (`appearance` tercihi).

**Doğrulama**: `flutter analyze` temiz ✅, **204/204 test** ✅
(`test/app_appearance_test.dart` + `test/appearance_picker_test.dart`;
regresyon: Klasik, eski görünümün aynısı — turkuaz vurgu, 12px köşe, düz
zemin).

### A28 — Güvenlik ve Ağ Sertleştirme ✅
- [x] **SMB NTLMv2 parola doğrulama**: gömülü SMB sunucusu Tip-3 yanıtını
      gerçek kullanıcı/şifre ile doğrular; yanlış parola
      `STATUS_LOGON_FAILURE`. Ağdan erişim ekranı FTP ile aynı kimlik
      bilgisini SMB'ye iletir.
- [x] **SMB istemci SESSION_SETUP ofset düzeltmesi**: güvenlik tamponu
      ofseti 0x48 → 0x58 (MS-SMB2 PreviousSessionId sonrası).
- [x] **SecureStore**: uzak konum şifreleri ve OAuth jetonları
      `flutter_secure_storage` (Android Keystore) içinde; prefs'ten
      otomatik migrasyon.
- [x] **Uygulama kilidi lockout**: kasa ile aynı üstel geri çekilme
      (0→5→15→60→300→1800 sn) + `auth_service_test`.
- [x] **FTP salt-okunur + paylaşılan kök**: STOR/DELE/MKD/RMD reddi;
      Ana bellek / İndirilenler seçimi.

## Riskler / Notlar
- **photo_manager KGP uyarısı** (Android build çıktısı): yanlış pozitif —
  `android/gradle.properties` içindeki `android.builtInKotlin=true`
  korunmalı (bkz. A26). Upstream PR #1451 yayınlandığında (photo_manager
  3.12.1+) `flutter pub upgrade photo_manager` ile uyarının kendisi de
  kaybolacak.
- Android 11+ (API 30+) kapsamlı dosya erişimi için `MANAGE_EXTERNAL_STORAGE`
  izni gerekir — Play Store'da kısıtlı, APK yan yüklemeye uygun.
- Medya okuma için Android 13+ `READ_MEDIA_IMAGES/VIDEO/AUDIO` izinleri A3'te eklenecek.
- TV platformu ayrı build değil, aynı APK'ya leanback destek + banner eklenir.
### A29 — Sürdürülebilirlik ve Kalan P1/P2 ✅
- [x] **browser_screen parçalama**: `browser_file_actions` / `browser_row_menu`
      / `browser_body` (~1800 → ~700 + parçalar).
- [x] **TV odak**: arşiv listesi + TÜMÜNÜ ÇIKAR; kasa kilit ekranı;
      tarayıcı satırları (önceden vardı).
- [x] **Kasa MKC1**: >4 MB dosyalar 1 MB parçalı AES-GCM; tavan 512 MB;
      PIN değişiminde parçalı yeniden şifreleme.
- [x] **Bulut UX**: Ayarlar → "Bulut bağlantıları" (uyarı diyaloğu + `/cloud`).
- [x] **i18n iskeleti**: `l10n.yaml` + `app_tr.arb` / `app_en.arb` +
      `AppLocalizations` (başlıklar); varsayılan locale hâlâ `tr`.
- [x] **photo_manager**: 3.12.0 hâlâ güncel; 3.12.1+ bekleniyor (A26).

- **Bekleyen (manuel)**: cihaz matrisi hücrelerinin doldurulması (smoke S1–S9).
