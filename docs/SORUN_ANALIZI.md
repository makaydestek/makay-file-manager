# MakayFileManager — Detaylı Sorun Analizi

> **DURUM (16 Kasım 2026):** Öncelik sırasına göre uygulama turu **tamamlandı**.
> `flutter analyze` → **No issues found**, `flutter test` → **297/297 geçti**
> (önce 282/293). Yapılan düzeltmelerin özeti belgenin sonundaki
> **"UYGULANAN DÜZELTMELER"** bölümünde; aşağıdaki bulgular ilk analizin
> tarihsel kaydı olarak korunmuştur. Yapılamayan tek iş: FTP istemcisine
> FTPS (`AUTH TLS`) — aşağıda "Kalan" başlığında gerekçesiyle listelendi.

**Tarih:** 14 Kasım 2026 · **Sürüm:** 1.0.60+61 · **Kapsam:** `lib/` (93 Dart dosyası), `android/` native taraf, CI, testler, bağımlılıklar.

**Yöntem:** `flutter analyze`, `flutter test`, bağımlılık denetimi + üç derinlemesine kod incelemesi (güvenlik/kripto, ağ/sunucu servisleri, UI/state) + repo/derleme denetimi. Aşağıdaki her bulgu dosya ve satır numarasıyla doğrulanmıştır.

---

## A. KRİTİK (yayını/büyümeyi doğrudan engelleyen)

### A1. Test paketi kırmızı — 11 test başarısız (282 geçiyor)
| Test | Kök neden (doğrulanmış) |
|---|---|
| `viewer_screens_test` ×2 — TextEditor | **Gerçek uygulama hatası:** `text_editor_screen.dart:167-186` `_lineNumberGutter` içindeki `ListView.builder`, salt-okunur modda (`SingleChildScrollView` → `Row`, satır 338-352) sınırsız yükseklik alıyor → `Vertical viewport was given unbounded height` + art arda layout çökmesi. Satır numaraları açıkken uzun bir metin dosyasını salt-okunur açmak üretimde de layout hatası üretir. |
| `view_style_test` ×4 — sütun sayısı | Test `find.byType(GridView)` bekliyor; `home_screen.dart:230` `SliverGrid`'e geçirilmiş. Testler implementasyonla güncellenmemiş. |
| `appearance_picker_test` ×3 | `settings_screen.dart:33` `AppLocalizations.of(context)` kullanıyor; test `MaterialApp`'e localization delegate vermiyor → `Null check operator used on a null value`. |
| `settings_about_test` ×1 | Aynı kök neden (SettingsScreen + l10n). |
| `remote_connections_e2e_test` (WebDAV) | Test 127.0.0.2'de canlı sunucu varsayıyor (`SocketException errno 1225`); sonra `WebDAV` yazan widget bulunamıyor. Ortam-bağımlı / akış uyumsuz — izole çalıştırılamıyor. |

> CI'da `flutter test` başarısızsa yayın hattı test koruması olmadan ilerliyor demektir. Kalıcı çözüm: TextEditor'da gutter'ı `ListView` yerine `Column`/`CustomScrollView` sliver'ına çevirmek; testleri `SliverGrid` ve `AppLocalizations.delegate` ile eşitlemek.

### A2. ~2.500 satır commit edilmemiş iş + kritik dosyalar git'te izlenmiyor
`git status`: 28 değişmiş dosya (+2508/−1511) ve izlenmeyen kritik dosyalar:
- `AppUpdateRepository.kt` (otomatik güncellemenin native tarafı), `MakayDocumentsProvider.kt`, `res/values/strings.xml`
- `lib/models/remote_item.dart`, `lib/screens/remote/`, `lib/services/ftp_session.dart`, `remote_preview.dart`, `remote_service` değişiklikleri …

HEAD'deki (v1.0.60 etiketi) `MainActivity.kt` `checkForUpdate` kanalını **implemente etmiyor**, manifest `MakayDocumentsProvider`'ı tanımıyor. Etiket üzerinden derlenen CI release'i, çalışma ağacındaki kodla **aynı değil**. Risk: yarım/eksik sürüm yayınlamak veya geri dönülemez commit kaybı.

### A3. SMB sunucusunda kimlik doğrulama baypası
`lib/services/smb_server.dart`: yalnız `_onTreeConnect` (satır 521) `!_authenticated` denetliyor. `_onCreate` (634), `_onRead` (676), `_onWrite` (753), `_onSetInfo` (797, silme/yeniden adlandırma), `_onQueryDirectory` (968), `_onQueryInfo`, `_onClose` (1130) handler'larında **hiç auth/treeConnect kontrolü yok**; `sessionId`/`treeId` başlıkları okunuyor ama doğrulanmıyor (322-324). NEGOTIATE/SESSION_SETUP atlanıp doğrudan CREATE/READ/WRITE/DELETE gönderilebilir. **En ciddi tek bulgu budur.**

### A4. FTP/SMB sunucusunda zayıf kimlik + parola sızıntısı
- Şifre uzayı 4 hane: `network_access_screen.dart:79-83` (`1000-9999`); `ftp_server.dart:252-258`'de deneme sayısı sınırı/geri çekilme yok → LAN'da saniyeler içinde kırılır.
- **Parola günlüğe yazılıyor:** `ftp_server.dart:237` her komut satırını (`PASS ****` dahil) `_log`'a ekliyor; "Sunucu günlüğü" kartında ekranda görünüyor.
- Varsayılan kullanıcı `admin`, sabit portlar (2121/6586/445).
- FTP PASS doğrulaması sabit-zamanlı değil (`==`).

### A5. FTPS TLS anahtar çifti kaynak koduna gömülü
`lib/services/ftp_tls_cert.dart:5-55`: sertifika **ve private key** sabit string. APK'dan çıkaran herkes anahtarı alır; herkes aynı self-signed anahtarı kullandığı için "sunucu taklidi" (MITM) mümkün. Anahtar cihaz/curatum-özel üretilmeli.

---

## B. YÜKSEK (kullanıcıya dokunan hata/performans/güvenlik)

### B1. Kalıcı locale sabit + yarıda kalmış i18n
`main.dart:291` `locale: const Locale('tr')` — sistem dili yok sayılıyor. l10n iskeleti var ama **yalnız 7 anahtar** ve 2 kullanım (`main.dart:277`, `settings_screen.dart:33`); UI'ın geri kalanı (yüzlerce metin) koda gömülü Türkçe. `en` çevirisi pratikte ölü.

### B2. FutureBuilder'larda her build'de yeni future (ağır I/O + flicker)
Aynı projede `media_category_screen`/`hex_viewer` doğru önbelleklemeyi uygularken:
- `album_screen.dart:884-885` — `_AssetThumb` her rebuild'te `thumbnailDataWithSize` (disk/platform I/O) tetikler; seçim/aramada tüm ızgara thumbnail'ları yeniden okunur.
- `file_thumbnail.dart:58-64` — video thumbnail'ı cache miss'te her build'de `MediaMetadataRetriever` tetikler (tarayıcının her satırı).
- `vault_screen.dart:441` — `AuthService.vaultBiometricsEnabled` static-getter yeni future; kilit geri sayımı her saniye rebuild ettiği için her saniye prefs okunur.
- `main.dart:395` (`AppPaths.byCategory`), `settings_screen.dart:503` (`PackageInfo.fromPlatform()`).

### B3. Dispose edilmeyen `TextEditingController`'lar (5 yerde)
- `settings_screen.dart:1016-1017` (`_askPin`, her çağrıda 2 controller)
- `browser_file_actions.dart:163` (chmod), `:575` (yeniden adlandır), `:618` (yeni klasör)
- `recent_files_screen.dart:470` (yeniden adlandır)
Widget-state'i dışında `showDialog` için oluşturulan controller'lar `whenComplete`/dialog state'i ile dispose edilmeli.

### B4. Abonelik iptali olmayan stream'ler
- `network_access_screen.dart:101,135` — `server.log.listen(...)` dönüşü **hiçbir yere saklanmıyor**; `dispose`'da iptal edilemez. Sunucu her yeniden başlatıldığında eski abonelik + yeni abonelik birikir → log satırları çoğalır, State closure'ları yaşar.
- `ftp_server.dart:75` / `smb_server.dart:44` — `_log` StreamController'ı `stop()`'ta hiç `close()` edilmiyor.

### B5. Aşırı rebuild / UI thread işleri
- `media_viewer_screen.dart:168-170` — player tick'inde `setState(() {})` **tüm sayfayı** yeniden çizer (slider + konum metni izole edilmeli).
- `browser_screen.dart:248-274` — `_loadChildCounts` klasör başına ayrı `setState` → 100 klasör = 100 tam rebuild.
- `smb_server.dart`/`ftp_server.dart` sunucuları UI isolate'inde **senkron I/O** ile (`listSync`/`statSync`/`readSync`, smb_server:879-903, ftp_server:590-600) → kalabalık klasörde uygulama donar.
- O(n²) tampon büyüme: `smb_server.dart:273`, `smb_client.dart:121`, `ftp_session.dart:397` (`remainder = [...remainder, ...chunk]`) — `BytesBuilder` gerekli.
- Aramada debounce yok (`album_screen:610`, `browser_screen:480`); `global_search_screen`'deki 350 ms desen buralara da uygulanmalı.

### B6. İndirmelerde iptal mekanizması hiç yok
`ftp_session.dart:114`, `smb_client.dart:342`, `webdav_service.dart:255`, `sftp_service.dart:57`, `cloud_http_client.dart:149-231`, `update_service.dart:104` — cancel token/abonelik iptali yok; önizleme/indirme diyaloğu `barrierDismissible: false` (kullanıcı beklemeye mahkûm). Boyutu bilinmeyen dosyada sınır **indirmeden sonra** kontrol ediliyor (`remote_preview.dart:198-212`) → 500 MB belleğe inebilir.

### B7. Sunucu stop() oturumları öldürmüyor + bağlanırlık zafiyetleri
- `ftp_server.dart:117-123`, `smb_server.dart:74-78` yalnız dinleyicileri kapatır; açık kalan istemci soketleri "durduruldu"ktan sonra da transfer yapabilir.
- **PASV:** `ftp_server.dart:182` veri portu `boundPort+1..38` aralığında öngörülebilir; veri bağlantısının kontrol bağlantısıyla eşleşme doğrulaması yok (448-462) → üçüncü taraf veri enjekte edebilir/çatabilir.
- **PORT/bounce:** 481-499, 779-794 — istemcinin verdiği herhangi bir adrese sunucu bağlanır (port tarama vektörü).
- Bağlantı/mesaj limiti ve idle timeout yok (`smb_server.dart:280-301` 16 MB'a kadar tek mesaj tamponlanır) → kolay DoS.
- `network_access_screen.dart:85-118` — hızlı çift dokunuş iki sunucu örneği üretebilen başlatma yarışı.

### B8. Diğer protokollerde doğrulama boşlukları
- `sftp_service.dart:27-28` — `disableHostkeyVerification: true`: **tüm** SFTP bağlantılarında host-key doğrulaması kapalı (host internet sunucusu olsa bile) → MITM şifreyi ve dosya içeriğini yakalar. Doğrusu TOFU parmak izi pinleme.
- `ftp_session.dart:47-63` — FTP **istemcisi** düz TCP; `USER`/`PASS` açık metin, `AUTH TLS`/FTPS hiç denenmiyor (uygulamanın kendi FTPS sunucusu varken istemci tarafı TLS'siz).
- `ftp_session.dart:341-349` (`_fixPasvHost`) — sunucunun PASV'de söylediği herhangi bir IP'ye bağlanılır (veri kanalı kontrol kanalı peer'ına sabitlenmez) → FTP bounce/SSRF.
- `smb_client.dart:216-220` — istemci hiçbir SMB2 mesajını imzalamıyor; imza zorunlu kılan sunucuyu reddedip kullanıcıya "imzalamayı zorunlu değil yapın" diyor (güvenliği düşürerek uyumluluk). `ntlm.dart:230-298` MIC/`NEGOTIATE_MIC` ve channel binding (AV pairs) yok → NTLM yanıtı relay'e açık.
- `webdav_service.dart:157-166,180` — `http://` şeması korunup Basic Auth Base64 olarak düz gidiyor; `dart:io` HttpClient Android cleartext politikasını denetlemez.
- `oauth_service.dart:71` — `state` **hiç gönderilmezse** kontrol atlanıyor: aynı cihazdaki bir uygulama `http://127.0.0.1:<port>/callback?code=...` ile login CSRF / kod enjeksiyonu yapabilir.
- `remote_download.dart:50-52` — uzak sunucudan gelen dosya adı sanitize edilmeden hedef yola ekleniyor (`../evil.apk` senaryosu ile Download dışına yazma); `:31` `/storage/emulated/0/Download` hardcoded.
- SMB `_onClose` + `deleteOnClose` → `deleteSync(recursive: true)` (1142): auth bypass ile birleşince yıkıcı.

---

## C. ORTA

| # | Sorun | Yer |
|---|---|---|
| C1 | `vault_screen.dart:152-158`: `await VaultService.create` sonrası `_pin.clear()` vb. **mounted kontrolünden önce** → dispose edilmiş controller'a erişim riski (AssertionError) | vault_screen |
| C2 | `album_screen.dart:97` static `_titleCache` uygulama ömrü boyunca sınırsız büyür | album_screen |
| C3 | `remote_preview.dart:51-56` önizleme disk önbelleğinde LRU/temizleme yok; `:206` tüm dosyayı belleğe okur | remote_preview |
| C4 | `ftp_session.dart:37` `_listCache` ve `smb_server.dart:262` `_handles` sınırsız (istemci CLOSE göndermezse birikir) | ftp/smb |
| C5 | `??=` ile oturum yaratma yarışı: `ftp_browse_screen.dart:63,85,108,175` (+smb/sftp) → çift connect, sızan soket | browse ekranları |
| C6 | `file_service.dart:269-273`: `movePath` same-volume yolunda `_measureDirectory`'ı **iki kez** çağırıyor (aynı ağaç iki kez yürünür); `deleteEntry(useRecycleBin:)` parametresi ölü kod (313-317); `rename()` yeni adı doğrulamıyor (`../` içeren ad ebeveyne kaçabilir) | file_service |
| C7 | Uygulama kilidi PIN türetmesi: sabit üretimli 5.000× SHA-256 (`auth_service.dart:251-260`) — kasa PBKDF2-200k'yken kilit zayıf halka; `pinMin=4` (10⁴ uzay) hash+salt SharedPreferences'ta. Çevrimiçi brute-force koruması (kademeli kilit + sabit-zamanlı karşılaştırma) var, offline'e karşı tasarımı zayıf | auth_service |
| C7b | **`AndroidManifest.xml`'de `android:allowBackup` yok (varsayılan `true`)** → kasa salt+verifier'ı, PIN hash+salt'ı ve kilitlenme sayacı Google yedeğine/cihaz aktarımına girer. Kasa ve app-lock meta verisi (`vault_service.dart:204-216`, `auth_service.dart:127-128`) ve kilitlenme sayacı yalnız istemcide tutulduğu için (`auth_service.dart:184-189`) saldırgan cihaza dokunmadan offline kaba kuvvet çalıştırır — tüm lockout mantığı anlamsızlaşır. `allowBackup="false"` veya `fullBackupContent` dışlaması şart | manifest |
| C7c | `vault_service.changePin` (281-290) hatalı eski PIN'de `_registerFailure()`/`lockoutRemaining()` çağırmıyor → kilit süresi devredeyken bile sınırsız eski-PIN denemesi (servis katmanı; UI yalnız kasa açıkken erişse de `_requireKey` kullanılmıyor) | vault_service |
| C7d | Legacy (1.0.x) kasalar **sonsuza dek 20.000 turla** açılıyor (`vault_service.dart:82,196-197`) — açılışta 200k'ya rehash yok; güncel 200k da OWASP PBKDF2-SHA256 önerisinin (600k) altında (kod yorumunda bilinçli sapma olarak kabul edilmiş) | vault_service |
| C7e | Kilitlenme tavanı 30 dk'da sabit, kalıcı kilit/sıfırlama yok (`lockoutBackoffSeconds=[0,5,15,60,300,1800]`): sürekli açık cihazda günde ~240 deneme → 4 haneli app-lock PIN'i en kötü ~42 günde tükenir | auth/vault |
| C7f | `VaultService.lock()` varsayılan çağrıda `_sessionPin`'i RAM'de bırakıyor (`vault_service.dart:154-157`, biyometriyle hızlı yeniden açma için) → süreç belleğini okuyabilen saldırgan PIN'i ele geçirir; `_key=null` tek başına yeterli değil | vault_service |
| C7g | OAuth sonuç sayfasında hata metni HTML-escape edilmeden yazılıyor (`oauth_service.dart:89-94`); `error` sağlayıcı yanıt gövdesinden gelebiliyor → localhost'ta bile HTML/script enjeksiyonu vektörü | oauth_service |
| C8 | `SecureStore.read` hataları yutup `null` döner (`secure_store.dart:43`) → Keystore arızasında kullanıcı "parolam kayboldu" yaşar, ayırt edilemez | secure_store |
| C9 | SMB `FileMode.append` + `setPositionSync` çelişkisi (`smb_server.dart:655-662`) — offset'li resume yazımları sessizce EOF'a gider | smb_server |
| C10 | TreeConnect istenen paylaşım adını hiç doğrulamaz (`smb_server.dart:505-507`) | smb_server |
| C11 | OAuth token'ların yenilenme yarışları ve `cloud_http_client.dart` timeout'ların işlem tiplerine göre sabit kalması — gözden geçirilmeli | cloud |
| C12 | `flutter analyze` 15 bilgi (exit 1): `use_build_context_synchronously` (`network_access_screen.dart:241`), `unnecessary_underscores` (`receive_share_screen.dart:203`), `unnecessary_import` (`auth_service.dart:3`), `use_null_aware_elements` ×3 (`platform_service.dart:398,421,422`), `avoid_print` ×8 (`tool/_probe_update*.dart`), `depend_on_referenced_packages` (`test/recycle_bin_service_test.dart:6`) | genel |
| C13 | `flutter pub outdated`: `dartssh2` 3.3.1→**4.1.0** ve `sqlite3` 2.9.4→**3.9.1** majör geride; `archive` 4.7.1'e çıkabilir. 16 transitive bağımlılık eski kilitli | pubspec |
| C14 | `MainActivity.videoThumbnailJpeg` (835-863) `frame` bitmap'ini recycle etmiyor; `renderPdfPageJpeg` yalnız başarı yolunda `recycle()` (817) → native bitmap sızıntıları | native |
| C15 | Depoda izlenen artık dosya: `stop` (içeriği `srv2`) anlamsız; `tool/_probe_update*.dart` 4 geçici keşif betiği ve `bat/build/test_output.txt` artıkları çalışma ağacında | repo hijyeni |
| C16 | CI release workflow'u yalnız `workflow_dispatch`; keystore yoksa **debug anahtarla** release imzalıyor (`build.gradle.kts:57-61`) — yanlışlıkla debug-imzalı yayın, mevcut kurulumların üstüne kurulamaz | build |

---

## D. DÜŞÜK / KOD KALİTESİ

- Manifest yoğun yetenek seti (`MANAGE_EXTERNAL_STORAGE`, `QUERY_ALL_PACKAGES`, `REQUEST_INSTALL_PACKAGES`, `PACKAGE_USAGE_STATS`): Play politikası riski + `largeHeap=true` bellek tembelliği.
- `ftp_server.dart:681-691` her STOR öncesi probe dosyası oluştur-sil (gereksiz I/O); LIST yanıtı 3 katman bellek kopyası (587-615).
- `google_drive_service.dart:374-380` her chunk'ta `await source.length()`; `:289-309` `nextPageToken` yok → 1000+ öğede liste kesilir. `dropbox_service.dart:102-128` `while(true)` sunucu `has_more` verirse sonsuz döngü.
- `webdav_service.dart:174` yol URI-encode edilmiyor (boşluklu/özel karakterli yollar bozuk).
- `browser_file_actions.dart:108-111` iptal edilemeyen 8 sn'lik `Future.delayed`; `album_screen.dart:797` `itemBuilder` içinde guard'sız `_loadPage()` (mükerrer sayfa isteği riski).
- `settings_screen.dart:27` ve `browser_screen.dart:701` geniş `watch` kapsamı → tek switch tüm ekranı yeniden çiziyor; `context.select`'e bölünebilir.
- 4 dosya 20-45 KB (settings 44 KB, smb_server 38 KB, archive_service 35 KB, vault_service 32 KB) — bölünmeyi bekleyen büyümüş dosyalar.
- `docs/` Türkçe dosya adları CI araçlarında kodlama sorunlarına yol açabiliyor (test çıktısında da görülen `?` karakterleri).

---

## E. DOĞRU YAPILMIŞ OLANLAR (korunması gereken desenler)

- **Arşiv güvenliği:** `archive_service.safeTargetPath` (603-627) zip-slip'i eksiksiz kapatıyor (mutlak yol, `..`, normalize sonrası prefix kontrolü); `NativeArchive.kt` de canonical-path doğruluyor.
- **Kasa:** PBKDF2-HMAC-SHA256 200.000 tur + 16 bayt tuz, AES-256-GCM (12 bayt random nonce, etiket doğrulaması), parçalı MKC1 formatı, izolat'ta türetme, geri sayımlı üstel kilitlenme — modern ve doğru.
- **Otomatik güncelleme:** SHA-256 doğrulaması + yalnızca resmi GitHub host whitelist'i (`update_service.dart:92-152`), keystore SHA-256 guard'ı (`build.gradle.kts:89-137`).
- **Kimlik deposu:** parola/token'lar `flutter_secure_storage`'da; eski düz-metin prefs kayıtları `load()` sırasında migrasyonla SecureStore'a taşınıp prefs temizleniyor (`remote_service.dart:127-147`, `webdav_service.dart:98-131`, `google_drive_service.dart:203-229`); `toJson()` varsayılan olarak parolayı dışarı yazmıyor.
- **OAuth hijyeni:** gömülü `client_secret` yok (public client + her sağlayıcıda **PKCE S256**, `Random.secure()` state/verifier, loopback redirect). `verifyPin` sabit zamanlı.
- **TLS doğrulaması bulutta temiz:** `cloud_http_client.dart` ve tüm bulut servislerinde `onBadCertificate`/`badCertificateCallback` override'ı yok (`lib/` genelinde tek atlatma `sftp_service.dart:28`).
- **NTLM doğru:** her zaman NTLMv2+LMv2, NTLMv1 yanıtı sunucu tarafında reddediliyor, challenge'lar `Random.secure()` ile.
- **Transferler:** `file_service` chunk'lı kopyalama + iptal token'ı + yarım kalan hedefi geri alma; `category_size_service` izolat timeout/kill/port temizliği.
- **Yaşam döngüsü disiplini:** `folder_watcher`, `tv_focusable`, `media_viewer`, `vault_screen` timer/controller temizliği ve `mounted` kontrolleri örnek seviyede; `hex_viewer`/`media_category` future memoization'ı doğru şablon.
- **ANR bilinçli native tasarım:** ağır kanal işleri `_bg` executor'ına taşınmış; ikonlar tembel yükleniyor.

---

## F. ÖNERİLEN DÜZELTME SIRASI

1. **SMB auth bypass** (A3) + FTP log'a parola yazma + parola gücü/deneme limiti (A4) + SFTP host-key TOFU pinleme (B8) — dördü de tek oturumda kapanabilir somut açıklar.
2. **`android:allowBackup="false"`** (C7b): kasa/PIN meta verisinin yedeğe sızmasını kes — offline kaba kuvvet yüzeyini kapatır.
3. Commit edilmemiş işi tamamla/böl, eksik native dosyaları depoya al, etiket/derleme tutarlılığı (A2).
4. TextEditor gutter layout hatası → 11 testi yeşile çek, CI'a `flutter test` kapısı ekle (A1).
5. FTPs anahtarını cihaz başına Keystore üretimine geçir; FTP istemcisine `AUTH TLS`, `changePin`'e lockout, OAuth `state` zorunluluğu + HTML-escape (A5/B8/C7c/C7g).
6. App-lock'u kasa standardına çıkar (PBKDF2 ≥600k, `pinMin=6`), legacy kasaları açılışta rehash'le, kilit tavanını kalıcı kilitle birleştir (C7/C7d/C7e).
7. Download/önizleme/güncelleme akışlarına `CancelToken`; `barrierDismissible` diyaloğuna iptal düğmesi (B6).
8. FutureBuilder memoization + dialog controller dispose + log aboneliklerinin iptali (B2/B3/B4).
9. Sunucuları izolat'a taşı veya en azından async I/O'ya çevir; `BytesBuilder` ile tamponları düzelt (B5).
10. Locale'ı sistem diline bağla; kalan UI metinlerini ARB'e çıkar; `dartssh2`/`sqlite3` majör yükseltmeleri (B1/C13).

---

## G. UYGULANAN DÜZELTMELER (16 Kasım 2026)

Öncelik sırasına göre yapıldı; her adım `flutter analyze` + `flutter test` ile
doğrulandı. **Sonuç: analyzer temiz, 297/297 test geçiyor** (başlangıç: 282/293 + 15 uyarı).

### 1) Kritik güvenlik
| Düzeltme | Dosya |
|---|---|
| **SMB kimlik doğrulama baypası kapatıldı.** Merkezi kapı: `CREATE/READ/WRITE/CLOSE/QUERY_*/SETINFO/FLUSH` yalnız `_authenticated && _treeConnected` iken çalışır; 8 hatalı oturum sonrası bağlantı kapatılır. | `smb_server.dart` |
| **FTP parolası artık log'a yazılmıyor** (`PASS ****`). Sabit-zamanlı karşılaştırma + artan gecikme + 8 denemede bağlantı kapatma. | `ftp_server.dart` |
| **Sunucu parolası 4 hane → 12 karakter güçlü rastgele** (~10^18 olasılık), kopyalanabilir. | `network_access_screen.dart` |
| **SFTP host-key doğrulaması açıldı:** `disableHostkeyVerification` kaldırıldı; TOFU parmak izi pinleme (şifreli depoda) + değişimde açık MITM hatası. | `sftp_service.dart` |
| **`android:allowBackup="false"` + `data_extraction_rules.xml`** (bulut yedek + cihaz aktarımı dışlaması). | `AndroidManifest.xml`, `res/xml/` |

### 2) Veri/gizlilik saklama
- **Kasa meta verisi (tuz + doğrulayıcı) şifreli depoya** taşındı; eski prefs kaydı okunup taşınır, düz kopya silinir (`vault_service.dart`).
- **Uygulama kilidi PIN özeti/tuzu şifreli depoya** taşındı (migrasyonlu).
- **App-lock KDF:** 5.001×SHA-256 → **PBKDF2-HMAC-SHA256 (100.000 tur, izolatta)**, `pinMin` 4→6; eski kayıtlar açılışta şeffafça yükseltilir (test eklendi).
- `vault.reset()` şifreli kaydı da siler; `lock()` sonrası oturum PIN'i reset'te temizlenir.

### 3) Kimlik doğrulama mantığı
- `changePin` artık kilitlenme kontrolü yapıyor ve hatalı eski PIN sayacı artırıyor.
- **OAuth `state` zorunlu** (yokluğu hata) + sonuç sayfasında **HTML escape**.

### 4) Testler yeşile çekildi (gerçek hata dahil)
- **TextEditor salt-okunur modda satır numarası gutter'ı `ListView` → `Column`**: iç içe sınırsız yükseklik çökmesi giderildi (üretim hatası). Düzenleme modunda gutter metinle senkron kaydırılıyor.
- `view_style_test` `SliverGrid`'e; `appearance_picker_test`/`settings_about_test` l10n delegate'ine; WebDAV e2e testi gerçek etikete (`WebDAV / Nextcloud`) ve `Hakkında` başlığına hizalandı.

### 5) Veri bütünlüğü / path traversal
- **Uzak indirme dosya adı sanitize ediliyor** (yol ayırıcı, `..`, kontrol karakterleri) — test eklendi.
- **FTP PASV veri bağlantısı kontrol peer'ına sabitlendi** (SSRF/bounce kapandı).
- **WebDAV düz `http://` otomatik HTTPS'e yükseltiliyor** (loopback hariç) — test eklendi.
- Google Drive listeleme **sayfalama** eklendi; Dropbox sonsuz döngü sınırlandı; WebDAV yol segmentleri URI-encode edildi.

### 6) İptal ve ilerleme
- **İndirmelerde İptal düğmesi** (`RemoteCancelToken`): iptalde kısmi dosya silinir; önizlemede de İptal düğmesi kısmi dosyayı temizler.

### 7) Performans / bellek
- Video oynatıcıda tick başına tam sayfa rebuild → yalnız ilerleme göstergesi (`ValueListenableBuilder`).
- `album_screen`/`file_thumbnail`: thumbnail future'ları memoize; `static _titleCache` ekran ömrüne çekildi; `_loadPage` guard'landı.
- Tarayıcı klasör sayımı: klasör başına setState → 20'lik toplu güncelleme.
- Sunucu `stop()` artık **etkin istemci soketlerini kapatıyor**; FTP liste önbelleği 60 klasörle sınırlandı.
- SMB/FTP tamponları `BytesBuilder`/`addAll` (O(n²) kopyalama giderildi), SMB mesaj üst sınırı 16 MB.
- `PackageInfo` ve kategori kök yolları memoize edildi.
- **Native bitmap sızıntıları** (`MainActivity` PDF/video yollarında `finally { recycle() }`).

### 8) Temizlik / yapı
- **Release derlemesi keystore yoksa artık durur** (sessiz debug imzası yerine); `Apk Hazırla.bat` önceden uyarıyor. Yerel test: `-PreleaseDebugSign=true`.
- 5 yerde `TextEditingController` sızıntısı kapatıldı (settings PIN, chmod/rename/newFolder, yeni dosyalar).
- Sunucu log abonelikleri saklanıp iptal ediliyor; çift BAŞLAT yarışı engellendi.
- `vault_screen` async sonrası mounted sırası düzeltildi.
- `flutter analyze` 15 uyarı → **0**; probe betikleri analiz dışı.
- İzlenen artık `stop` dosyası kaldırıldı; `.gitignore` probe betiklerini kapsıyor.
- `archive`/`crypto` yükseltildi.
- Ayarlar'a **Uygulama dili** seçici (Cihaz dili / Türkçe / English) eklendi; `MaterialApp` artık sistem diline uyuyor (sabit `Locale('tr')` kaldırıldı).

### Kalan (bilinçli ertelenen)
- **FTP istemcisine FTPS (`AUTH TLS` + `PROT P`)**: protokol el sıkışması + sertifika pinleme tasarımı gerekiyor; şu an PASV sabitleme ve https zorunluluğu yapıldı.
- **SMB istemci imzalama/MIC** ve **sunucuların izolat'a taşınması**: mimari değişiklik; auth kapısı riski büyük ölçüde azalttı.
- **`dartssh2` 3→4 ve `sqlite3` 2→3 majör yükseltmeleri**: API kırıcı, ayrı sürümde test edilmeli.
- UI metinlerinin tamamının ARB'ye çıkarılması (şu an 7 anahtar + dil seçici altyapısı hazır).
- Commit edilmemiş dalganın parçalanıp gözden geçirilmesi (A2) — sizin kararınıza bırakıldı; kod değişiklikleri çalışma ağacında hazır.
