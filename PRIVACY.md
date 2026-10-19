# Gizlilik ve public paylaşım

## Pakette bulunmayan veriler

Kaynak ve release ZIP'leri açık bir dosya listesiyle oluşturulur. Kullanıcı
ayarları, günlükler, duraklatma durumu, namaz vakti önbelleği, Slack oturumu,
mesaj geçmişi, Git geçmişi, iş e-postası, sertifika ve API anahtarları pakete
alınmaz. Dosyalar mevcut kullanıcı dizini üzerinden belirlenir; belirli bir
Mac'e ait mutlak kullanıcı yolu kaynakta tanımlı değildir.

## Kullanıcıya özel dosyalar

Önceki Wakelock sürümündeki ayarları korumak için veri yolları ve
`local.wakelock` uygulama kimliği değişmez; görünen ad Slack Wake Lock'tur.

- `~/Library/Application Support/Wakelock/config.json`: çalışma saatleri ve tercihler.
- Aynı dizindeki `state.json` ve `prayer-cache.json`: duraklatma ve isteğe bağlı vakit önbelleği.
- `~/Library/Logs/Wakelock.log`: uygulama durumu, izin hataları, kıpırdatma ve bildirim adetleri.
- `~/Library/LaunchAgents/local.wakelock.plist`: otomatik başlatma seçilirse uygulama yolu.

Bu dosyalar kullanıcının kendi Mac'inde oluşturulur. Hata bildirimi açarken
günlükleri paylaşmadan önce gözden geçir: çalışma saatleri ve seçilen şehir
günlüklere yansıyabilir.

## Slack ve izinler

Slack token'ı, parolası veya çerezi okunmaz; Slack API'sine bağlanılmaz.
Erişilebilirlik izni sanal fare hareketi, geçici kilit sırasında kısayol
denetimi ve yalnızca Slack banner önizlemelerini okumak için kullanılır.
Gönderen ve mesaj önizlemeleri bellekte tutulur, günlüğe yazılmaz ve kilit
açıldığında temizlenir. Bu önizlemeler şifre girmeden görülebilir.

Geçici ekranın varsayılan PIN'i **123456**'dır ve kaynak kodda açıktır. Bu,
macOS hesabının parolası değildir. Geçici ekran gerçek güvenli ekran kilidi
yerine kullanılmamalıdır.

## Ağ bağlantıları

Slack Wake Lock telemetri ve analitik servisi içermez. Cuma vakti özelliği yeni
kurulumlarda kapalıdır. Açılırsa seçilen şehir, ülke ve hesaplama yöntemiyle
`https://api.aladhan.com` adresinden vakitler alınır; bu servis bağlantının
IP adresini de görebilir. Mevcut kullanıcıların config.json tercihleri korunur.
İndirme/ayar menülerindeki bağlantılar yalnızca kullanıcı seçerse açılır.

## Derleme ve dağıtım

Release Apple Developer/kurum sertifikası kullanmadan ad hoc imzalanır; bir
kurumun imza kimliği pakete eklenmez. Derlemede kaynak dizini yolları
`-file-prefix-map` ile genelleştirilir. Arşivler macOS kaynak çatalları ve
genişletilmiş dosya öznitelikleri taşınmadan hazırlanır.
