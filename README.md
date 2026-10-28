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

Без интерактива (все ответы — переменными): `EDAPHIA_GIT_TOKEN`,
`EDAPHIA_UI_BIND`, `EDAPHIA_UI_PORT`, `EDAPHIA_VIEW_PORT`, `EDAPHIA_HOSTGUARD=да|нет`.
Ключи API, логин оператора и копия мастер-ключа всё равно спрашиваются в
терминале — потом: `sudo -u edaphia edaphia secrets`.
