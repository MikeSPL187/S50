# 00. Факты, предположения и недостающие данные

Документ пользователя `Motorola_S50_XT2409-5_Claude_Full_Context_2026-11-01.md` прочитан полностью
(1361 строка, 109 685 байт, включая приложения A–F: оба XML, оба сгенерированных сценария,
guarded runner и полный журнал прошивки от 30.10.2026).

Обозначения степени достоверности:

* **[Устройство]** — получено с телефона пользователя (ADB/Fastboot/фото) и приведено в документе.
* **[Пакет]** — проверено мной на побайтно том же пакете прошивки, который был установлен
  (SHA-256 архива `6bc78abc…f6a3` совпал с эталоном пользователя; MD5 59/59).
* **[Исходники]** — проверено чтением/сборкой опубликованных исходников Motorola/AOSP.
* **[Сторонний источник]** — утверждение третьих лиц, не проверено на XT2409-5.
* **[Гипотеза]** — инженерное предположение, требующее проверки.

## 1. Подтверждённые факты

| Факт | Источник |
|---|---|
| SKU `XT2409-5`, `product=vienna`, аппаратный CID `0x000B` (11) | [Устройство] fastboot |
| Загрузчик разблокирован: `ro.boot.flash.locked=0`, `vbmeta.device_state=unlocked`, `verifiedbootstate=orange` | [Устройство] |
| Канал `teleu` (`ro.carrier`, `fastboot getvar ro.carrier`) | [Устройство] |
| Установлена сборка `W1UI36H.39-25-11-4`, Android 16, патч 2026-09-01; система загрузилась | [Устройство] фото OTA |
| После прошивки активен слот A (`slot-retry-count:_a=7`, `slot-unbootable:_a=no`) | [Устройство] журнал |
| `efuseBackup` **не** записан (загрузчик пропустил), `nvdata` стёрт | [Устройство] журнал |
| Пакет: `vienna_g_sys-user 16 W1UI36H.39-25-11-4 2734cd-58da6`, `cid_value=0x0032` (50), HAB_SECURITY_VERSION 27 | [Пакет] |
| **Ядро в `boot.img`: `6.1.157-android14-11-g14047afecd8b-ab16012876`**, Clang 17.0.2 (r487747c), `#1 SMP PREEMPT Tue Aug 4 11:44:32 UTC 2026` | [Пакет] |
| Коммит `14047afecd8b` = тег AOSP **`android14-6.1-2025-12_r29`** (GKI, KMI generation 11), сборка Google CI `16012876` | [Пакет]+[Исходники] |
| `boot.img` — header v4, только ядро (gzip Image 35 637 760 байт), без GKI-подписи (`signature size: 0`) | [Пакет] |
| Встроенный IKCONFIG (7558 строк): `MODVERSIONS=y`, `MODULE_SIG_PROTECT=y`, `TRIM_UNUSED_KSYMS=y`, `HZ=250`, `PREEMPT=y`, `UCLAMP_TASK(_GROUP)=y`, `PSI=y`, `LRU_GEN=y`, `ZRAM=m` | [Пакет] |
| SoC `MT6878` (Dimensity 7300): DTB `model = "MT6878"`, 4 ядра `capacity-dmips-mhz=267` + 4 ядра `1024` | [Пакет] DTB |
| `vbmeta` (RSA2048, rollback index 27, flags 0): hash-дескрипторы `boot`, `dtbo`, `init_boot`, `vendor_boot`; hashtree `vendor`, `vendor_dlkm`, `system_dlkm`, `product`; цепочка `vbmeta_system` (`system`, `system_ext`) | [Пакет] avbtool |
| Свойство vbmeta `KERN_PROT_META = rodata_bounds:65536,17039360,29229056` = смещения `_stext`, `_etext`, `__init_begin` от `_text` | [Пакет]+[Исходники]: моя пересборка дала ровно эти значения |
| Ожидаемый `ro.boot.vbmeta.digest` = `9935ea56ba7359951d5856863727e3c45bce416cb6d18f36f215ebc9b63ccc23` | [Пакет] avbtool |
| `super`: LP metadata v10.2, 3 слота метаданных; `vendor_dlkm_a` 18 092 032 байт, `system_dlkm_a` 7 491 584 байт (EROFS) | [Пакет] superimg.py |
| Модули: 217 в `vendor_boot` (206 в first-stage `modules.load`), 234 в `vendor_dlkm`, 60 в `system_dlkm` | [Пакет] |
| Политика CPU (`scheduler.ko`, `cpufreq_sugov_ext.ko`, `mtk_core_ctl.ko`, `task_turbo.ko`, `moto_sched.ko`, `fpsgo`) загружается из **`vendor_dlkm`** | [Пакет] modules.load |
| Исходники **точной** сборки опубликованы Motorola: тег `MMI-W1UI36H.39-25-11-4` в `kernel-mtk`, `kernel-kernel_device_modules-6.1`, `motorola-kernel-modules`, `kernel-build-bazel_mgk_rules`, 12 репозиториях `vendor-mediatek-kernel_modules-*` (кроме `udc` и `met_drv_v3`) | [Исходники] git ls-remote |
| Пересобранный из `kernel_device_modules-6.1` код `scheduler.ko`, `cpufreq_sugov_ext.ko`, `mtk_core_ctl.ko` **побайтно идентичен** стоковому (отличается только `.note.gnu.build-id`) | [Исходники]+[Пакет] |
| Пересобранное GKI-ядро KMI-совместимо со всеми 498 стоковыми модулями: 0 расхождений CRC, 0 неразрешённых символов | [Исходники]+[Пакет] |
| Штатные настройки userspace: `sugov_ext` на обоих кластерах, `sched_pelt_multiplier=4`, MGLRU вкл., zram lz4 `zramsize=100%` (fstab.enableswap) / 75 % (fstab.enablezram), `swappiness=100`, `page-cluster=0`, `watermark_boost_factor=0`, BFQ на `sdc`, PowerHAL держит `up/down_rate_limit_us` на 0–10 мкс | [Пакет] vendor rc / PowerHAL XML |

## 2. Сторонние утверждения (не проверены на XT2409-5)

Проект [VD171/vienna-kernel-build](https://github.com/VD171/vienna-kernel-build) описывает **другую**
модель (Edge 60 Neo XT2509-1, другая сборка). Использован только как справочник; его образы не применялись.

| Утверждение | Статус для XT2409-5 |
|---|---|
| `fastboot boot` отсутствует в загрузчике vienna | не проверено; наш план его не использует |
| `fastboot flash boot` сверяется с hash-дескриптором `boot` в vbmeta на устройстве | не проверено; наш план не меняет `boot` |
| GKI protected exports ломают Wi-Fi при собственном ядре | согласуется с `MODULE_SIG_PROTECT=y` в стоковом конфиге; наш план не меняет ядро |

## 3. Гипотезы (требуют проверки на телефоне)

1. Значения `up/down_rate_limit_us` на работающем телефоне — 10 мкс (DefaultValue PowerHAL) или задержка драйвера
   `mediatek-cpufreq-hw`. От этого зависит, проявится ли патч 0001 (см. 03-optimizations.md).
2. Motorola fastbootd разрешает `fastboot flash vendor_dlkm_a` на разблокированном XT2409-5 (стандартное поведение
   Android 10+, но не проверено).
3. Загрузчик принимает vbmeta, подписанный не ключом OEM, в состоянии unlocked/orange (стандарт libavb; сторонний отчёт для
   Edge 60 Neo это подтверждает).
4. `fastboot oem config cmdl` (виден в flashfile.xml как `unset`) позволяет передавать параметры модулей через cmdline —
   не проверено, не используется.

## 4. Чего не хватает (и как получить)

| Нужно | Зачем | Как получить (без root) |
|---|---|---|
| `uname -r`, `ro.boot.vbmeta.digest` с телефона | доказать, что на телефоне именно анализированные образы | `scripts/device/00-readonly-diagnostics.sh` |
| Текущие `sugov_ext/*rate_limit_us`, таблицы частот, cpuidle, zram, PSI, термозоны | базовая линия и оценка эффекта патчей | тот же скрипт |
| Объём RAM/UFS этого экземпляра | конфигурация модели не определена (12 ГБ по каталогу Lenovo) | `/proc/meminfo` в диагностике; `fastboot getvar all` (ram/ufs) |
| Базовые замеры UX/энергии/температуры | без них нельзя утверждать улучшение | `scripts/device/10-baseline-profile.sh` |
| Проверка SIM/модема/Wi-Fi/BT/камер после стирания `nvdata` | независимо от ядра: известный риск прошлой прошивки | ручная проверка (см. 05-profiling-and-test-plan.md, раздел «Аппаратные функции») |
| Root | runtime-переключение экспериментов, полные трассы | не требуется для базовой работы; не устанавливается этим проектом |
