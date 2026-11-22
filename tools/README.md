# tools/ai-run.sh

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
- Label `task` dipotong 80 karakter dan disensor bila ada token/rahasia.
- File disimpan maksimal 500 entri terakhir.
- Skrip hanya melakukan commit terhadap `usage.json` dan mendorong commit ke branch `main` secara default.
- Atur `AI_RUN_BRANCH` untuk memilih branch tujuan lain.
- Skrip memakai clone sementara dan tidak mengubah checkout operator.
- Skrip melakukan rebase sebelum push. Jika push ditolak karena non-fast-forward, skrip mengulang rebase dan push satu kali. Skrip tidak pernah melakukan force-push.
- Jika pencatatan atau push gagal, skrip menulis peringatan ke stderr dan tetap mengembalikan kode keluar perintah AI.

Halaman `index.html` membaca `usage.json` secara relatif. Setelah setiap run yang berhasil dicatat dan didorong ke `main`, GitHub Pages menerbitkan data penggunaan terbaru. Jika file tidak ada atau tidak valid, halaman kembali ke mode simulasi.
