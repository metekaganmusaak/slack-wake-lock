# Slack Wake Lock v1.0.0 — macOS

macOS 13 veya üzeri. Universal uygulama: Apple Silicon (M serisi) ve Intel.
Arayüz Türkçedir. Bağımsız bir projedir; Slack/Salesforce ile ilişkili değildir.

## İndirip kullanma

1. `Slack-Wake-Lock-1.0.0-macos-universal.zip` dosyasını aç.
2. `Slack Wake Lock.app` uygulamasını Applications/Uygulamalar klasörüne kopyala ve aç.
3. Sistem Ayarları → Gizlilik ve Güvenlik → Erişilebilirlik bölümünde Slack Wake Lock'a izin ver.
4. Slack masaüstü uygulamasında oturum aç. Slack Wake Lock menü çubuğunda görünür.

Mac açılınca otomatik başlatmayı menüden açabilirsin. Geçici kilit her
yeniden başlatmada kapalı başlar.

Otomatik kurulum ve Slack'in arka planda uyutulmasını engelleyen App Nap ayarı
için aynı klasörde `bash install.sh` çalıştırılabilir. Release içindeki kurulum
betiği hazır uygulamayı kullanır; Xcode veya Swift derleyicisi gerekmez.
Önceki Wakelock kurulumu varsa `bash install.sh` eski uygulamayı yeni adla
değiştirir; mevcut çalışma saatleri ve tercihler korunur.

## İlk açılış ve Apple onayı

Bu sürüm **ad hoc imzalıdır; Apple Developer ID imzası ve noter onayı yoktur**.
İnternetten indirildiğinde macOS ilk açılışı engelleyebilir. Dosyayı ve
kaynağını doğruladıktan sonra Sistem Ayarları → Gizlilik ve Güvenlik →
Yine de Aç yolunu kullanabilirsin. Kurumsal cihaz politikaları buna izin
vermeyebilir. Sistem güvenliğini genel olarak kapatmak gerekmez.

Apple'ın açıklaması: https://support.apple.com/102445

## Bu sürümde

- Çalışma saatleri, molalar ve duraklatma seçenekleri.
- Şifre ekranıyla geçici masaüstü kaplaması; varsayılan PIN **123456**.
- Siyah zemin, pil göstergesi, 5 saniye sonra parlaklık azaltma ve fareyle geri açma.
- Yalnızca Slack banner'ları için son üç önizleme ve isteğe bağlı ek uyarı sesi.
- Slack renklerinden esinlenen macOS uygulama ikonu.
- Cuma vakitleri isteğe bağlı; yeni kurulumlarda kapalı.

## Sınırlar

Geçici şifre ekranı macOS'un güvenli kilidi değildir. PIN kaynakta açıktır.
Bildirim önizlemeleri şifre girmeden görülebilir. Uygulama kapatılırsa veya
zorla sonlandırılırsa kaplama kalkar. Gerçek güvenlik için macOS kilidini kullan.

Slack çevrimiçi durumu garanti edilmez. Ağ, Slack ayarları, gerçek ekran
kilidi, uyku ve kapalı kapak bunu etkileyebilir. Parlaklık için kullanılan
DisplayServices arayüzü ve bildirimlerin Erişilebilirlik yapısı macOS
sürümlerinde değişebilir; harici ekran desteği donanıma bağlıdır.

Apple Silicon üzerinde çalışma testleri yapılmıştır. Intel dilimi derlenip
paket yapısı doğrulanmıştır; fiziksel Intel Mac üzerinde test edilmemiştir.

Gizlilik ayrıntıları `PRIVACY.md`, lisans `LICENSE` dosyasındadır.

## Kaldırma

Bu klasörde `bash uninstall.sh`; yerel ayarları da silmek için
`bash uninstall.sh --all` çalıştır. Otomatik kurulum ~/Applications yolunu
kullanır; uygulamayı farklı bir klasöre elle kopyaladıysan onu da kaldır.

## GitHub'a yükleme

1. Kişisel hesabında `slack-wake-lock` isimli public repo oluştur.
2. Kaynak ZIP'ini **açıp içindeki dosyaları** repo köküne yükle. ZIP'in kendisini kaynak kod yerine yükleme.
3. Releases → Draft a new release → yeni etiket `v1.0.0`, başlık `Slack Wake Lock v1.0.0`.
4. Uygulama ZIP'i ve `Slack-Wake-Lock-1.0.0-SHA256SUMS.txt` dosyasını release'e ekle.
5. Bu dosyanın GitHub'a yükleme bölümünden önceki kısmını release açıklaması olarak kullan ve yayınla.

Sonraki sürümlerde VERSION dosyasını güncelleyip `bash release.sh` çalıştır.
Betik uygulama ZIP'ini, temiz kaynak ZIP'ini ve SHA-256 listesini `dist/`
altına üretir; GitHub'a otomatik yükleme yapmaz. Yeni sürümün release
açıklamasındaki sürüm adını da güncelle.
