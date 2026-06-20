# HLS (m3u8) İndirme Desteği — Uygulama Planı

Her faz bağımsız bir session'da tamamlanabilir. Faz sonunda testler geçmeli ve
mevcut indirmeler bozulmamalı.

---

## Bağlam

### Mevcut Akış (normal indirme)
```
addUrl(url, options)
  → Download nesnesi oluştur + meta kaydet
  → start() → execute()
      → probeUrl()          # HEAD/GET → totalSize, filename, acceptsRanges
      → planChunks()        # chunk listesi oluştur
      → Chunk[] paralel indir
      → parça dosyaları birleştir → final dosya
```

### HLS Akışı (hedef)
```
addUrl(url, options)        # aynı API — değişmez
  → Download nesnesi oluştur
  → start() → execute()
      → probeUrl()          # Content-Type: application/x-mpegurl → isHls = true
      → HlsSession.run()
          → master.m3u8 indir + parse
          → en iyi stream seç (bandwidth)
          → media playlist indir + parse → segment URL listesi
          → segment'leri paralel indir (.ts parçalar)
          → ffmpeg ile birleştir → final dosya (.mp4 / .mkv / .ts)
```

### Kapsam Dışı
- DASH (MPD) desteği — ayrı faz
- YouTube özel formatları
- DRM (şifreli HLS)
- Canlı stream (live m3u8 — sonsuz playlist)

---

## Ortak Ön Koşul: `filename` ve `targetPath` per-download parametreleri

**TypeScript** — `DownloadOptions` zaten her ikisini de destekliyor (`filename?`,
`targetPath?`). TS tarafında ek değişiklik gerekmez.

**Dart** — `DownloadOptions` zaten her ikisini de içeriyor (`filename?`,
`targetPath?`). Dart tarafında da ek değişiklik gerekmez.

**Extension → Engine iletişimi** — `ws_server.dart` `add-url` mesajında
`filename` ve `targetPath` alanlarını kabul etmeli. Şu an sadece `url`
okunuyor. Bu Faz 0'da düzeltilecek.

---

## Faz 0 — WebSocket `add-url` mesajına `filename` ve `targetPath` ekle

**Amaç:** Extension'dan gelen `pageTitle` ve ileride eklenecek `targetPath`'in
engine'e ulaşmasını sağla.

### TypeScript (`apps/downloadx`)
Değişiklik yok — `DownloadOptions` zaten tam.

### Dart (`apps/dlx_ui/lib/services/ws_server.dart` + `download_service.dart`)

`_onWsMessage` içinde `add-url` case'ini genişlet:

```dart
case 'add-url':
  final url = msg['url'] as String?;
  if (url == null) break;
  final options = DownloadOptions(
    filename: msg['filename'] as String?,
    targetPath: msg['targetPath'] as String?,
  );
  addUrl(url, options: options);
```

### Extension (`background.js`)

`add-url` mesajına `filename` (pageTitle) ekle:

```js
sendWs({ action: 'add-url', url: msg.url, filename: msg.filename });
```

### Test
- Extension'dan bir URL gönder, `filename` alanı dolu gelsin
- Flutter'da indirme başlasın, dosya adı doğru olsun

---

## Faz 1 — m3u8 Tespiti (TypeScript + Dart)

**Amaç:** `probeUrl` sonucuna `isHls` flag'i ekle, `execute()` içinde dallanma
noktası oluştur. Henüz HLS indirme yok — flag varsa `error` state'e düş
("HLS not yet supported") + log.

### TypeScript

**`types.ts`** — `ProbeResult`'a alan ekle:
```ts
interface ProbeResult {
  // ... mevcut alanlar
  isHls: boolean;   // Content-Type: application/x-mpegurl veya .m3u8 URL
}
```

**`probe.ts`** — `_finalize()` içinde:
```ts
const ct = raw.contentType?.toLowerCase() ?? '';
const isHls = ct.includes('mpegurl') || ct.includes('x-m3u8')
           || opts.url.split('?')[0].endsWith('.m3u8');
return { ...existing, isHls };
```

**`download.ts`** — `execute()` içinde probe sonrası:
```ts
if (this._probe.isHls) {
  this.transition('error');
  this._meta.errorMessage = 'HLS not yet supported';
  return;
}
```

### Dart

**`types.dart`** — `ProbeResult`'a `bool isHls` ekle.

**`probe.dart`** — `_finalize()` içinde aynı mantık.

**`download.dart`** — `execute()` içinde aynı dallanma.

### Test
- `.m3u8` URL'i `addUrl` ile ekle → state `error`, mesaj "HLS not yet supported"
- Normal URL → davranış değişmez

---

## Faz 2 — m3u8 Parser (TypeScript + Dart)

**Amaç:** Master playlist ve media playlist'i parse eden saf fonksiyonlar.
Network bağımlılığı yok — sadece metin parse.

### Veri Modelleri

```ts
// TypeScript
interface HlsStream {
  bandwidth: number;
  resolution?: string;   // "1920x1080"
  codecs?: string;
  uri: string;           // media playlist URL (göreceli veya mutlak)
}

interface HlsMasterPlaylist {
  streams: HlsStream[];  // bandwidth'e göre azalan sırada
}

interface HlsSegment {
  uri: string;
  durationSec: number;
  byteRange?: { offset: number; length: number };
}

interface HlsMediaPlaylist {
  segments: HlsSegment[];
  totalDurationSec: number;
  isLive: boolean;       // #EXT-X-ENDLIST yoksa live
  targetDuration: number;
}
```

Dart'ta aynı modeller `hls_types.dart` dosyasına.

### Parser Kuralları

**Master playlist** (`#EXT-X-STREAM-INF` satırları var):
- Her `#EXT-X-STREAM-INF` satırından `BANDWIDTH`, `RESOLUTION`, `CODECS` parse et
- Hemen altındaki satır stream URI'si
- Göreceli URI'leri base URL'e göre mutlak yap

**Media playlist** (`#EXTINF` satırları var):
- `#EXTINF:<süre>,` → segment süresi
- `#EXT-X-BYTERANGE` varsa byte range kaydet
- `#EXT-X-ENDLIST` yoksa `isLive = true`
- Göreceli URI'leri mutlak yap

**Stream seçimi:**
```ts
function selectBestStream(master: HlsMasterPlaylist): HlsStream {
  return master.streams[0]; // zaten bandwidth azalan → en yüksek
}
```

### Dosya Konumu
```
apps/downloadx/src/hls/
  parser.ts      # parse fonksiyonları
  types.ts       # HlsStream, HlsSegment vb.

apps/downloadx_dart/lib/src/hls/
  parser.dart
  types.dart
```

### Test
- Birkaç gerçek m3u8 örneği ile unit test (master + media)
- Göreceli URL çözümlemesi test edilmeli
- `isLive: true` tespiti test edilmeli

---

## Faz 3 — HLS Segment İndirici (TypeScript + Dart)

**Amaç:** Media playlist'teki segment'leri indirip `{cachePath}/{id}/seg-{n}.ts`
olarak kaydet. İlerleme raporla, pause/cancel destekle.

### `HlsSession` Sınıfı

```ts
class HlsSession {
  constructor(
    private download: Download,
    private io: Io,
    private fetch: FetchFn,
    private throttle: Throttle,
  ) {}

  async run(masterUrl: string, options: HlsOptions): Promise<void> {
    // 1. master.m3u8 indir
    // 2. parse → stream seç
    // 3. media playlist indir + parse
    // 4. isLive kontrolü → live ise hata ver (kapsam dışı)
    // 5. segment'leri sırayla/paralel indir
    // 6. her segment sonrası progress event emit et
  }
}

interface HlsOptions {
  targetFilename: string;   // final dosya adı (.mp4 veya .ts)
  maxParallelSegments: number;  // varsayılan 4
}
```

### İlerleme Hesabı

Toplam segment sayısı belli → her segment `1/N` ilerleme. Segment boyutları
farklı olduğu için byte-bazlı ilerleme Faz 4'te ffmpeg çıktısıyla gelecek.

### Pause/Cancel

Her segment inmeden önce `pauseRequested` / `cancelRequested` kontrol et.
Yarım kalan segment dosyasını sil.

### Hata Yönetimi

Mevcut `retry.ts` / `retry.dart` mekanizmasını kullan — segment başına
`maxRetries` deneme.

### Test
- Mock fetch ile 5 segment'lik playlist → tüm dosyalar doğru konuma iner
- Pause → resume → kalan segment'ler iner
- Cancel → temp dosyalar silinir
- Retry → 2. denemede başarılı olur

---

## Faz 4 — ffmpeg Birleştirme (TypeScript + Dart)

**Amaç:** Segment dosyalarından tek final dosya üret.

### ffmpeg Stratejisi

`concat demuxer` — yeniden encode yok, hızlı:

```bash
# file_list.txt içeriği:
# file '/tmp/dlx/abc/seg-0.ts'
# file '/tmp/dlx/abc/seg-1.ts'
# ...

ffmpeg -f concat -safe 0 -i file_list.txt -c copy output.mp4
```

Container seçimi:
- Segment'lerde video + audio varsa → `.mp4`
- Sadece audio varsa → `.aac`
- Belirsizse → `.ts` (en güvenli fallback)

### ffmpeg Yolu

```ts
// TypeScript
interface FfmpegConfig {
  path: string;   // 'ffmpeg' veya '/usr/bin/ffmpeg'
}
```

CLI'dan: `process.env.FFMPEG_PATH ?? 'ffmpeg'`
Flutter'dan: ayarlardan veya sistem PATH'inden.

### ffmpeg Yoksa

Segment'leri binary concat yap → `.ts` dosyası üret. Bazı oynatıcılar açar,
kalite/sync sorunları olabilir. UI'da uyarı göster.

### Test
- Gerçek ffmpeg ile 3 segment → tek `.mp4` çıkar
- ffmpeg yoksa binary concat → `.ts` çıkar
- Bozuk segment → hata state

---

## Faz 5 — `execute()` Entegrasyonu + UI (TypeScript + Dart)

**Amaç:** Faz 1'deki stub'ı gerçek `HlsSession` ile değiştir. Flutter UI'da
HLS indirmeleri için özel progress gösterimi.

### `download.ts` / `download.dart` Değişikliği

```ts
if (this._probe.isHls) {
  const session = new HlsSession(this, this.io, this.fetch, this.throttle);
  await session.run(this.url, {
    targetFilename: this.options.filename ?? inferFilename(this.url),
    maxParallelSegments: 4,
  });
  return;
}
// mevcut chunk akışı devam eder
```

### UI Değişiklikleri (`dlx_ui`)

- `transfer_card.dart` — HLS indirmelerinde chunk gösterimi yerine segment
  sayacı göster ("12 / 48 segments")
- `add_download_dialog.dart` — m3u8 URL girildiğinde `filename` alanına
  sayfa title'ı otomatik doldur (extension zaten gönderiyor, dialog'a da
  manuel girilebilmeli)

### Extension Değişikliği

m3u8 URL'lerini artık listeden gizleme — göster ama "HLS" etiketi ekle.
`filename` alanına `pageTitle` gönder.

### Test
- Gerçek m3u8 URL ile uçtan uca test
- Pause/resume çalışır
- İlerleme UI'da görünür
- ffmpeg yoksa `.ts` üretilir, UI uyarır

---

## Dosya Değişiklik Özeti

### TypeScript (`apps/downloadx/src/`)
| Dosya | Değişiklik |
|---|---|
| `types.ts` | `ProbeResult.isHls` |
| `probe.ts` | isHls tespiti |
| `download.ts` | HLS dallanması |
| `hls/types.ts` | **yeni** — HLS veri modelleri |
| `hls/parser.ts` | **yeni** — m3u8 parser |
| `hls/session.ts` | **yeni** — segment indirici + ffmpeg |

### Dart (`apps/downloadx_dart/lib/src/`)
| Dosya | Değişiklik |
|---|---|
| `types.dart` | `ProbeResult.isHls` |
| `probe.dart` | isHls tespiti |
| `download.dart` | HLS dallanması |
| `hls/types.dart` | **yeni** |
| `hls/parser.dart` | **yeni** |
| `hls/session.dart` | **yeni** |

### Flutter UI (`apps/dlx_ui/lib/`)
| Dosya | Değişiklik |
|---|---|
| `services/ws_server.dart` / `download_service.dart` | `filename` + `targetPath` WebSocket'ten oku |
| `ui/add_download_dialog.dart` | `filename` pre-fill |
| `ui/widgets/transfer_card.dart` | HLS segment sayacı |

### Extension (`apps/dlx_extension/src/`)
| Dosya | Değişiklik |
|---|---|
| `background.js` | `add-url` mesajına `filename` ekle |
| `request-watcher.js` | m3u8 listede göster, "HLS" etiketi |
| `popup.js` | HLS etiketi render |

---

## Bağımlılıklar

| Paket | Nerede | Amaç |
|---|---|---|
| ffmpeg (sistem) | runtime | segment birleştirme |
| `process` (Node built-in) | TS CLI | ffmpeg spawn |
| `dart:io Process` | Dart | ffmpeg spawn |

Yeni npm/pub paketi eklenmez.
