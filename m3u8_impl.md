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

## ✅ Faz 0 — WebSocket `add-url` mesajına `filename` ve `targetPath` ekle

> **Durum: DONE**
> - TS `DownloadOptions` zaten tam, değişiklik gerekmedi.
> - Dart `DownloadOptions` zaten tam, değişiklik gerekmedi.
> - **YAPILMADI:** `_onWsMessage` add-url case'i hâlâ sadece `url` okuyor —
>   `filename` ve `targetPath` geçirilmiyor.
> - **YAPILMADI:** Extension `background.js` `add-url` mesajına `filename`
>   (pageTitle) eklemiyor.

**Kalan iş (bir sonraki session'da ilk yapılacak):**

`download_service.dart` — `_onWsMessage`:
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

`background.js`:
```js
sendWs({ action: 'add-url', url: msg.url, filename: msg.filename });
```

---

## ✅ Faz 1 — m3u8 Tespiti (TypeScript + Dart)

> **Durum: DONE**
> - TS: `types.ts` → `ProbeResult.isHls`, `probe.ts` → tespit, `download.ts`
>   → stub hata ("HLS downloads are not yet supported").
> - Dart: `types.dart`, `probe.dart`, `download.dart` — aynı şekilde implemente
>   edildi.

---

## ✅ Faz 2 — m3u8 Parser (TypeScript + Dart)

> **Durum: DONE**
> - TS: `hls/types.ts`, `hls/parser.ts` oluşturuldu. `parser.test.ts` yazıldı.
> - Dart: `hls/types.dart`, `hls/parser.dart` oluşturuldu. `parser_test.dart`
>   yazıldı.

---

## 🔄 Faz 3 — HLS Segment İndirici (TypeScript + Dart)

> **Durum: PARTIAL**
> - TS: `hls/session.ts` oluşturuldu. `session.test.ts` yazıldı.
> - Dart: `hls/session.dart` oluşturuldu. `session_test.dart` yazıldı ve
>   hataları düzeltildi (`fetcher.calls` → `fetcher.requests`, named record
>   wildcard pattern düzeltmeleri).
> - **YAPILMADI:** Testler henüz çalıştırılıp geçtiği doğrulanmadı.
> - **YAPILMADI:** `execute()` entegrasyonu yok — Faz 5'te yapılacak.

**Kontrol listesi:**
- [ ] `dart test test/unit/hls/session_test.dart` geçmeli
- [ ] `npx vitest run tests/unit/hls/session.test.ts` geçmeli

---

## ⬜ Faz 4 — ffmpeg Birleştirme (TypeScript + Dart)

> **Durum: YAPILMADI**

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

CLI'dan: `process.env.FFMPEG_PATH ?? 'ffmpeg'`
Flutter'dan: ayarlardan veya sistem PATH'inden.

### ffmpeg Yoksa

Segment'leri binary concat yap → `.ts` dosyası üret. Bazı oynatıcılar açar,
kalite/sync sorunları olabilir. UI'da uyarı göster.

### Dosya Konumu

```
apps/downloadx/src/hls/ffmpeg.ts       # spawn + concat logic
apps/downloadx_dart/lib/src/hls/ffmpeg.dart
```

### Test

- Gerçek ffmpeg ile 3 segment → tek `.mp4` çıkar
- ffmpeg yoksa binary concat → `.ts` çıkar
- Bozuk segment → hata state

---

## ⬜ Faz 5 — `execute()` Entegrasyonu + UI (TypeScript + Dart)

> **Durum: YAPILMADI**

**Amaç:** Faz 1'deki stub'ı gerçek `HlsSession` + Faz 4 ffmpeg ile değiştir.
Flutter UI'da HLS indirmeleri için özel progress gösterimi.

### Önce tamamlanması gerekenler

- Faz 3 testleri geçmeli
- Faz 4 tamamlanmış olmalı

### Çoklu Kalite (Multi-stream) Stratejisi

Master playlist'te birden fazla stream varsa engine kullanıcıya sormaz,
beklemez. Her stream için ayrı `Download` nesnesi oluşturur, hepsini
`autoStart: false` ile listeye ekler. Kullanıcı istediğini listeden başlatır.

**İsim üretimi** (`options.filename` base alınır):

```
resolution varsa  → "film 1920x1080.mkv"
sadece bitrate    → "film 5000kbps.mkv"
ikisi de yoksa    → "film stream-1.mkv", "film stream-2.mkv"
```

Resolution yoksa bitrate fallback, o da yoksa sıra numarası.

**Core akışı:**

```ts
// HlsSession.run() içinde, master parse sonrası
if (streams.length === 1) {
  // tek stream → direkt media playlist'e geç, normal indir
  await this.downloadMediaPlaylist(streams[0].uri);
} else {
  // çoklu stream → her biri için ayrı Download ekle, hiçbirini başlatma
  for (const stream of streams) {
    const name = buildStreamFilename(baseFilename, stream);
    await manager.addUrl(stream.uri, { filename: name }, autoStart: false);
  }
  // bu Download'ı iptal et — işi bitti
  this.cancel();
}
```

Dart tarafı aynı mantık.

**`buildStreamFilename` fonksiyonu** (`hls/session.ts` + `hls/session.dart`):

```ts
function buildStreamFilename(base: string, stream: HlsStream): string {
  const ext = extname(base) || '.mkv';
  const stem = basename(base, ext);
  const qualifier = stream.resolution
    ?? (stream.bandwidth ? `${Math.round(stream.bandwidth / 1000)}kbps` : null);
  const suffix = qualifier ?? `stream-${index + 1}`;
  return `${stem} ${suffix}${ext}`;
}
```

### `download.ts` / `download.dart` Değişikliği

```ts
if (this._probe.isHls) {
  const session = new HlsSession(this, this.io, this.fetch, this.throttle, this.manager);
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
  sayfa title'ı otomatik doldur
- Çoklu kalite durumunda liste ekranında `idle` indirmeler gruplanmış
  görünebilir (aynı base isim) — zorunlu değil, iyileştirme olarak

### Extension Değişikliği

m3u8 URL'lerini artık listeden gizleme — göster ama "HLS" etiketi ekle.
`filename` alanına `pageTitle` gönder.

### Test

- Tek stream m3u8 → direkt indir, bir Download oluşur
- Çoklu stream m3u8 → N adet `idle` Download oluşur, hiçbiri başlamaz
- İsimler resolution/bitrate içerir
- Pause/resume çalışır
- İlerleme UI'da görünür
- ffmpeg yoksa `.ts` üretilir, UI uyarır

---

## Dosya Değişiklik Özeti

### TypeScript (`apps/downloadx/src/`)

| Dosya            | Değişiklik                           | Durum |
| ---------------- | ------------------------------------ | ----- |
| `types.ts`       | `ProbeResult.isHls`                  | ✅    |
| `probe.ts`       | isHls tespiti                        | ✅    |
| `download.ts`    | HLS dallanması (stub → gerçek)       | 🔄 stub |
| `hls/types.ts`   | HLS veri modelleri                   | ✅    |
| `hls/parser.ts`  | m3u8 parser                          | ✅    |
| `hls/session.ts` | segment indirici                     | 🔄 test bekliyor |
| `hls/ffmpeg.ts`  | ffmpeg birleştirme                   | ⬜    |

### Dart (`apps/downloadx_dart/lib/src/`)

| Dosya              | Değişiklik                     | Durum |
| ------------------ | ------------------------------ | ----- |
| `types.dart`       | `ProbeResult.isHls`            | ✅    |
| `probe.dart`       | isHls tespiti                  | ✅    |
| `download.dart`    | HLS dallanması (stub → gerçek) | 🔄 stub |
| `hls/types.dart`   | HLS veri modelleri             | ✅    |
| `hls/parser.dart`  | m3u8 parser                    | ✅    |
| `hls/session.dart` | segment indirici               | 🔄 test bekliyor |
| `hls/ffmpeg.dart`  | ffmpeg birleştirme             | ⬜    |

### Flutter UI (`apps/dlx_ui/lib/`)

| Dosya                          | Değişiklik                                  | Durum |
| ------------------------------ | ------------------------------------------- | ----- |
| `services/download_service.dart` | `filename` + `targetPath` WebSocket'ten oku | ⬜    |
| `ui/add_download_dialog.dart`  | `filename` pre-fill                         | ⬜    |
| `ui/widgets/transfer_card.dart` | HLS segment sayacı                         | ⬜    |

### Extension (`apps/dlx_extension/src/`)

| Dosya                | Değişiklik                         | Durum |
| -------------------- | ---------------------------------- | ----- |
| `background.js`      | `add-url` mesajına `filename` ekle | ⬜    |
| `request-watcher.js` | m3u8 listede göster, "HLS" etiketi | ⬜    |
| `popup.js`           | HLS etiketi render                 | ⬜    |

---

## Bağımlılıklar

| Paket                     | Nerede  | Amaç                |
| ------------------------- | ------- | ------------------- |
| ffmpeg (sistem)           | runtime | segment birleştirme |
| `process` (Node built-in) | TS CLI  | ffmpeg spawn        |
| `dart:io Process`         | Dart    | ffmpeg spawn        |

Yeni npm/pub paketi eklenmez.
