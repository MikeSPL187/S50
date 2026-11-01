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
