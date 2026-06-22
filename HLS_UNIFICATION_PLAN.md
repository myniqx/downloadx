# HLS'i Chunk Altyapısına Birleştirme Planı

## Amaç

HLS indirmeleri şu an tamamen ayrı bir kod yolu (`HlsSession`) üzerinden
yürüyor ve `Download`/`Chunk` altyapısının özelliklerinin çoğunu kaybediyor:
resume baştan başlıyor, hız gösterilmiyor, retry/throttle kodu tekrar ediyor.

Hedef: **Her HLS segment'i, mevcut `Chunk` sınıfının `isSegment` modunda
indirilen bir birimi olsun.** Böylece speed tracking, resume, retry, throttle,
event sistemi bedavaya gelir. `HlsSession`'dan geriye sadece **playlist parse +
concat** kalır.

### Akış (hedef)

```
probe → isHls?
         ├─ master playlist  → her kalite ayrı idle Download olarak register, bu download "completed"
         └─ media playlist   → her segment bir isSegment Chunk (offset=0, kendi dosyası)
                               → driveChunks (paralellik = targetChunkCount)
                               → tüm segmentler bitince concat (ffmpeg / binary fallback)
                               → rename → completed
```

### Tasarım kararları (kullanıcı onaylı)

- **Segment = bir Chunk**, her segment **kendi `.ts` dosyasına** yazılır, sonda concat.
- **`isSegment` flag** `Chunk`'a eklenir: offset=0'dan yazar, split edilmez, kendi dosyasına yazar, retry/throttle/speed korunur, meta'ya güncellenir.
- **Resume optimistik**: segment Range ile resume denenir; sunucu 200 dönerse (range yok) o segment baştan iner. Uzunluk biliniyorsa tam resume, bilinmiyorsa baştan — kabul.
- **`targetChunkCount` = paralel inecek segment sayısı** (HLS modunda).
- **ETA** = kalan segment × tamamlanan segmentlerin ortalama indirme süresi.
- **Progress yüzdesi** = tamamlanan segment / toplam segment. **Hız** = gerçek byte'lardan (`aggregate.totalSpeed`).
- **Allocation** (`alloc`) ve **finalize size-mismatch** kontrolü HLS'te atlanır (totalSize=null guard).

### Ek istek (HLS'ten bağımsız)

`DownloadOptions`'a `description?: string` ve `metadata?: Record<string,string>`
eklenir. Bunlar **sadece persist edilir ve `describe()`/sorgularda geri döner**;
başka davranışsal etkileri yoktur. Core'u kullanan uygulamalar (extension, UI)
indirmeye özel not / `sourceLink` / `fromExtension` gibi veriler iliştirebilsin.

---

## Persist denetimi (mevcut durum — kontrol sonuçları)

- ❌ **`isHls` metaya yazılmıyor.** `ProbeResult.isHls` var ama `MetaFile`'da alan yok, `applyProbeToMeta` kopyalamıyor. Şu an resume'da her seferinde yeniden probe edildiği için kazara çalışıyor — kırılgan. **Eklenecek.**
- ❌ **`description`/`metadata` metada yok.** Eklenecek.
- ⚠️ **`ChunkSnapshot` segment'e yetmiyor.** Segment için `targetFilePath` (kendi dosyası), `isSegment`, opsiyonel `durationSec`, `uri` gerekiyor. Snapshot genişletilecek.
- ⚠️ `updateMeta` patch listesinde `minChunkSize`/`journal`/`description`/`metadata` yok — eklenecek (şu an bazıları in-place set ediliyor, tutarlılık için patch'e alınacak).
- ⚠️ `meta.ts` `validate`/`validateChunk` yeni alanları doğrulamalı (geriye dönük uyumlu: eski metalar yeni alansız da yüklenebilmeli).
- ⚠️ `META_SCHEMA_VERSION` artırılmalı mı? Yeni alanlar nullable/opsiyonel olacağı için **artırmadan** geriye dönük uyum sağlanır; eski metalar default değerlerle yüklenir. (Phase 1'de değerlendir.)

---

## TS / Dart strateji

TS (`apps/downloadx`) **referans implementasyon**. Her phase önce TS'te
tamamlanıp testleri geçer, **sonra aynı phase dart'a (`apps/downloadx_dart`)
portlanır.** Paralel değil, çünkü dart birebir port ve TS'teki tasarım
kararları/edge-case'ler önce orada oturmalı. Her phase'in dart portu kendi
alt-görevi olarak işaretlenir.

> İki paket birbirinin portu olduğu için her phase'de: **(a) TS uygula+test, (b) Dart porta+test.** Bir phase ancak her iki taraf da yeşilse "done".

---

## Phase'ler

Her phase tek bir session'da bitirilebilecek boyutta. Tamamlanınca başlığın
yanına `✅ DONE` yazılır.

### Phase 0 — Meta & Options altyapısı (persist temeli) ✅ DONE

> Davranış değişikliği yok; sadece veri modelini HLS birleşmesine ve yeni
> alanlara hazırlar. En güvenli ilk adım.

- [x] `MetaFile`'a `isHls: boolean` ekle (default false).
- [x] `MetaFile`'a `description: string | null` ve `metadata: Record<string,string> | null` ekle.
- [x] `ProbeResult.isHls` → `applyProbeToMeta` içinde meta'ya kopyalansın.
- [x] `DownloadOptions`'a `description?` ve `metadata?` ekle; constructor'da meta'ya yaz.
- [x] `ChunkSnapshot`'ı genişlet: `targetFilePath?`, `isSegment?`, `durationSec?`, `uri?` (hepsi opsiyonel — non-HLS chunk'ları etkilemesin).
- [x] `createEmptyMeta` yeni alanları null/false ile başlatsın.
- [x] `updateMeta` patch listesine `description`/`metadata` (ve eksik `minChunkSize`/`journal`) ekle.
- [x] `meta.ts` `validate`/`validateChunk`: yeni alanları geriye dönük uyumlu doğrula (yoksa default).
- [x] `describe()` / `DownloadDescription`'a `description` ve `metadata` ekle (geri dönsün).
- [x] Schema version artışı gerekmedi: yeni alanlar opsiyonel/nullable, eski metalar default ile yüklenir (legacy load testi ile doğrulandı).
- [x] **TS testleri yeşil.** (148/148)
- [x] **Dart portu + testleri yeşil.** (121/121)

### Phase 1 — `Chunk.isSegment` modu ✅ DONE

> `Chunk`'ı segment indirebilir hale getir. Henüz `Download` tarafı bağlanmaz;
> birim testlerle doğrulanır.

- [x] `ChunkParams`'a `isSegment: boolean` ekle (+ `Chunk.isSegment` getter).
- [x] `writeBytes`: offset zaten `offset + downloadedBytes`; segment'te `offset=0` verileceği için byte 0'dan kendi `targetFilePath`'ine yazar. Ek koda gerek kalmadı.
- [x] `truncateTail` / split: segment chunk'ı asla bölünmez (savunmacı guard `if (isSegment) return null`; Download tarafında `splitAllowed` zaten totalSize=null ile kapalı kalacak).
- [x] Open-ended segment (length bilinmiyor) → `UNKNOWN_SIZE_LENGTH`, EOF'a kadar streamler, sonra completed (mevcut open-ended chunk mantığı).
- [x] Length sabitlemeye gerek kalmadı: completion `status === 'completed'` ile yönetiliyor; resume'da `run()` başındaki `if (status === completed) return` tamamlanmış segmenti atlar.
- [x] Optimistik resume: segment'lere `acceptsRanges=false` verilir (Phase 4'te `buildChunk`'ta); `chunk.ts:243` mantığı `downloadedBytes>0` ise baştan indirir, Range header hiç gönderilmez.
- [x] **Birim testleri (segment indirme, split guard, range-yok, resume) yeşil.** (TS 152/152)
- [x] **Dart portu + testleri yeşil.** (Dart 125/125)

### Phase 2 — `driveChunks` concurrency limiti ✅ DONE

> Segment modunda 1000 segment = 1000 paralel istek olmasın. Paralellik
> `targetChunkCount` ile sınırlansın. Non-HLS davranışı değişmesin.

- [x] `driveChunks`'a aynı anda en fazla N canlı chunk başlatma mantığı (`launchPending`) eklendi. N = segment modunda `targetChunkCount`, non-HLS'te sınırsız (Infinity / `1<<30`).
- [x] `segmentMode = chunks.some(c => c.isSegment)` ile mod tespit edilir; bir runner settle olunca `launchPending` boşalan slotu sıradaki chunk'la doldurur (sürekli akış).
- [x] Non-HLS split/reassign bozulmadı (concurrency=Infinity → tüm chunk'lar baştan launch, mevcut davranış).
- [x] **Önemli düzeltme:** `launchPending` launchable filtresi `completed`/`reassigned`/`failed`/zaten-çalışan hariç herkesi başlatır. İlk versiyonda `status === 'pending'` filtresi resume'daki `paused` chunk'ları atlayınca pause/resume regresyonu + failed chunk relaunch (OOM) çıktı; filtre düzeltildi.
- [x] Non-HLS regresyon yok (tüm mevcut testler yeşil). Segment modunun gerçek eşzamanlılık gözlemi Phase 4'te HLS integration testinde (mock fetch eşzamanlılık sayacı) yapılacak — Phase 2 kodu `runHls` segment planlaması olmadan izole gözlenemez.
- [x] **TS testleri yeşil.** (152/152)
- [x] **Dart portu + testleri yeşil.** (125/125)

### Phase 3 — `HlsSession` sadeleştirme (parse + concat)

> Download/retry/throttle kopyalarını sil; session sadece playlist çözer ve
> concat yapar.

- [ ] `HlsSession`'dan `downloadSegments`/`downloadSegment`/retry/throttle kodunu çıkar.
- [ ] `resolvePlaylist` (master/media ayrımı) ve `registerStreams` (multi-stream) korunur.
- [ ] `concatSegments` korunur (io.concatSegments / binary fallback).
- [ ] Segment listesini `Download`'a verecek bir arayüz (parse sonucu → ChunkSnapshot listesi planı) tanımla.
- [ ] `MAX_PARALLEL_SEGMENTS` sabitini kaldır.
- [ ] **Parser/session birim testleri yeşil.**
- [ ] **Dart portu + testleri yeşil.**

### Phase 4 — `Download.runHls` birleştirme

> Asıl birleştirme. `runHls`, segment'leri isSegment chunk olarak planlayıp
> normal `driveChunks` ile indirir.

- [ ] `runHls`: master ise dallan (child register, completed). Media ise segment'leri `ChunkSnapshot[]` olarak `meta.chunks`'a yaz (`isSegment`, `offset=0`, `uri`, kendi `targetFilePath`, `length=UNKNOWN`).
- [ ] Segment dosyaları `{cachePath}/{id}-hls/seg-N.ts` yoluna; concat sonrası temizlik.
- [ ] `driveChunks`'ı HLS modunda da kullan (concurrency = targetChunkCount).
- [ ] Tüm segmentler completed → `concatSegments` → `rename` → completed.
- [ ] `alloc` ve finalize size-mismatch HLS'te atlansın.
- [ ] Progress: yüzde = segment oranı, hız = aggregate, ETA = kalan segment × ort. segment süresi.
- [ ] Resume: `isHls` metadan okunur, tamamlanmış segment chunk'ları atlanır, kalanlar inilir.
- [ ] Pause/cancel: chunk pause mekanizması üzerinden (HLS spin-wait kodu kaldırılır).
- [ ] `cleanup` (segment dosyaları silme) chunk modeline uyarlanır.
- [ ] **HLS integration testleri (resume dahil) yeşil.**
- [ ] **Dart portu + testleri yeşil.**

### Phase 5 — Temizlik & doğrulama

- [ ] Ölü kod taraması (eski HLS-özel alanlar, `hlsSegmentsDone`/`hlsTotalSegments` hâlâ gerekli mi yoksa generic chunk progress yeterli mi).
- [ ] UI/CLI tarafının yeni alanlardan (`description`, `metadata`, HLS hız/ETA) faydalanıp faydalanmayacağını gözden geçir (kapsam dışı bırakılabilir, not düşülür).
- [ ] Tüm test suite (TS + Dart) yeşil.
- [ ] CHANGELOG güncelle.

---

## Riskler / açık noktalar

- **Schema migration**: yeni meta alanları opsiyonel/nullable tutularak version artışından kaçınılır; eski metalar default ile yüklenir. Phase 0'da kesinleştir.
- **Concat sırası**: segment dosya isimleri sıralı (`seg-000000.ts`) olmalı; chunk id ↔ segment index eşlemesi korunmalı.
- **Master playlist**: segment inmez, child download'lar register edilir; bu dal birleşik akıştan önce ayrılmalı.
- **`isHls` resume**: metadan okununca yeniden probe gereksiz olabilir; yine de finalUrl/etag tazeliği için probe mantığı korunabilir — Phase 4'te karar.
