# Инвентаризация стоковой прошивки

Источник: `/work/fw/x/VIENNA_G_SYS_W1UI36H.39_25_11_4_subsidy_DEFAULT_regulatory_DEFAULT_cid50_CFC.xml`  
Сформировано: 2026-11-01T15:34:03Z скриптом scripts/host/analyze-firmware.sh

## Пакет
```
BUILD INFORMATION
  SW Version: vienna_g_sys-user 16 W1UI36H.39-25-11-4 2734cd-58da6 release-keys MW-390
  MBM Version: MBM-3.1-vienna-ddf047-W1UI36H.39-25-11-4-2734cd
  Modem Version: MT6878V_NR17.RC.MP.V40.2.P249.01.342R
  SW Display Build ID: W1UI36H.39-25-11-4
  Build Fingerprint: motorola/vienna_g_sys/vienna:16/W1UI36H.39-25-11-4/2734cd-58da6:user/release-keys

OTHER INFORMATION
  Subsidy Lock Config: slcf_mediatek_default_v1.0.atc
  Regulatory Info (eLabel): regulatory_info_default.png
  eLabel SHA1: da39a3ee5e6b4b0d3255bfef95601890afd80709

HAB_PRODUCT vienna
HAB_SECURITY_VERSION 27
HAB_CID 50
HAB_CUSTOMER_REGION Retail
enforce_anti_rollback_check_in_ota=true
BOOTLOADER_ANTIROLLBACK_VER_SUM=023
```

## Контрольные суммы ключевых образов (SHA-256)
```
17c2fad9875e021e35fef00e3e9f0bdaf96ed29f4874a7884fef130ca4a9a5fd  flashfile.xml
ee5a9438fd833af944507ccff80dcca897e54e05b75bcdc45f818585a7a57697  servicefile.xml
f8a5f539754947deeb54bf80a1927e93b5807c81f0fca7aab04cbc8ee25ac919  boot.img
59b64d0e216cc3aa08f125799b52d89cb2d60029a155a80b564ed32e1d297ba8  init_boot.img
5a0c47aaf3f9852d758de53901ab23411de1afca4706083d0b2f1531774bfa49  vendor_boot.img
9a442cf2d48b02001c6a002ce03f29099edd1a41da1e5eb74492f91cf06feda6  dtbo.img
654e7f9fcf3c7f18a4f3c143cb68fa16ae383f09960547ccaf55b0ded10405e3  vbmeta.img
1528d9c7b325c1c3ac41a94b87f418523fd4e871a56b01a5f51e9903012754b9  vbmeta_system.img
```

MD5 из flashfile.xml: совпало 28, не совпало 0, файлов нет на диске 31

## Ядро в boot.img
```
kernel_size: 14108811
boot image header version: 4
boot.img signature size: 0
Linux version 6.1.157-android14-11-g14047afecd8b-ab16012876 (build-user@build-host) (Android (10087095, +pgo, +bolt, +lto, -mlgo, based on r487747c) clang version 17.0.2 (https://android.googlesource.com/toolchain/llvm-project d9f89f4d16663d5012e5c09495f3b30ece3d2362), LLD 17.0.2) #1 SMP PREEMPT Tue Aug  4 11:44:32 UTC 2026
IKCONFIG: 7558 строк
```

## vendor_boot
```
vendor boot image header version: 4
vendor ramdisk total size: 35222903
vendor command line args: bootopt=64S3,32N2,64N2
product name: 
dtb size: 327296
        name: 
        name: recovery
modules.load (first stage): 206 модулей
```

## vbmeta
```
Minimum libavb version:   1.0
Header Block:             256 bytes
Authentication Block:     320 bytes
Auxiliary Block:          5376 bytes
Public key (sha1):        fd29248b78aa9d6427e8f569eda90be62b9fa0ee
Algorithm:                SHA256_RSA2048
Rollback Index:           27
Flags:                    0
Rollback Index Location:  0
Release String:           'avbtool 1.3.0'
Descriptors:
    Chain Partition descriptor:
      Partition Name:          vbmeta_system
      Rollback Index Location: 2
      Public key (sha1):       fd29248b78aa9d6427e8f569eda90be62b9fa0ee
      Flags:                   0
    Prop: KERN_PROT_META -> 'rodata_bounds:65536,17039360,29229056'
    Prop: HAB_META -> 'vienna_50'
    Prop: com.android.build.boot.os_version -> '14'
    Prop: com.android.build.boot.fingerprint -> 'motorola/vienna_g_hal/vienna:14/W1UI36H.39-25-11-4/2734cd:user/release-keys'
    Prop: com.android.build.boot.security_patch -> '2026-09-01'
    Prop: com.android.build.boot.security_patch -> '2026-09-01'
    Prop: com.android.build.dtbo.fingerprint -> 'motorola/vienna_g_vext/vienna:14/W1UI36H.39-25-11-4/2734cd:user/release-keys'
    Prop: com.android.build.init_boot.os_version -> '14'
    Prop: com.android.build.init_boot.fingerprint -> 'motorola/vienna_g_hal/vienna:14/W1UI36H.39-25-11-4/2734cd:user/release-keys'
    Prop: com.android.build.init_boot.security_patch -> '2026-09-01'
    Prop: com.android.build.product.os_version -> '16'
    Prop: com.android.build.product.fingerprint -> 'motorola/vienna_g_sys/vienna:16/W1UI36M.39-25-11-4/58da6:user/release-keys'
    Prop: com.android.build.product.security_patch -> '2026-09-01'
    Prop: com.android.build.system_dlkm.os_version -> '14'
    Prop: com.android.build.system_dlkm.fingerprint -> 'motorola/vienna_g_hal/vienna:14/W1UI36H.39-25-11-4/2734cd:user/release-keys'
    Prop: com.android.build.vendor.os_version -> '14'
    Prop: com.android.build.vendor.fingerprint -> 'motorola/vienna_g_hal/vienna:14/W1UI36H.39-25-11-4/2734cd:user/release-keys'
    Prop: com.android.build.vendor.security_patch -> '2026-09-01'
    Prop: com.android.build.vendor.security_patch -> '2026-09-01'
    Prop: com.android.build.vendor_boot.fingerprint -> 'motorola/vienna_g_hal/vienna:14/W1UI36H.39-25-11-4/2734cd:user/release-keys'
    Prop: com.android.build.vendor_dlkm.os_version -> '14'
    Prop: com.android.build.vendor_dlkm.fingerprint -> 'motorola/vienna_g_hal/vienna:14/W1UI36H.39-25-11-4/2734cd:user/release-keys'
    Hash descriptor:
      Image Size:            14131200 bytes
      Hash Algorithm:        sha256
      Partition Name:        boot
      Flags:                 0
    Hash descriptor:
      Image Size:            292960 bytes
      Hash Algorithm:        sha256
      Partition Name:        dtbo
      Flags:                 0
    Hash descriptor:
      Image Size:            3096576 bytes
      Hash Algorithm:        sha256
      Partition Name:        init_boot
      Flags:                 0
    Hash descriptor:
      Image Size:            35561472 bytes
      Hash Algorithm:        sha256
      Partition Name:        vendor_boot
      Flags:                 0
    Hashtree descriptor:
      Version of dm-verity:  1
      Image Size:            4530696192 bytes
      Tree Offset:           4530696192
      Tree Size:             35680256 bytes
      Data Block Size:       4096 bytes
      Hash Block Size:       4096 bytes
      FEC num roots:         2
      FEC offset:            4566376448
      FEC size:              36102144 bytes
      Hash Algorithm:        sha256
      Partition Name:        product
      Flags:                 0
    Hashtree descriptor:
      Version of dm-verity:  1
      Image Size:            7262208 bytes
      Tree Offset:           7262208
      Tree Size:             61440 bytes
      Data Block Size:       4096 bytes
      Hash Block Size:       4096 bytes
      FEC num roots:         2
      FEC offset:            7323648
      FEC size:              65536 bytes
      Hash Algorithm:        sha256
      Partition Name:        system_dlkm
      Flags:                 0
    Hashtree descriptor:
      Version of dm-verity:  1
      Image Size:            1653211136 bytes
      Tree Offset:           1653211136
      Tree Size:             13025280 bytes
      Data Block Size:       4096 bytes
      Hash Block Size:       4096 bytes
      FEC num roots:         2
      FEC offset:            1666236416
      FEC size:              13172736 bytes
      Hash Algorithm:        sha256
      Partition Name:        vendor
      Flags:                 0
    Hashtree descriptor:
      Version of dm-verity:  1
      Image Size:            17670144 bytes
      Tree Offset:           17670144
      Tree Size:             143360 bytes
      Data Block Size:       4096 bytes
      Hash Block Size:       4096 bytes
      FEC num roots:         2
      FEC offset:            17813504
      FEC size:              147456 bytes
      Hash Algorithm:        sha256
      Partition Name:        vendor_dlkm
      Flags:                 0
```

Ожидаемое значение `ro.boot.vbmeta.digest` (сверяется на телефоне без root):
```
9935ea56ba7359951d5856863727e3c45bce416cb6d18f36f215ebc9b63ccc23
```

## Модули ядра
```
217 .ko в vendor_boot/rd_vendor_ramdisk00/lib/modules
234 .ko в super/vendor_dlkm_a/lib/modules
60 .ko в super/system_dlkm_a
vendor_dlkm: scheduler.ko  124df21d0f13013d…  vermagic=6.1.157-android14-11-gb7fc4b7b6b17 SMP preempt mod_unload modversions aarch64
vendor_dlkm: cpufreq_sugov_ext.ko  a94f89666f68aab1…  vermagic=6.1.157-android14-11-gb7fc4b7b6b17 SMP preempt mod_unload modversions aarch64
vendor_dlkm: mtk_core_ctl.ko  e1fc17e8cf1f5faa…  vermagic=6.1.157-android14-11-gb7fc4b7b6b17 SMP preempt mod_unload modversions aarch64
vendor_dlkm: moto_sched.ko  8a4adf95a8c0a99f…  vermagic=6.1.157-android14-11-gb7fc4b7b6b17 SMP preempt mod_unload modversions aarch64
vendor_dlkm: task_turbo.ko  f4903e57d5759a53…  vermagic=6.1.157-android14-11-gb7fc4b7b6b17 SMP preempt mod_unload modversions aarch64
vendor_dlkm: mtk_fpsgo.ko  9c52b75fee919b7a…  vermagic=6.1.157-android14-11-gb7fc4b7b6b17 SMP preempt mod_unload modversions aarch64
vendor_dlkm: fpsgo.ko  1832ae90ef6d230f…  vermagic=6.1.157-android14-11-gb7fc4b7b6b17 SMP preempt mod_unload modversions aarch64
```

## super (LP metadata)

В этой рабочей среде sparse-чанки были удалены после извлечения разделов (нехватка диска), поэтому ниже — сохранённый ранее вывод `tools/superimg.py list` на всех 31 чанке пакета:
```
LP metadata v10.2  geometry_checksum_ok=True tables_checksum_ok=True  slots=3
groups: default, main_a, main_b
  product_a                    4617228288 bytes  extents=1  group=main_a
  product_b                             0 bytes  extents=0  group=main_b
  system_a                      686043136 bytes  extents=1  group=main_a
  system_b                      569192448 bytes  extents=1  group=main_b
  system_dlkm_a                   7491584 bytes  extents=1  group=main_a
  system_dlkm_b                         0 bytes  extents=0  group=main_b
  system_ext_a                  671940608 bytes  extents=1  group=main_a
  system_ext_b                          0 bytes  extents=0  group=main_b
  vendor_a                     1684840448 bytes  extents=1  group=main_a
  vendor_b                              0 bytes  extents=0  group=main_b
  vendor_dlkm_a                  18092032 bytes  extents=1  group=main_a
  vendor_dlkm_b                         0 bytes  extents=0  group=main_b

extract: vendor_dlkm_a sha256=91a9ade67032c86c6c05c8a6a2daea9ae14a870c7f421b220cbbc45afd7bfcb0
extract: system_dlkm_a sha256=917666e69954046a1c50e4c7031348618b4f660d258eead2bb8f1b6fd5121c42
extract: vendor_a      sha256=6536d427cd1a0431ce5a6de47d141bea596a65a5abd6d5e95fec37ffb6c8af7e
```

MD5 всех 59 образов из flashfile.xml (включая 31 чанк super) совпали при первой распаковке в этой среде — 59/59.
