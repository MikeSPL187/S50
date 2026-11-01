# 01. Аудит исходников и соответствие установленной прошивке

## 1. Найденные исходники (точный тег сборки)

Тег `MMI-W1UI36H.39-25-11-4` («Vienna push for Android 16», 16.10.2026) существует во всех нужных
репозиториях Motorola. Точные коммиты закреплены в [`manifest/sources.lock`](../manifest/sources.lock).

| Репозиторий | Роль | Коммит |
|---|---|---|
| `android.googlesource.com/kernel/common` `android14-6.1-2025-12_r29` | **ядро в boot.img** (GKI) | `14047afecd8b` |
| `MotorolaMobilityLLC/kernel-mtk` | GKI-дерево Motorola (+MTK-правки) = `KERNEL_DIR` для сборки vendor-модулей | `19769679e8a8` |
| `MotorolaMobilityLLC/kernel-kernel_device_modules-6.1` | драйверы MTK, DTS, `scheduler`, `sugov_ext`, `core_ctl`, thermal | `700ad8d4c3ac` |
| `MotorolaMobilityLLC/motorola-kernel-modules` | `moto_sched`, `moto_swap`, `mm_iosched`, драйверы Motorola | `3c95814604e4` |
| `MotorolaMobilityLLC/kernel-build-bazel_mgk_rules` | правила сборки MTK (как собирается конфигурация) | `1f867d45b95c` |
| 12 × `vendor-mediatek-kernel_modules-*` (gpu, mtkcam, connectivity, hbt…; у `udc`, `met_drv_v3` тега нет) | прочие vendor-модули | см. lock-файл |
| `prebuilts/clang/host/linux-x86` `clang-r487747c` | компилятор из баннера ядра | `382db94fa959` |

Не опубликованы (проприетарные MTK): `fpsgo_int`, `sched_int`, `cpufreq_int`, `met_drv_secure_v3`, `msync2_frd_int`,
`hbt_driver` (внутр.). В прошивке им соответствуют, в частности, модули с лицензией `Proprietary`:
`fpsgo.ko`, `msync2_frd.ko`, `scheduler_ext.ko`. Их пересобрать нельзя — и не нужно: проект меняет только модуль,
исходник которого опубликован, и сохраняет все экспортируемые им символы с прежними CRC.

## 2. Как установлено соответствие (не по кодовому имени)

Кодовое имя `vienna` используют разные модели (Edge 50 Neo / Moto S50, Edge 60 Neo), поэтому соответствие
устанавливалось **по бинарникам установленной прошивки**:

1. **Ядро boot.img.** Баннер `Linux version 6.1.157-android14-11-g14047afecd8b-ab16012876` содержит хэш коммита
   AOSP `14047afecd8b` = тег `android14-6.1-2025-12_r29`; коммит-сообщение Motorola в `kernel-mtk`
   прямо ссылается на этот тег и CI-сборку 16012876. Ядро — **официальный GKI Google**, а не дерево `kernel-mtk`.
2. **Пересборка GKI** из этого коммита с IKCONFIG, извлечённым из стокового Image:
   * строка релиза и баннер воспроизведены полностью (включая `#1 SMP PREEMPT Tue Aug 4 11:44:32 UTC 2026`);
   * размер Image совпал до байта: **35 637 760**;
   * границы `_stext/_etext/__init_begin` = `0x10000/0x1040000/0x1BE0000` = ровно `KERN_PROT_META` из vbmeta;
   * конфигурация: отличаются только 5 строк, зависящих от хоста (`CC_CAN_LINK*`, `UAPI_HEADER_TEST`,
     `PAHOLE_VERSION 123→125`, `PAHOLE_HAS_LANG_EXCLUDE`) — они не влияют на образ ядра
     ([config-vs-stock.diff](../results/build/gki/config-vs-stock.diff));
   * побайтно Image **не** идентичен (~24 % байт): пути исходников в строках, ключ подписи модулей, BTF другой
     версии pahole. Для KMI это не имеет значения (см. п. 3), но это значит, что «тот же boot.img» собрать нельзя.
3. **KMI-gate** ([результат](../results/kmi/gki-rebuild-vs-stock-modules.txt)): для каждого из 498 уникальных
   стоковых модулей (`vendor_boot` + `vendor_dlkm` + `system_dlkm`) каждый импортируемый символ найден в
   `Module.symvers` пересборки или в экспортах стоковых модулей **с тем же CRC**: 0 расхождений, 0 неразрешённых.
4. **Vendor-модули.** Конфигурация MTK воспроизведена так же, как в `bazel_mgk_rules/mgk.bzl`
   (`merge_config.sh -m -r gki_defconfig + mgk_64_k61_defconfig + moto-mgk_64_k61.config +
   moto-mgk_64_k61-vienna.config`, `KCONFIG_EXT_PREFIX`, порядок include как в `kdm/Kbuild`).
   Неизменённые исходники дали модули, у которых ([отчёт](../results/repro/module-reproducibility.txt)):
   * все экспортные CRC совпали: `scheduler.ko` 149/149, `cpufreq_sugov_ext.ko` 112/112, `mtk_core_ctl.ko` 21/21;
   * все импорты с CRC совпали: 293/293, 120/120, 108/108;
   * после `llvm-strip --strip-debug` (как в прошивке) файлы совпадают со стоковыми **побайтно во всех секциях,
     кроме `.note.gnu.build-id`** (36 байт; хэш включает пути DWARF машины сборки).

   Это доказывает: опубликованный исходник = код, работающий на телефоне; восстановленная конфигурация верна.

## 3. Различия `kernel-mtk` (Motorola) и AOSP GKI

`git diff android14-6.1-2025-12_r29 MMI-W1UI36H.39-25-11-4` в `kernel-mtk`: 64 файла, +1912/−57 строк
(printk, `kernel/sched/core.c`, `rt.c`, workqueue, UFS, fuse и др.). Практически всё под `CONFIG_MTK_*`, которые в
GKI-конфигурации выключены; из `gki_defconfig` убран `CONFIG_MODULE_SIG_PROTECT=y`. Это дерево служит только
для сборки vendor-модулей; ядро на телефоне собрано из чистого AOSP. Поэтому:

* собирать **ядро** для boot.img нужно из AOSP `common`, а не из `kernel-mtk`;
* собирать **vendor-модули** — против `kernel-mtk` с MTK-конфигурацией (как это делает Motorola).

## 4. Полнота, законность, воспроизводимость

* Ядро и опубликованные модули — GPLv2 (Motorola обязана публиковать; публикация есть). Изменения проекта
  распространяются как патчи + собранный GPL-модуль.
* Образы прошивки (`vendor_dlkm.img`, `vbmeta.img` и т. п.) в репозиторий **не** кладутся: они содержат
  проприетарные модули MTK и материалы Motorola. Скрипты собирают их локально из вашей копии пакета.
* Сборка воспроизводима: закреплённые SHA, официальный компилятор, фиксированные `KBUILD_BUILD_*`,
  проверка SHA при загрузке, контейнер на Ubuntu 24.04.
* Ограничения: Kleaf/Bazel не используется (plain kbuild даёт тот же результат для проверенных модулей);
  проприетарные модули не пересобираются; полный побайтный `boot.img` не воспроизводится (не требуется).
