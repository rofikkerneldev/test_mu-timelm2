# Pengumpulan log Windows melalui keyboard OTG

Uji terlebih dahulu apakah mouse/keyboard bekerja di Windows. DSDT timelm yang
sekarang berhasil boot belum mendeklarasikan controller USB; input OTG di UEFI
atau Recovery belum membuktikan input OTG akan tersedia setelah Windows berjalan.
Skrip ini disiapkan untuk saat keyboard/CMD sudah dapat dipakai.

Salin `Collect-TimelmDiagnostics.ps1` dan `Collect-TimelmLogs.cmd` dari
Resources/Scripts ke folder `C:\TimelmTools` di ponsel. Belum ada instalasi
otomatis, startup task atau perubahan registry yang ditambahkan.

Pada OOBE, coba Shift+F10 untuk membuka CMD melalui keyboard USB. Setelah masuk
desktop, buka CMD sebagai administrator. Jalankan:

```bat
C:\TimelmTools\Collect-TimelmLogs.cmd
```

Jika Windows memakai huruf selain C:, gunakan `%SystemDrive%` sebagai gantinya.
Hasil disimpan di `%SystemDrive%\TimelmLogs\<waktu-unik>`. Folder ini berada di
partisi `win`, bukan di direktori boot/BCD. Setelah kembali ke Recovery, folder
tersebut dapat diambil melalui ADB dengan mount Windows hanya-baca.
Alternatifnya, ketika ponsel di mode mass storage, salin folder TimelmLogs dari
volume win melalui PC. Huruf E: yang terdeteksi saat ini adalah huruf di PC;
di Windows ponsel gunakan %SystemDrive%. Akses file melalui USB sudah terbukti,
tetapi DISM PC masih gagal membuka image dengan error 87.

Data yang dikumpulkan:

- Mode display aktif dari EnumDisplaySettings, orientasi, refresh rate, serta
  informasi DPI beserta konteks DPI-awareness proses pengumpul.
- Perangkat PnP termasuk USB/HID/ACPI, kode masalah, driver, stack dan resources.
- Paket driver, versi Windows, konfigurasi grafik dan hasil pembacaan BCD.
- Event log System/Application/Kernel-PnP/DriverFrameworks yang sudah tersedia;
  channel yang tidak aktif tidak diaktifkan oleh skrip.
- SetupAPI/Panther dan salinan log clock/UFS dari ESP bila dapat diakses.

Skrip menulis file hasil saja. Ia tidak memasang driver, mengubah DPI/registry,
mereset perangkat atau mengedit BCD. Untuk menyalin log ESP, ia memakai satu
huruf drive kosong sementara, memeriksa jenis ESP dan disk Windows yang sama,
lalu melepas huruf drive tersebut. Tiap kegagalan dicatat tanpa membatalkan
seluruh pengumpulan; statusnya ada di collection-status.json.

Log dapat memuat identitas perangkat, path dan informasi setup. Simpan hasil
di workspace diagnosis pribadi, jangan commit atau unggah ke repo publik.
