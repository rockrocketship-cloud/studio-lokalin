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
- Commit/push `usage.json` hanya ke branch fitur, bukan ke `main` (itu diaktifkan nanti).

Halaman `index.html` membaca `usage.json` secara relatif. Setelah merge ke `main`, GitHub Pages akan menampilkan angka nyata. Jika file tidak ada atau tidak valid, halaman kembali ke mode simulasi.
