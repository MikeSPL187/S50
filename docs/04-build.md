# 04. Воспроизводимая сборка

## 1. Что собирается

| Этап | Вход | Выход | Назначение |
|---|---|---|---|
| GKI | AOSP `common` @ `14047afecd8b` + IKCONFIG из стокового `boot.img` | `Image`, `vmlinux.symvers`, `Module.symvers`, GKI-модули | эталон KMI; символы для сборки vendor-модулей (boot.img **не** меняется) |
| MTK-модули (сток) | `kernel-mtk` @ `19769679` + `kdm` @ `700ad8d4` | `scheduler.ko`, `cpufreq_sugov_ext.ko`, `mtk_core_ctl.ko` | доказательство воспроизводимости (= стоку) |
| MTK-модули (patched) | то же + `patches/kernel_device_modules-6.1/*.patch` | `cpufreq_sugov_ext.ko` | экспериментальный модуль |
| Артефакт | стоковые `vendor_dlkm_a.img`, `vbmeta.img` + patched модуль | `vendor_dlkm.img`, `vbmeta.img` | экспериментальная установка (не выполняется автоматически) |

## 2. Steam Deck / SteamOS (рекомендуемый путь — контейнер)

SteamOS 3.5+ содержит `podman`/`distrobox`; корневая ФС SteamOS read-only, поэтому зависимости ставим в контейнер,
а не в систему. Нужно ~15 ГБ свободного места в `/home` и ~1 ч (загрузки ≈4 ГБ, сборка GKI ≈15–30 мин на 4C/8T).

```bash
# 0. один раз: репозиторий проекта
cd ~ && git clone -b ccr-8fd37226-yb83cu https://github.com/MikeSPL187/S50 moto-s50-kernel
cd ~/moto-s50-kernel

# 1. резервная копия стоковых образов из вашего пакета + сверка с телефоном (adb, без root)
bash scripts/device/20-backup-stock.sh

# 2. контейнер сборки
podman build -t s50-kernel -f Containerfile .

# 3. полный конвейер (сборка + все проверки + экспериментальный артефакт)
podman run --rm -it -v "$HOME/moto-kernel:/work:Z" -v "$PWD:/repo:Z" s50-kernel \
    /repo/scripts/host/build-all.sh /work /work/backup-W1UI36H.39-25-11-4
```

Шаг 1 использует `python3` хоста (есть в SteamOS) и не требует установки пакетов.
Если `podman` недоступен: `distrobox create -i ubuntu:24.04 s50 && distrobox enter s50`, затем установить пакеты
из `Containerfile` и запустить `scripts/host/build-all.sh` напрямую.

Результаты: `~/moto-kernel/results/` (KMI, воспроизводимость), `~/moto-kernel/out/artifact/` (образы).
Каждая контрольная точка (KMI-gate, сравнение с бинарниками, сравнение vbmeta, сравнение файлов vendor_dlkm)
прерывает конвейер при ошибке.

## 3. Отдельные шаги

```bash
scripts/host/setup-toolchain.sh ~/moto-kernel                  # clang-r487747c + avbtool/mkbootimg (закреплённые ревизии)
scripts/host/fetch-sources.sh ~/moto-kernel/src                # исходники по sources.lock, проверка SHA, git am патчей
scripts/host/build-gki.sh ~/moto-kernel/src/common ~/moto-kernel/out/gki stock.config
scripts/host/build-mtk-modules.sh <kernel-mtk> <kdm|kdm-patched> <mgk-out> <out> <Module.symvers> <stock-vendor.symvers> -- drivers/misc/mediatek/sched
python3 tools/kmi_check.py --symvers out/gki/Module.symvers --modules <stock .ko dirs> [--candidate-modules dir]
python3 tools/ko_compare.py stock.ko rebuilt.ko
scripts/host/make-vendor-dlkm.sh vendor_dlkm_a.img vbmeta.img out/artifact patched/cpufreq_sugov_ext.ko
scripts/host/analyze-firmware.sh <распакованная-прошивка> out/inventory
```

## 4. Тонкости, найденные при сборке (важно для воспроизводимости)

1. **Строка релиза.** `scripts/setlocalversion` не добавляет `-g<sha>`, если HEAD стоит ровно на теге; CI Google
   собирает коммит до создания тега. `fetch-sources.sh` удаляет ссылки на теги. Нужны также
   `BRANCH=android14-6.1 KMI_GENERATION=11 BUILD_NUMBER=16012876 KBUILD_BUILD_VERSION=1`.
2. **KMI-список для `TRIM_UNUSED_KSYMS`** формируется как в Kleaf: `android/abi_gki_aarch64` + все списки
   filegroup `aarch64_additional_kmi_symbol_lists` (34 файла, 8769 символов) → `abi_symbollist.raw`.
3. **Конфигурация MTK** — `merge_config.sh -m -r` четырёх фрагментов + `KCONFIG_EXT_PREFIX=<kdm>/`.
4. **Порядок include**: `-I<kdm>/include` должен стоять *перед* заголовками ядра (MTK затеняет ряд заголовков
   `linux/soc/mediatek/*`); воспроизведено обёрткой `Kbuild`.
5. **vermagic модулей** стока — `6.1.157-android14-11-gb7fc4b7b6b17` (внутренний коммит Motorola).
   Загрузчик модулей его не сравнивает (при `MODVERSIONS` сравниваются только флаги), но для побайтной
   идентичности `.modinfo` он воспроизведён через `.scmversion`.
6. **Пути `__FILE__`** воспроизведены `-fmacro-prefix-map=…=../kernel_device_modules-6.1/…`; модули очищаются
   `llvm-strip --strip-debug`, как в прошивке.

## 5. Альтернатива: CI

[`ci/github-actions-build.yml`](../ci/github-actions-build.yml) — шаблон GitHub Actions (ручной запуск):
собирает GKI и модули из закреплённых исходников и выкладывает артефакты. Проверки против прошивки в CI не
выполняются (образы прошивки не хранятся в репозитории). Чтобы включить — скопировать в `.github/workflows/`.

## 6. Журнал этой сессии (облачный контейнер, 4 vCPU, 15 ГБ RAM)

* GKI полная сборка (Image + 59 GKI-модулей): 707 с, 0 ошибок; инкрементальная — 61–83 с.
* MTK-модули: ≈1 мин на вариант, 0 предупреждений modpost.
* Логи и отчёты: [`results/`](../results).
