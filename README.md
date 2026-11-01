# Motorola Moto S50 (XT2409-5, vienna) — Performance & Efficiency Kernel

Инженерный проект оптимизации ядра для **конкретного** телефона: Moto S50 5G XT2409-5, MT6878 (Dimensity 7300),
Android 16 **W1UI36H.39-25-11-4** (TELEU, патч 2026-09-01), загрузчик разблокирован, активный слот A.

> **Статус (01.11.2026).** Исходники точной сборки найдены и побайтно сопоставлены с прошивкой; ядро и
> vendor-модули воспроизводимо собираются; реализованы 2 KMI-нейтральных патча `sugov_ext`; подготовлен
> экспериментальный артефакт и безопасная процедура установки/отката. **На телефоне ничего не выполнялось и не
> прошивалось; замеров на устройстве пока нет.** Итог и рекомендации: [docs/07-final-report.md](docs/07-final-report.md).

## Главные выводы

1. Ядро в `boot.img` — официальный Google GKI `android14-6.1-2025-12_r29` (`6.1.157-android14-11-g14047afecd8b-ab16012876`).
2. Политику частот и размещения задач определяют vendor-модули MTK из `vendor_dlkm` (`scheduler.ko`,
   `cpufreq_sugov_ext.ko`, …) через vendor hooks — менять `boot.img` ради «оптимизации планировщика» бессмысленно.
3. Исходники этих модулей для точной сборки опубликованы Motorola; пересборка совпала со стоком побайтно
   (кроме build-id).
4. Стоковая конфигурация уже агрессивно настроена (PELT×4, FPSGO, uclamp-бусты, MGLRU, zram). Без замеров нельзя
   обещать прирост; проект даёт инструменты, чтобы его найти и доказать.

## Структура

| Путь | Содержимое |
|---|---|
| [docs/](docs) | 00 факты/пробелы · 01 аудит исходников · 02 архитектура · 03 решения и патчи · 04 сборка · 05 план испытаний · 06 безопасность и откат · 07 итоговый отчёт |
| [patches/kernel_device_modules-6.1/](patches/kernel_device_modules-6.1) | патчи 0001, 0002 к `cpufreq_sugov_main.c` |
| [artifacts/](artifacts) | собранный `cpufreq_sugov_ext.ko` + SHA256SUMS |
| [manifest/sources.lock](manifest/sources.lock) | точные коммиты всех исходников и тулчейна |
| [scripts/host/](scripts/host) | загрузка исходников/тулчейна, сборка GKI и модулей, упаковка `vendor_dlkm`/vbmeta, анализ прошивки, полный конвейер |
| [scripts/device/](scripts/device) | для Steam Deck: `00` диагностика (read-only) · `10` замеры · `20` резервная копия · `30` предполётная проверка · `40` установка (ручная, с подтверждением) · `90` откат |
| [tools/](tools) | `superimg.py`, `kmi_check.py`, `ko_compare.py`, `ko2symvers.py`, `erofs_meta.py`, `vbmeta_diff.py`, `analyze_profile.py` |
| [results/](results) | журналы и отчёты: инвентаризация прошивки, сборка, KMI, воспроизводимость, checkpatch, проверка артефакта |
| `Containerfile`, [ci/](ci) | среда сборки для SteamOS (podman) и шаблон GitHub Actions |

## Быстрый старт на Steam Deck (ничего не меняет в телефоне)

```bash
git clone -b ccr-8fd37226-yb83cu https://github.com/MikeSPL187/S50 ~/moto-s50-kernel && cd ~/moto-s50-kernel
bash scripts/device/00-readonly-diagnostics.sh      # телефон в Android, отладка USB включена
bash scripts/device/20-backup-stock.sh              # копия стоковых образов + сверка vbmeta.digest
bash scripts/device/10-baseline-profile.sh stock-run1
```

Сборка и проверки: [docs/04-build.md](docs/04-build.md). Установка — только по [docs/06-safety-and-rollback.md](docs/06-safety-and-rollback.md)
и только после вашего отдельного решения.

## Правила проекта

* Не блокировать загрузчик; не менять CID, канал TELEU, GPT, preloader, lk, nvdata, efuse, modem.
* Не отключать термозащиту, защиту батареи и верификацию AVB.
* Каждое изменение — отдельный патч с обоснованием, проверкой и откатом; эффект — только по измерениям.
* Образы прошивки и ключи в репозиторий не добавляются.
