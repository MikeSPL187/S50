# Офлайн-тесты скриптов устройства (без телефона)

Выполнено 01.11.2026 в облачной среде. `fastboot` заменён имитатором `/tmp/fbstub`, который отвечает на
`devices`/`getvar` значениями XT2409-5 и **отказывает в любой записи** (`STUB REFUSES WRITE`).
Резервная копия собрана из стокового пакета; `EXPECTED.txt` проверен `sha256sum -c` (8/8 OK).

| Тест | Ожидание | Результат |
|---|---|---|
| `bash -n` всех `scripts/device/*.sh`, `scripts/host/*.sh`; `py_compile` `tools/*.py` | без ошибок | OK |
| `30-preflash-gate.sh` с корректным артефактом | все проверки [OK], exit 0 | OK |
| `30-preflash-gate.sh`, vbmeta артефакта подменён стоковым | [СТОП] root digest не совпадает, exit 1 | OK |
| `30-preflash-gate.sh`, `current-slot=b` | [СТОП] current-slot=b | OK |
| `40-flash-…sh`, неверная фраза подтверждения | ОСТАНОВКА, ничего не записано | OK |
| `40-flash-…sh`, верная фраза, запись `vbmeta_a` отклонена | ОСТАНОВКА на шаге 1/3 + инструкция отката, `vendor_dlkm` не тронут | OK |
| `make-vendor-dlkm.sh` без замен («холостой») | 246/246 путей идентичны стоку; VBMETA DIFF OK | OK |
| `make-vendor-dlkm.sh` с patched модулем | отличается только `/lib/modules/cpufreq_sugov_ext.ko`; hashtree валиден; root digest совпадает | OK |
| Разбор `fastboot getvar` для ключей с `:` (`slot-successful:_a`) | значение `yes` | OK |

Не тестировалось (нужен реальный телефон): фактическая запись, fastbootd, поведение загрузчика с vbmeta чужого
ключа, `00`/`10`/`20` с реальным `adb`.

## Повторные тесты после исправлений по рецензии (01.11.2026)

Имитатор `fastboot` с состоянием (режим загрузчик/fastbootd, активный слот, флаги слотов); записывает
последовательность команд, ничего не пишет.

| Сценарий | Ожидание | Фактическая последовательность | Результат |
|---|---|---|---|
| `40`, слот A, загрузка отклонена | vbmeta_a → fastbootd → vendor_dlkm_a → загрузчик, без загрузки системы | `flash vbmeta_a (загрузчик); reboot fastboot; flash vendor_dlkm_a (fastbootd); reboot bootloader` | OK |
| `40`, `slot-successful:_a=no` | остановка до записи | записей нет, «предполётная проверка не пройдена» | OK |
| `90`, `current-slot=b`, без флага | остановка до записи | записей нет | OK |
| `90 --set-active-a`, слот B, ввод `BOOT` | vbmeta_a → set-active a → fastbootd → vendor_dlkm_a → загрузчик → загрузка | `flash vbmeta_a; set-active a; reboot fastboot; flash vendor_dlkm_a; reboot bootloader; REBOOT SYSTEM` | OK |
| `90` из fastbootd, слот A, загрузка отклонена | vendor_dlkm_a → загрузчик → vbmeta_a, без загрузки | `flash vendor_dlkm_a (fastbootd); reboot bootloader; flash vbmeta_a (загрузчик)` | OK |
| `90 --all`, неверная фраза | ничего не записано | записей нет | OK |
| `tools/bootimg_kernel.py` на стоковом `boot.img` | баннер = `EXPECT_PROC_VERSION` в `00-readonly-diagnostics.sh` | совпал | OK |

## Тесты после второй рецензии (01.11.2026)

Имитаторы `adb` (значения свойств задаются) и `fastboot` (с состоянием; `version-bootloader` отдаётся частями
`[0]`/`[1]`, как у Motorola). Ничего не записывается.

| Сценарий | Результат |
|---|---|
| `20 --recheck-only`, все значения стоковые | 9/9 OK, маркер `schema=1` создан |
| `20 --recheck-only`, `ro.carrier=retapac` | НЕ СОВПАДАЕТ, маркера нет, создан `DEVICE-MISMATCH.txt` |
| `20 --recheck-only`, adb недоступен, был старый маркер | ОСТАНОВКА, старый маркер удалён |
| `30`, свежий маркер, всё стоковое | ПРОЙДЕНА |
| `30`, маркер старше 120 мин | СТОП (возраст 180 мин) |
| `30`, `SHA256SUMS` копии изменён после сверки | СТОП (копия изменилась после сверки) |
| `30`, образ на 64 КиБ больше раздела | СТОП (размер; заодно hashtree и root digest) |
| `30`, fastboot `ro.carrier=retapac` | СТОП |
| `30`, `securestate=oem_locked` | СТОП |
| `30`, `securestate` пуст, свежий маркер | ПРОЙДЕНА с информационной строкой |
| `30`, `version-bootloader` другой сборки | СТОП |
| `gvm version-bootloader` из двух частей | склеено в `MBM-3.1-vienna-ddf047-W1UI36H.39-25-11-4-2734cd` |
| `90`, слот A, сборка W1UI36H | vbmeta_a → fastbootd → vendor_dlkm_a → загрузчик, без загрузки |
| `90`, слот A, другая сборка (с `--accept-unverified-build` тоже) | ОСТАНОВКА, записей нет |
| `90`, слот A, сборка не читается: без флага / с флагом | ОСТАНОВКА / восстановление |
| `90 --set-active-a`, слот B, загрузчик V1UI35H или W1UI36H | vbmeta_a → set-active a → fastbootd → vendor_dlkm_a → загрузчик |
| `90 --set-active-a`, слот B с другой сборкой (OTA) | ОСТАНОВКА, записей нет |
| `40`, полный цикл со свежим маркером, загрузка отклонена | vbmeta_a → fastbootd → vendor_dlkm_a → загрузчик |

## Тесты после третьей рецензии (01.11.2026)

Имитатор `fastboot` в режиме fastbootd теперь, как AOSP, не отдаёт `sku`, `cid`, `securestate`, `ro.carrier`,
`slot-retry-count`. Имитатор `adb` для отката воспроизводит работающий Android с заданными свойствами.

| Сценарий | Результат |
|---|---|
| `40`, полный цикл | журнал: `prepared` (с ожидаемым vbmeta.digest эксперимента) → `vbmeta_a_written` → `vendor_dlkm_a_written` |
| `90` запущен из fastbootd, слот A, журнал активен | `reboot bootloader` → проверки → vbmeta_a → fastbootd → vendor_dlkm_a → загрузчик; журнал `restored` |
| `90`, слот A, журнал закрыт, adb нет | ОСТАНОВКА (состояние неизвестно) |
| то же с `--accept-unverified-state` | восстановление |
| `90 --set-active-a`, слот B `successful=yes` (как после OTA), даже с обходом | ОСТАНОВКА, записей нет |
| `90 --set-active-a`, слот B не successful, журнал активен, загрузчик V1UI35H | vbmeta_a → set-active a → fastbootd → vendor_dlkm_a |
| `90`, Android работает, digest эксперимента из журнала | подтверждение → `adb reboot bootloader` → восстановление |
| `90`, Android работает с другой сборкой | ОСТАНОВКА, записей нет |
| `90`, Android работает, digest неизвестен | ОСТАНОВКА, записей нет |
