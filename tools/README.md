# Pencatatan pemakaian Studio Lokalin

## ai-run

Pencatat token nyata untuk halaman Studio Lokalin.

```bash
# Di mesin operator (bukan di GitHub Pages):
export PATH="$HOME/.local/bin:$PATH"
./tools/ai-run.sh codex /path/ke/repo "$caveman Prompt tugas..."
./tools/ai-run.sh claude /path/ke/repo "/caveman Prompt review..."
```

Skript ini menjalankan Codex atau Claude, membaca jumlah token dari keluaran CLI, lalu menambahkan entri ke `usage.json` di repo `studio-lokalin`:

```json
{ "ts": "2026-11-23T04:30:00+08:00", "ai": "ChatGPT", "task": "ringkasan tugas", "input": 0, "output": 0, "total": 10630 }
```

- `ai` hanya `ChatGPT` atau `Claude`.
- Hingga 80 karakter pertama prompt AI tetap masuk ke `usage.json` sebagai label `task` setelah penyensoran pola rahasia. File ini dapat dibaca siapa saja di repo publik.
- File disimpan maksimal 500 entri terakhir.
- Skrip hanya melakukan commit terhadap `usage.json` dan mendorong commit ke branch `main` secara default.
- Atur `AI_RUN_BRANCH` untuk memilih branch tujuan lain.
- Skrip memakai clone sementara dan tidak mengubah checkout operator.
- Skrip melakukan rebase sebelum push. Jika push ditolak karena non-fast-forward, skrip mengulang rebase dan push satu kali. Skrip tidak pernah melakukan force-push.
- Jika pencatatan atau push gagal, skrip menulis peringatan ke stderr dan tetap mengembalikan kode keluar perintah AI.

Halaman `index.html` membaca `usage.json` secara relatif. Setelah setiap run yang berhasil dicatat dan didorong ke `main`, GitHub Pages menerbitkan data penggunaan terbaru. Jika data ChatGPT dan Claude belum tersedia atau tidak valid, halaman menampilkan 0 dan “Belum ada data”.

## set-grokbot-usage

Jalankan dari mesin operator untuk mencatat persentase kuota mingguan GrokBot. Gunakan `~/bin/set-grokbot-usage` jika `~/bin` belum ada di `PATH`.

```bash
set-grokbot-usage 42.5 '2026-11-30T09:00:00+08:00'
set-grokbot-usage 45
set-grokbot-usage 0 null
```

Persentase harus berupa angka dari 0 sampai 100, termasuk desimal dengan tanda titik. Waktu reset memakai tanggal dan jam ISO-8601. Waktu tanpa offset dianggap WITA. Jika argumen reset dihilangkan, waktu reset sebelumnya dipertahankan. Gunakan `null` untuk menghapusnya. Skrip mengisi `updated_at` dengan waktu pembaruan di Asia/Makassar.

Jika `usage.json` berisi array, skrip memindahkan seluruh array ke `entries`. Jika file belum ada, skrip membuat `entries` kosong. Pada format objek, skrip memperbarui `grokbot` dan mempertahankan semua entri serta kunci lainnya. `ai-run` dapat menambahkan entri ke kedua format.

```json
{
  "entries": [],
  "grokbot": {
    "weekly_percent": 42.5,
    "resets_at": "2026-11-30T09:00:00+08:00",
    "updated_at": "2026-11-23T10:00:00+08:00"
  }
}
```

- Skrip memakai clone sementara dan tidak mengubah checkout operator. Skrip hanya melakukan commit terhadap `usage.json`.
- Default repo adalah `~/projects/studio-lokalin` dan default branch tujuan adalah `main`. Gunakan `USAGE_REPO` dan `AI_RUN_BRANCH` untuk menggantinya.
- Skrip memerlukan `timeout`. Skrip melakukan rebase sebelum push dan membuat ulang pembaruan pada file terbaru jika terjadi konflik. Jika push ditolak karena non-fast-forward, skrip mencoba lagi satu kali. Skrip tidak pernah melakukan force-push.
- Jika file berupa symlink, strukturnya tidak didukung, atau push gagal, skrip menulis peringatan ke stderr dan keluar dengan status gagal.
