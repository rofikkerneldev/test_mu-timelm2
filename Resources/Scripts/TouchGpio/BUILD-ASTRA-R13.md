# Kandidat trial Astra R13 — build 0x20261024, diagnostic schema 2

Kandidat ini mengimplementasikan koreksi review Astra 24 Oktober terhadap baseline cbd97ab3. Tujuannya mendapatkan pengujian host GPIO-I2C dengan identitas paket yang pasti dan catatan kegagalan yang tidak hilang saat rollback. Keberhasilan build/tes tidak membuktikan touch fisik bekerja.

## Perubahan dan batas

| Review | Implementasi kandidat |
|---|---|
| R1 | Query satu Class key dari Enum Driver; wajib cocok INF, service dan hash SYS. Tidak memindai Class tree untuk menentukan selected package. Filter HID vhidmini divalidasi melalui INF filter contract dan service binary, terpisah dari function service inbox |
| R2 | Requested/effective gate wajib exact 1. Host memakai query interface **V4 terpisah**: QueryState membaca gate dan generation provider yang hidup tanpa mengubah pin. Prepare dan start memerlukan gate 1 + generation nonzero yang sama sebelum output power/reset. ABI V2/V3 tetap ada untuk konsumen lama |
| R3 | FirstFailure menyimpan operation, index, value, status dan byte count sebelum cleanup. WriteStatus start tidak ditimpa cleanup. FailOp 1–16 dipertahankan; readiness memakai 17 |
| R4 | Attempt baru di staging, driver epoch, build ID dan validity flag. Field lama diinvalidasi/reset. Runner/analyzer menolak attempt/build/backend/epoch yang hilang atau salah; snapshot entry/exception/final memakai publikasi JSON setelah flush/readback |
| R5 | Connection ID diperlakukan sebagai opaque 64-bit value. Analyzer memeriksa jumlah, ID unik/nonzero dan ordinal; pin fisik ditentukan kontrak SSDT/provider. Query selesai pada stage2, GPIO mode aktif pada stage3, identity pada stage4 |
| R6 | Setiap komponen memiliki commit/tree/input digest/daftar hash source sendiri. Metadata launcher dipisahkan dari driver dan helper. Build CI menolak campuran revisi atau dirty inputs. Paket menyertakan hash semua helper yang dipakai staging |

Kontrak ACPI default launcher dipin ke DSDT 952 B SHA `b759e921e4224158834b5867a456ab988a49d5f900ee90d2b77ed984d9a6c5fe` dan SSDT 451 B SHA `79aab95e716573b511d12538d6d44d6c07361ea9278382a5eaf4b8260b7a3501`. Build trial tidak kembali ke platform DSDT 3369 B ketika env snapshot kosong.

Provider V4 wajib dipasangkan dengan host R13. Host tidak fallback ke provider V3 yang tidak bisa menerbitkan live readiness. Electrical bitbang, physical pin mapping, GENI FIFO/DMA, SMMU, IORT dan algoritme decoding HID tidak diubah oleh koreksi ini. Lifecycle setelah sleep/resume tetap memerlukan pekerjaan terpisah.

## Dua tahap yang dipilih berdasarkan state perangkat

1. **Prepare boot:** bila exact selected host/provider belum cocok paket, staging memasang kedua requested gate=0. Runner memasang GPIO dan host, menaruh client di Driver Store, menyimpan bukti, lalu shutdown. Tahap ini tidak menjalankan hardware touch test. Bila PnP meminta reboot, receipt mencatat `need_next_boot`; state dibaca ulang saat mass storage.
2. **Cold test boot:** setelah raw selected host/provider INF **dan SYS** cocok, staging memasang requested provider/host gate=1 beserta attempt baru dan menginvalidasi snapshot lama. Pada boot, host memverifikasi live V4 provider sebelum power/reset. Runner mengadopsi hasil start tersebut, memvalidasi identity/provenance, dan tidak restart host/provider yang aktif. Client dipasang/diverifikasi lalu jendela tap/swipe 120 detik dibuka hanya jika seluruh prasyarat lolos.

Tidak ada loop restart atau fallback trial otomatis. Kegagalan start direkam lalu trial diakhiri; perbaiki hipotesis berdasarkan first-failure. JSON memakai file `.pending`, WriteThrough + Flush(true), readback/parse, kemudian atomic replacement. Ini memperbaiki publikasi receipt tetapi tidak menjamin semua metadata disk selamat dari setiap power loss. File NUL/terpotong selalu dianggap evidence tidak lengkap.

## Build dan validasi

Workflow `.github/workflows/timelm-astra-touch-trial.yml` membangun launcher di Ubuntu dan provider/host/client ARM64 bertanda tangan test di Windows. Seluruh komponen harus berasal dari commit yang sama. Artefak bundle ada dalam direktori `astra-trial/`; PDB dan source manifests juga diunggah untuk analisis dump.

Tes lokal/CI mencakup production C adapter dan provider dengan ASan/UBSan, electrical core, snapshot ACPI benar/rusak, exact selected vs stale node, hash SYS salah, gate null/0/1/2, attempt/backend/build/epoch salah, first-failure setelah cleanup, atomic JSON dan analyzer evidence tidak lengkap. Full signature trust/load dan operasi sentuh harus dibuktikan pada HP.

Verifikasi paket pada PC:

```powershell
& '<bundle>\Test-TouchGpioPackage.ps1' -Artifact '<bundle>'
```

Untuk tahap staging yang telah diotorisasi secara terpisah, gunakan **helper yang ada di bundle itu sendiri**, agar checkout lain tidak mengganti script runtime:

```powershell
& '<bundle>\Stage-TouchGpioTrial.ps1' -Artifact '<bundle>' -Output '<folder-receipt-PC-baru>' -ReArm
```

Perintah staging adalah instruksi penggunaan, bukan tanda bahwa staging sudah dilakukan. Guard tetap memerlukan USB serial 8509C01F, marker instalasi timelm, geometry disk yang sesuai, original Windows Boot Manager yang cocok hash, serta backup restore-first. Bundle tidak mem-flash partisi boot/platform DSDT. Daftar replacement INF berasal dari ledger yang direview; INF tambahan yang tidak dikenal membuat stage berhenti.

Acceptance fisik: source/artifact/selected binary cocok → provider live ready → identity B3W68TIM → host/client Code0 → IRQ dan HID reports → tap/swipe nyata. Dokumentasi hasil build final di workspace mencatat run CI, SHA commit/zip, dan status staging/hardware secara terpisah.
