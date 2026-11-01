# 02. Архитектура ядра на XT2409-5: где на самом деле живёт политика

## 1. Цепочка загрузки и разделы (слот A)

```
preloader → lk (MBM-3.1) ── AVB: vbmeta_a (+ chain vbmeta_system_a)
   │                          ├─ hash:     boot, init_boot, vendor_boot, dtbo
   │                          └─ hashtree: vendor, vendor_dlkm, system_dlkm, product (+system, system_ext)
   ├─ boot_a        : GKI Image.gz (Google, android14-6.1, 6.1.157)          ← «ядро»
   ├─ init_boot_a   : generic ramdisk (first-stage init)
   ├─ vendor_boot_a : DTB MT6878 + vendor ramdisk (217 .ko, 206 грузятся на 1-м этапе) + recovery ramdisk
   ├─ dtbo_a        : оверлеи платы vienna
   └─ super (LP)    : system/system_ext/product/vendor + vendor_dlkm_a (234 .ko) + system_dlkm_a (GKI .ko)
```

Ключевое следствие: **изменение одного vendor-модуля = изменение `vendor_dlkm_a` + его hashtree-дескриптора в
`vbmeta_a`**. `boot`, `vendor_boot`, `init_boot`, `dtbo` остаются стоковыми.

## 2. Кто принимает решения о частотах и размещении задач

GKI-ядро содержит механизмы (CFS, EAS, schedutil, uclamp, PSI, cpuidle), но MediaTek подменяет почти все
решения через Android vendor hooks. Из исходников `kernel_device_modules-6.1` (подсчитано по `register_trace_android_*`):

| Модуль (vendor_dlkm) | Перехватывает | Что делает |
|---|---|---|
| `scheduler.ko` | `find_energy_efficient_cpu`, `select_task_rq_rt`, `find_lowest_rq`, `check_preempt_wakeup`, `find_busiest_group/queue`, `sched_newidle_balance`, `can_migrate_task`, `cpu_overutilized`, `update_cpu_capacity`, `tick_entry`, … (42 хука; всего по каталогу sched с sugov/core_ctl — 47) | EAS-размещение MTK, VIP-задачи, FLT (fast load tracking), core pause, group-aware, ротация больших задач |
| `cpufreq_sugov_ext.ko` | губернатор `sugov_ext` вместо schedutil | частота по утилизации + adaptive margin, turn-point, DSU-голосование, rate limits, iowait boost |
| `mtk_core_ctl.ko` | — | «парковка» ядер (по умолчанию политика выключена, включается PowerHAL) |
| `moto_sched.ko` (Motorola) | mutex/rwsem/futex/binder хуки | UX/VIP-приоритизация потоков UI при блокировках |
| `task_turbo.ko`, `fpsgo.ko` (проприет.), `mtk_fpsgo.ko`, `frs.ko` | — | буст критичных потоков, покадровое управление частотой |
| `thermal_interface.ko`, `soc_temp_lvts.ko`, cooling-модули | — | термоограничения (не трогаем) |

Поверх этого **userspace** (vendor) задаёт режимы:

* `init.cgroup.rc`: `sugov_ext` на policy0/policy4, `sched_pelt_multiplier=4` (полураспад PELT 8 мс вместо 32),
  загрузочный буст (min 2.0/2.6 ГГц, uclamp.min=100) до `sys.boot_completed`;
* `init.mt6878.rc`: MGLRU, zram lz4, `swappiness=100`, `page-cluster=0`, `watermark_boost_factor=0`,
  read-ahead/`nr_requests`;
* PowerHAL MTK (`powerscntbl.xml`, `powercontable.xml`): сценарии `INTERACTION`, `ACT_SWITCH` и т. д. —
  freq_qos min/max по кластерам, uclamp top-app, DRAM OPP, rate limits `sugov_ext` (0 мкс в интерактиве,
  DefaultValue 10 мкс), FPSGO-параметры.

## 3. Вывод для проекта

1. **Пересобирать GKI-ядро ради «оптимизации планировщика» бессмысленно и рискованно**: решения принимает
   `scheduler.ko`; правка `boot.img` потребовала бы обхода GKI protected exports (`MODULE_SIG_PROTECT=y`),
   пересчёта `KERN_PROT_META` и изменения hash-дескриптора `boot`. Пересборка GKI выполнена только как
   эталон KMI и основа для сборки модулей.
2. **Реальный рычаг ядра — vendor-модули MTK** (исходники точной сборки опубликованы и воспроизведены побайтно).
3. **Наибольшая часть «тюнинга» — userspace-параметры** (PowerHAL, sysctl, cgroup). Их изменение — задача
   userspace (root или изменение vendor), и смешивать её с правками ядра нельзя: эффект станет неатрибутируемым.
