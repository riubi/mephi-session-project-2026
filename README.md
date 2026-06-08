# Сессионный проект (Fedora 43)

Подготовка Fedora 43 для локальной сети: имя хоста, сеть, nginx, второй диск,
пользователи и группы, SELinux, capabilities, веб-страница. Вся настройка в `setup.sh`.

## Запуск

```bash
docker build -t mephi-session .
docker network create --subnet 192.168.1.0/24 --gateway 192.168.1.1 mephi-net
docker run --rm -d -p 8080:80 --privileged --network mephi-net --ip 192.168.1.100 \
  -e STUDENT_ID=M2551076 -v "$PWD/artifacts:/artifacts" mephi-session
```

Страница `http://localhost:8080` отдаёт `Hello from Student: M2551076`.
Артефакты пишутся в `artifacts/` и копируются в корень репозитория.

## Файлы

`project_history.txt`, `network_check.txt`, `nginx_recent_logs.txt`, `fstab.txt`,
`selinux_status.txt`, `file_contexts.txt`, `tcpdump_capabilities.txt`, `permissions.txt`,
`users_groups.txt`, `index.html`, `curl_output.txt`, `tcpdump.rpm`,
`mephi-nginx-screenshot.png`.

## SELinux

`selinux_status.txt` и `file_contexts.txt` сняты на Fedora 43 с включённым SELinux
(Enforcing). Ядро Docker Desktop SELinux не поддерживает.
