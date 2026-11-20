# edaphia — установщик

Установка edaphia на чистый сервер Ubuntu или Debian одной командой:

```bash
curl -fsSL https://raw.githubusercontent.com/zqpmv/edaphia_install/main/install-edaphia.sh | sudo bash
```

Здесь только скрипт установки. Код edaphia — в закрытом репозитории: скрипт
спросит токен только на чтение (GitHub → Settings → Developer settings →
Fine-grained tokens → доступ к репозиторию edaphia, Contents: Read-only).
Токен не сохраняется.

Что делает скрипт:

1. проверяет систему (root, Ubuntu/Debian, x86_64/aarch64, память и диск);
2. ставит недостающее: git, curl, python3, iptables, Docker (официальный
   репозиторий docker.com), Node.js 22, pnpm;
3. заводит пользователя `edaphia`, код — в `/opt/edaphia`;
4. спрашивает, на каком адресе и порту открыть веб-интерфейс;
5. собирает и поднимает edaphia, выводит копию мастер-ключа (сохраните вне
   сервера), спрашивает логин и пароль оператора и ключи API;
6. по вопросу закрывает контейнерам вход на сам сервер (правило iptables,
   служба `edaphia-hostguard`; ssh не трогается).

Повторный запуск той же команды — обновление: данные и ключи сохраняются.

Обновление без токена — отдельной командой:

```bash
sudo edaphia update
```

Для неё установщик заводит пользователю `edaphia` ssh-ключ и, если ключ ещё не
добавлен, печатает его на итоговом экране. Ключ нужно один раз добавить в репозиторий
edaphia: Settings → Deploy keys → Add deploy key, «Allow write access» не
отмечать.

На экране — только ход установки; подробный вывод — в журнале
`/var/log/edaphia-install.log`, при ошибке показываются его последние строки.

Без интерактива (все ответы — переменными): `EDAPHIA_YES=1`, `EDAPHIA_GIT_TOKEN`,
`EDAPHIA_UI_BIND`, `EDAPHIA_UI_PORT`, `EDAPHIA_VIEW_PORT`, `EDAPHIA_HOSTGUARD=да|нет`.
Ключи API, логин оператора и копия мастер-ключа всё равно спрашиваются в
терминале — потом: `sudo -u edaphia edaphia secrets`.

## Часть 2 («доработка»)

Ставится отдельно, на сервер, где уже работает edaphia:

```bash
curl -fsSL https://raw.githubusercontent.com/zqpmv/edaphia_install/main/install-edaphia-part2.sh | sudo bash
```

Что делает скрипт:

1. проверяет, что edaphia стоит и её контур готов к части 2 (иначе просит
   сначала `sudo edaphia update`);
2. заводит пользователю `edaphia` отдельный ключ для обновлений части 2
   (GitHub не принимает один deploy key в два репозитория);
3. кладёт код в `/opt/edaphia-part2`: по этому ключу, если он уже добавлен,
   иначе по токену только на чтение для репозитория edaphia-part2;
4. собирает образ и запускает контейнер части 2;
5. включает пункт «Доработка» в веб-интерфейсе: записывает адрес части 2 в
   `/etc/edaphia/stand.sh` (с проверкой и копией файла) и перезапускает
   control. Если идут прогоны, перезапуск откладывается: итоговый экран
   скажет, что сделать.

Повторный запуск — обновление. Без токена: `sudo edaphia update part2`. Ключ
с итогового экрана нужно один раз добавить в репозиторий edaphia-part2:
Settings → Deploy keys, «Allow write access» не отмечать.

Журнал: `/var/log/edaphia-part2-install.log`. Ответы заранее: `EDAPHIA_YES=1`,
`EDAPHIA_PART2_GIT_TOKEN`.
