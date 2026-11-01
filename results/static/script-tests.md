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
