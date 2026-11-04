# 📋 Cihaz Üstü Test Matrisi (Manuel)

> Otomatik testler (`flutter test`) mantığı ve iş kuralını korur; ancak **izin
> akışları, depolama birimleri, ağ sunucuları ve cihaz üretici katmanları**
> yalnızca gerçek cihazda doğrulanabilir. Bu matris her yayın öncesi bir kez
> koşulur; sonuçlar sürüm notu yerine bu dosyaya işaretlenir.
>
> Otomatik kapsam: `flutter analyze` + `flutter test` (CI tarafından her
> push/PR'da koşulur). Bu dosya: **yalnızca otomasyonun kapsayamadığı
> durumlar**.

## Test cihazları

| Kod | Cihaz | Android | Not |
|---|---|---|---|
| **C1** | Samsung Galaxy (One UI) | 14+ | Üretici dosya yöneticisi rekabeti; agresif arka plan kısıtları |
| **C2** | Xiaomi / Redmi (MIUI) | 13+ | Pil optimizasyonu izin akışını kırabilir |
| **C3** | Google Pixel / emülatör | 15+ | Saf Android + Material You (dinamik renk) |
| **C4** | Tablet (Samsung Tab vb.) | 13+ | Geniş ekran, iki panel, sürükle-bırak |
| **C5** | Android TV / TV kutusu | 12+ | D-pad odak, leanback, TV kanalı |

Her satır: **C1 · C2 · C3 · C4 · C5** — uygun değilse `—` işaretlenir.

---

## 1. İzin ve ilk açılış

| # | Adım | Beklenen | C1 | C2 | C3 | C4 | C5 |
|---|---|---|---|---|---|---|---|
| 1.1 | Temiz kurulum → ilk açılış | Sürüm seçimi (Mobil-Tablet / TV) ekranı çıkar | | | | | |
| 1.2 | Dosya izni reddedilir | Uygulama açılmaz, anlaşılır Türkçe uyarı | | | | | |
| 1.3 | `MANAGE_EXTERNAL_STORAGE` isteği | "Tüm dosyalara erişim" ekranı açılır, onaylanınca geri dönülür | | | | | |
| 1.4 | İzin verilmeden tarayıcı açılır | Boş liste + izin butonu, **çökme yok** | | | | | |

## 2. Depolama birimleri (USB OTG / SD)

| # | Adım | Beklenen | C1 | C2 | C3 | C4 | C5 |
|---|---|---|---|---|---|---|---|
| 2.1 | Hiçbir birim yokken "USB / SD" açılır | Boş durum mesajı, hata yok | | | | | |
| 2.2 | SD kart takılır → "USB / SD" yenilenir | Birim listelenir, ad + durum doğru | | | | | |
| 2.3 | USB OTG flash takılır | Birim listelenir ve tarayıcıyla gezinilebilir | | | | | |
| 2.4 | Birime dosya yazılır (kopyala) | Dosya yazılır, hata yok | | | | | |
| 2.5 | Birim güvenli çıkarılır | Listeden kaybolur; açık tarayıcı hata verir ama **çökmez** | | | | | |
| 2.6 | Ağaç görünümünde birim düğümü | Sürükle-bırak hedefi olarak çalışır | | | | | |

## 3. Dosya işlemleri

| # | Adım | Beklenen | C1 | C2 | C3 | C4 | C5 |
|---|---|---|---|---|---|---|---|
| 3.1 | Kopyala / taşı (tek dosya) | SnackBar + liste tazelenir | | | | | |
| 3.2 | Çoklu seçim → toplu sil | Onay diyaloğu, hepsi silinir | | | | | |
| 3.3 | Çoklu seçim → toplu kopyala | Hedef klasörde hepsi belirir | | | | | |
| 3.4 | Aynı adlı dosya üzerine yazma | Çakışma diyaloğu çıkarsa doğru çalışır | | | | | |
| 3.5 | 1 GB dosya kopyalanır | **İlerleme gösterilir**, uygulama donmaz | | | | | |
| 3.6 | Kopyalama sırasında geri tuşu | İşlem ya devam eder ya iptal olur; **çift iş olmaz** | | | | | |
| 3.7 | Sil → Geri Dönüşüm Kutusu'ndan geri yükle | Dosya eski yerine döner, içerik bozulmaz | | | | | |
| 3.8 | Geri dönüşüm kutusunu boşalt | Kalıcı silinir, alan geri kazanılır | | | | | |
| 3.9 | Tablette listeden ağaça sürükle-bırak | Kopyalama yapılır, hedef klasör tazelenir | | | | | |

## 4. Görüntüleyiciler ve editör

| # | Adım | Beklenen | C1 | C2 | C3 | C4 | C5 |
|---|---|---|---|---|---|---|---|
| 4.1 | `.txt` açılır | Metin editörü açılır, düzenleyip kaydedilir | | | | | |
| 4.2 | >1 MB `.txt` | Salt-okunur uyarı bandı + kırpılmış görünüm | | | | | |
| 4.3 | Kaydedilmemiş değişiklikle çıkış | Onay diyaloğu | | | | | |
| 4.4 | `.bin` / bilinmeyen uzantı → Hex | Offset + hex + ASCII akıcı (sonsuz rebuild yok, CPU normal) | | | | | |
| 4.5 | Çok büyük dosya hex'de kaydırma | Sanal liste akıcı, bellek patlamaz | | | | | |
| 4.6 | `.db` → SQLite görüntüleyici | Tablolar listelenir, 500 satır gösterilir | | | | | |
| 4.7 | Şifreli / bozuk `.db` | Anlaşılır hata, **çökme yok** | | | | | |
| 4.8 | Görüntü / video / ses | Sistem uygulamasıyla açılır | | | | | |

## 5. Kök (root) ve chmod

| # | Adım | Beklenen | C1 | C2 | C3 | C4 | C5 |
|---|---|---|---|---|---|---|---|
| 5.1 | Root'suz cihazda "İzinleri değiştir" | "Root gerekli" mesajı, işlem yapılmaz | | | | | |
| 5.2 | Root'luda `su` reddedilir (Magisk izni yok) | Anlaşılır hata, kilitlenme yok | | | | | |
| 5.3 | Root'luda `chmod 755` | İzin değişir, bilgi diyaloğu yeniden açınca **yeni değeri** gösterir | | | | | |
| 5.4 | Geçersiz mod girdisi (`abc`, `999`) | Sekizlik doğrulaması reddeder | | | | | |
| 5.5 | Boşluk/tırnak içeren yol | Yol kaçışı yapılır; komut enjeksiyonu **imkânsız** | | | | | |
| 5.6 | Root'suzda dosya bilgisi diyaloğu | POSIX izin metni yine gösterilir (salt okunur) | | | | | |

## 6. Arşivler

| # | Adım | Beklenen | C1 | C2 | C3 | C4 | C5 |
|---|---|---|---|---|---|---|---|
| 6.1 | `.zip` açılır | Arşiv içi klasör ağacı gezilir | | | | | |
| 6.2 | "Tümünü çıkar" (ilerleme ile) | İlerleme çubuğu akar, bitince dosya sayısı + alan özeti | | | | | |
| 6.3 | Tek dosya çıkarılır | Doğru hedefe iner, içerik bozulmaz | | | | | |
| 6.4 | Klasör içeren zip | Alt klasör yapısı korunur | | | | | |
| 6.5 | `..` içeren zararlı zip (Zip-Slip) | **Reddedilir**, hedef dışına yazılmaz | | | | | |
| 6.6 | Şifreli / bozuk zip | Anlaşılır hata, çökme yok | | | | | |
| 6.7 | `.rar` / `.7z` | Android'de native açılır (liste + çıkarma); bozuk/şifreli arşivde anlaşılır hata | | | | | |
| 6.8 | Seçilen dosyaları zip'e ekle | Klasörde yeni zip oluşur, liste tazelenir | | | | | |

## 7. Kasa (gizli klasör)

| # | Adım | Beklenen | C1 | C2 | C3 | C4 | C5 |
|---|---|---|---|---|---|---|---|
| 7.1 | İlk kez kasa ekranı | PIN oluşturma (6–12 hane) akışı | | | | | |
| 7.2 | Tarayıcıdan "Kasaya taşı" | Dosya yerinde kalır, kasa açıksa kopya şifrelenip eklenir | | | | | |
| 7.3 | Kilitliyken "Kasaya taşı" | Önce kasa ekranı açılır, PIN sorulur | | | | | |
| 7.4 | Yanlış PIN (art arda) | Geri sayım + devre dışı buton görünür | | | | | |
| 7.5 | Geri sayım sırasında uygulama kapat/aç | Sayaç **kalıcı** sürer, sıfırlanmaz | | | | | |
| 7.6 | Doğru PIN | Kasa açılır, sayaç sıfırlanır | | | | | |
| 7.7 | Dışa aktar | `Download/Kasa` altına çözülmüş kopya iner | | | | | |
| 7.8 | Uygulama verisi temizlenir (veya sıfırlama) | Kasaya erişilemez — anahtar kaybolur (beklenen davranış) | | | | | |
| 7.9 | Eski sürümden yükseltme | 1.0.10'da oluşturulan kasa **yeni sürümde hâlâ açılır** | | | | | |

## 8. Ağ: sunucular

| # | Adım | Beklenen | C1 | C2 | C3 | C4 | C5 |
|---|---|---|---|---|---|---|---|
| 8.1 | FTP sunucusu başlat | IP + port + rastgele şifre gösterilir | | | | | |
| 8.2 | PC'den FTP ile bağlan (aynı ağ) | Listeleme, indirme, yükleme çalışır | | | | | |
| 8.3 | FTPS (şifreli) | TLS el sıkışması başarılı | | | | | |
| 8.4 | Yanlış şifre | Bağlantı reddedilir | | | | | |
| 8.5 | SMB sunucusu başlat | Windows'tan `\\<ip>` ile erişilir | | | | | |
| 8.6 | Ekran kilitlenir / uygulama arka plana alınır | Sunucu ayakta kalır ya da düzgün kapanır | | | | | |
| 8.7 | Uçak modu | Uygulama **çökmez**, hata mesajı gösterir | | | | | |

## 9. Ağ: istemciler ve bulut

| # | Adım | Beklenen | C1 | C2 | C3 | C4 | C5 |
|---|---|---|---|---|---|---|---|
| 9.1 | FTP / SMB / SFTP / WebDAV kaydet | Kayıt kalıcı, yeniden açılışta listede | | | | | |
| 9.2 | Ulaşılamayan sunucu | Türkçe hata, kilitlenme yok | | | | | |
| 9.3 | Google Drive OAuth | Tarayıcı açılır, callback gelir, gezinilir | | | | | |
| 9.4 | Dropbox / OneDrive / Box OAuth | Aynı akış sağlayıcıya göre çalışır | | | | | |
| 9.5 | Jeton süresi dolarsa | Otomatik yenileme, gerekiyorsa yeniden bağlanma | | | | | |
| 9.6 | Ağ keşfi (LAN taraması) | SMB/FTP sunucuları listelenir | | | | | |

## 10. Performans ve kararlılık

| # | Adım | Beklenen | C1 | C2 | C3 | C4 | C5 |
|---|---|---|---|---|---|---|---|
| 10.1 | 20.000+ dosyalı klasör açılır | Liste akıcı; tarama izolat'ta, **UI donmaz** | | | | | |
| 10.2 | Ana ekran (kategori boyutları hesaplanırken) | Kartlar dolu, arka planda hesaplanır | | | | | |
| 10.3 | Mükerrer dosya taraması (büyük depo) | İlerleme gösterilir, biter | | | | | |
| 10.4 | 30 dk kesintisiz kullanım | Bellek artışı geri döner (sızıntı yok) | | | | | |
| 10.5 | Arka arkaya 20 ekran aç/kapa | Bellek sabit, çökme yok | | | | | |
| 10.6 | Hex görüntüleyicide büyük dosya kaydırma | CPU normal; **sonsuz rebuild döngüsü yok** | | | | | |

## 11. Arayüz uyarlamaları

| # | Adım | Beklenen | C1 | C2 | C3 | C4 | C5 |
|---|---|---|---|---|---|---|---|
| 11.1 | Koyu tema | Tüm ekranlarda tutarlı, kontrast yeterli | | | | | |
| 11.2 | Material You (Android 12+) | Sistem rengi uygulanır; Ayarlar'dan kapatılınca turkuaza döner | | | | | |
| 11.3 | Geniş ekran (tablet) | İki panel, sürükle-bırak aktif | | | | | |
| 11.4 | Dar ekran (360×640) | Kartlarda **taşma yok**, kaydırma çalışır | | | | | |
| 11.5 | TV: D-pad gezinme | Her ekranda odak görünür, geri tuşu çalışır | | | | | |
| 11.6 | Yatay/dikey döndürme | Ekran durumu korunur, liste kaybolmaz | | | | | |
| 11.7 | Türkçe metin taşmaları | Uzun adlarda kırpma/kesme doğru | | | | | |

## 12. Güncelleme

| # | Adım | Beklenen | C1 | C2 | C3 | C4 | C5 |
|---|---|---|---|---|---|---|---|
| 12.1 | Yeni sürüm yayınlandığında açılış | Güncelleme diyaloğu çıkar | | | | | |
| 12.2 | İndir + SHA256 doğrulama | Özet eşleşmezse dosya **silinir** | | | | | |
| 12.3 | Kurulum (üzerine yazma) | İmza aynı → güncelleme kurulur | | | | | |
| 12.4 | İptal / tekrar dene | Durum temizlenir, ikinci deneme çalışır | | | | | |

---

## Yayın öncesi smoke (zorunlu kısa liste)

Her APK yayını öncesi **en az C3** (veya C1) üzerinde işaretleyin. Tam matris
ayrıca doldurulur; bu liste kararlılık regresyonunu hızlı yakalar.

| # | Adım | Beklenen | ✓ |
|---|---|---|---|
| S1 | Temiz kurulum → sürüm seçimi → izin | Çökme yok, ana ekran açılır | |
| S2 | Tarayıcıda klasör oluştur / yeniden adlandır / sil | SnackBar başarı veya hata; sessiz fail yok | |
| S3 | 50+ MB dosya kopyala, iptal et | İlerleme + iptal; çift dosya yok | |
| S4 | Farklı birime taşı (mümkünse USB/SD) | Kaynak silinemezse **uyarı** SnackBar | |
| S5 | Bellek Analizi + Geçici Dosyalar aç | UI donmaz; sonuç gelir veya zaman aşımı mesajı | |
| S6 | Kasa: PIN oluştur, küçük dosya ekle, çıkış/giriş | Açılır; >4 MB parçalı (MKC1); >512 MB reddedilir | |
| S7 | Arşiv çıkar → İptal | Kısmi klasör temizlenir | |
| S8 | Güncelleme diyaloğı (veya sahte release) | SHA yoksa / uyuşmazsa **kurulum yok** | |
| S9 | TV veya yatay tablet (varsa) | Odak / çift panel çökmez | |

## Koşum kaydı

| Sürüm | Tarih | Cihazlar | Sonuç | Notlar |
|---|---|---|---|---|
| 1.0.43+ | 2026-11-04 | — | ⏳ Manuel | Kod/depo hazır (A28–A29b). Yayın öncesi **yalnızca** smoke S1–S9 gerçek cihazda (en az C3) işaretlenecek — otomasyon dışı tek açık kapı |
| 1.0.31 | 2026-10-20 | — | ⏳ Bekliyor | Kararlılık sertleştirme (SHA zorunlu, izolat, kasa, arşiv iptal); smoke S1–S9 doldurulacak |
| 1.0.10 | 2026-10-11 | C3 (emülatör) | ⚠️ Kısmi | Yalnızca otomatik testler koşuldu; cihaz matrisi bu sürümden itibaren uygulanacak |

## Bilinen kabul edilen sınırlar

- **RAR / 7z** — Android'de Junrar + commons-compress (`NativeArchive`) ile
  okunur/çıkarılır. Diğer platformlarda veya bozuk/şifreli arşivde anlaşılır
  hata gösterilir.
- **x86_64 + arm32 + arm64 tek APK** — boyut (~64 MB) üç mimarinin
  `libflutter` + `libapp` kopyalarından gelir. Kullanıcı mimari seçmez;
  bu bilinçli tercihtir.
- **Kasa PIN'i cihaz kaybında sınırlı koruma sağlar** — cihaz ele geçtiğinde
  geri sayım kilitlenmesi offline denemeleri yavaşlatır, ama tamamen engellemez.
- **`MANAGE_EXTERNAL_STORAGE` + `QUERY_ALL_PACKAGES`** — Google Play
  incelemesinde gerekçe ister; dağıtım şu an APK (yan yükleme) üzerinden.
