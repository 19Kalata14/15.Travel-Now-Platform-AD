# Процедура ULD-04 — Втвърдяване на SSH достъпа до srv

Фирма №15 — TravelNow Platform AD

## Заглавна част

| Поле | Стойност |
|---|---|
| Реализира контрол (код) | ULD-04 (политика), Annex A: A.8.5, A.8.2 |
| R-ID | R-01 (достъп до средата), R-05 (атака с пароли) |
| Изпълнява се от (длъжност) | Системен администратор |
| Честота | При първоначална настройка и при всяка промяна на SSH конфигурацията; проверка на всеки 3 месеца |
| Версия | 0.2 |
| Дата | 11.11.2026 |

## Предусловия

- Достъп до `srv` като root (`su -`) в конзолата на VirtualBox.
- Инсталиран `openssh-server` на `srv`.
- Ключ ed25519 на `gw`, качен в `authorized_keys` на потребителя `srv` (`ssh-copy-id`).
- **Снапшот `pre-h06`** на `srv` преди започване (VirtualBox → Machine → Take Snapshot).
- **Конзолата на srv във VirtualBox остава отворена** до края (резервен достъп, ако SSH откаже).
- Терминал на `gw` за отрицателния тест.

## Стъпки

| # | Действие | Команда | Очакван резултат |
|---|---|---|---|
| 0 | Ключ за вход (gw) | `ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519` и `ssh-copy-id srv@10.140.0.10` | `Number of key(s) added: 1` |
| 1 | Запиши „преди“ (srv) | `(date; sshd -T \| grep -E 'rootl\|passworda') \| tee predi.txt` | `permitrootlogin without-password`, `passwordauthentication yes` |
| 2 | Провери, че ключът работи (gw) | `ssh srv@10.140.0.10 true && echo KEY-OK` | `KEY-OK`, без парола |
| 3 | Настройка в отделен файл (srv) | `cd /etc/ssh/sshd_config.d` и `printf '%s no\n' permitrootlogin passwordauthentication kbdinteractiveauthentication > 10-uld04.conf` | Файлът съдържа трите реда „... no“ |
| 4 | Провери синтаксиса | `sshd -t` | Няма изход (OK) |
| 5 | Приложи | `systemctl reload ssh` | Конзолната сесия остава жива |
| 6 | Запиши „след“ от работещата услуга (srv) | `cd; (date; sshd -T \| grep -E 'rootl\|passworda') \| tee sled.txt` | `permitrootlogin no`, `passwordauthentication no` |
| 7 | Отрицателен тест (gw) | `ssh -o PubkeyAuthentication=no srv@10.140.0.10 2>&1 \| tee otkaz.txt` | `srv@10.140.0.10: Permission denied (publickey).` |

## Проверка

- **Положителна:** вход с ключ продължава да работи (стъпка 2 — `KEY-OK`) и конзолната сесия остава жива.
- **Отрицателна:** вход без ключ се отказва → `Permission denied (publickey)` (стъпка 7, `otkaz.txt`).
- **Доказателство от работещата услуга:** `sled.txt` идва от `sshd -T`, не от конфигурационния файл.

## При отклонение

Ако `sshd -t` (стъпка 4) върне грешка — **не** презареждай услугата. Поправи файла `10-uld04.conf` и повтори стъпка 4. Ескалирай до Ръководител ИТ, ако грешката остане, в рамките на 1 час.

## Връщане назад

```
rm /etc/ssh/sshd_config.d/10-uld04.conf && systemctl reload ssh
```
Ако и конзолата е недостъпна — върни снапшота `pre-h06` от VirtualBox.

## Запис (доказателство)

| Файл | Какво съдържа | Къде |
|---|---|---|
| `predi.txt` | SSH стойности преди промяната | artefakti/s06-soa-procedura/ |
| `sled.txt` | SSH стойности след промяната (от работещата услуга) | artefakti/s06-soa-procedura/ |
| `otkaz.txt` | Резултат от отрицателния тест (Permission denied) | artefakti/s06-soa-procedura/ |

Записите се съхраняват 12 месеца в хранилището.

---

**Проверка от съученик:** _________________ , дата _________________
