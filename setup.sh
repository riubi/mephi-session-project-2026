#!/bin/bash
set -euo pipefail

STUDENT_ID="${STUDENT_ID:-M2551076}"
ARTIFACTS="${ARTIFACTS:-/artifacts}"
HISTORY_LOG="${HISTORY_LOG:-/root/project_history.txt}"

log_cmd() { echo "$1" >> "${HISTORY_LOG}.tmp"; }
run() { log_cmd "$*"; "$@"; }

mkdir -p "${ARTIFACTS}" /data /root /tmp
rm -f "${HISTORY_LOG}.tmp"
touch "${HISTORY_LOG}.tmp"

# отключаем репозиторий openh264
for f in /etc/yum.repos.d/fedora-cisco-openh264.repo /etc/yum.repos.d/*openh264*; do
  [[ -f "$f" ]] && sed -i 's/^enabled=1/enabled=0/' "$f" 2>/dev/null || true
done
DNF_OPTS=(--exclude='openh264*')

# 2.1 установка пакетов
run dnf -y "${DNF_OPTS[@]}" install --setopt=install_weak_deps=False \
  nginx tcpdump libcap-ng-utils \
  policycoreutils policycoreutils-python-utils \
  selinux-policy-targeted \
  openssh-server \
  NetworkManager iproute iputils \
  parted e2fsprogs \
  util-linux curl passwd \
  systemd systemd-pam

# 1.1 имя хоста
run hostnamectl set-hostname mephi-2026.domain.local 2>/dev/null || true
echo 'mephi-2026.domain.local' > /etc/hostname

# 1.2 статический адрес и шлюз
IFACE="$(ip -o route show default 2>/dev/null | awk '{print $5}' | head -1)"
if [[ -z "${IFACE}" ]]; then
  IFACE="$(ip -o link show | awk -F': ' '$2 !~ /^lo/ {print $2; exit}')"
fi
[[ -n "${IFACE}" ]] || IFACE="eth0"

if systemctl is-system-running &>/dev/null && systemctl start NetworkManager &>/dev/null; then
  run sleep 2
  nmcli con show mephi-static &>/dev/null && run nmcli con delete mephi-static
  run nmcli con add type ethernet con-name mephi-static ifname "${IFACE}" \
    ipv4.method manual ipv4.addresses 192.168.1.100/24 ipv4.gateway 192.168.1.1 \
    ipv4.dns 8.8.8.8 autoconnect yes || true
  run nmcli con up mephi-static || true
fi
run ip addr add 192.168.1.100/24 dev "${IFACE}" 2>/dev/null || true

# 1.2 проверка связи
bash -c "ping -c 4 8.8.8.8 > /tmp/network_check.txt" || true
bash -c "ping -c 4 192.168.1.1 >> /tmp/network_check.txt" || true
log_cmd "ping -c 4 8.8.8.8 > /tmp/network_check.txt"
log_cmd "ping -c 4 192.168.1.1 >> /tmp/network_check.txt"

# 2.2 загрузка rpm
log_cmd "dnf download tcpdump && rpm -ivh tcpdump*.rpm"
if ! dnf -y -C download --destdir=/tmp tcpdump; then
  dnf -y download --destdir=/tmp tcpdump
fi
shopt -s nullglob
RPM_LIST=(/tmp/tcpdump-*.rpm)
shopt -u nullglob
[[ ${#RPM_LIST[@]} -ge 1 ]] || { echo "tcpdump rpm not found"; exit 1; }
TCPDUMP_RPM="${RPM_LIST[0]}"
run rpm -ivh --replacepkgs "${TCPDUMP_RPM}"

# 3.1 диск ext4 с меткой MEPHI_DATA, монтирование в /data/mephi-web
DISK_IMG="/tmp/mephi_sdb.img"
mkdir -p /data/mephi-web
if ! mountpoint -q /data/mephi-web; then
  losetup -j "${DISK_IMG}" 2>/dev/null | cut -d: -f1 | xargs -r -n1 losetup -d 2>/dev/null || true
  run truncate -s 120M "${DISK_IMG}"
  run parted -s "${DISK_IMG}" mklabel gpt mkpart primary ext4 1MiB 100%
  LOOP="$(losetup -f --show -P "${DISK_IMG}")"
  partprobe "${LOOP}" 2>/dev/null || true
  udevadm settle 2>/dev/null || sleep 1
  PART="${LOOP}p1"
  for _ in {1..15}; do [[ -b "$PART" ]] && break; sleep 0.2; done
  if [[ -b "$PART" ]]; then
    run mkfs.ext4 -F -L MEPHI_DATA "${PART}"
    run mount "${PART}" /data/mephi-web
  else
    losetup -d "${LOOP}" 2>/dev/null || true
    run wipefs -a -f "${DISK_IMG}" 2>/dev/null || true
    run mkfs.ext4 -F -L MEPHI_DATA "${DISK_IMG}"
    run mount -o loop "${DISK_IMG}" /data/mephi-web
  fi
fi

# автомонтирование по метке (nofail чтобы отсутствие диска не ломало загрузку)
if ! grep -q 'MEPHI_DATA' /etc/fstab; then
  echo 'LABEL=MEPHI_DATA /data/mephi-web ext4 defaults,nofail,x-systemd.device-timeout=10 0 2' >> /etc/fstab
fi

# 4.1 пользователь, группа, setgid 2775
run groupadd -f mephi-devs
id mephi-admin &>/dev/null || run useradd -m mephi-admin
run bash -c "echo 'mephi-admin:P@ssw0rd2026' | chpasswd"
run usermod -aG mephi-devs mephi-admin
run chown mephi-admin:mephi-devs /data/mephi-web
run chmod 2775 /data/mephi-web

# 4.2 SELinux контекст для каталога nginx
if command -v semanage &>/dev/null; then
  semanage fcontext -a -t httpd_sys_content_t '/data/mephi-web(/.*)?' 2>/dev/null || \
    semanage fcontext -m -t httpd_sys_content_t '/data/mephi-web(/.*)?' 2>/dev/null || true
  log_cmd "semanage fcontext -a -t httpd_sys_content_t '/data/mephi-web(/.*)?'"
  run restorecon -Rv /data/mephi-web || true
fi

# 3.2/5.2 nginx отдаёт /data/mephi-web
run mkdir -p /etc/nginx/conf.d
shopt -s nullglob
for f in /etc/nginx/conf.d/*.conf; do
  [[ "$f" == /etc/nginx/conf.d/mephi-web.conf ]] && continue
  mv "$f" "${f}.bak" 2>/dev/null || true
done
shopt -u nullglob
cat > /etc/nginx/conf.d/mephi-web.conf <<'EOF'
server {
    listen       80 default_server;
    listen       [::]:80 default_server;
    server_name  _;
    root         /data/mephi-web;
    index        index.html;
    location / {
        try_files $uri $uri/ =404;
    }
}
EOF

echo "Hello from Student: ${STUDENT_ID}" > /data/mephi-web/index.html
run chown mephi-admin:mephi-devs /data/mephi-web/index.html

# 3.2 автозапуск и старт nginx
run systemctl enable nginx 2>/dev/null || true
if ! systemctl start nginx 2>/dev/null; then
  run nginx -t
  run nginx
fi

# 4.2 capabilities для tcpdump (запуск обычным пользователем)
run chmod u-s /usr/sbin/tcpdump 2>/dev/null || true
run setcap cap_net_raw,cap_net_admin+ep /usr/sbin/tcpdump
run runuser -u mephi-admin -- /usr/sbin/tcpdump --help >/dev/null 2>&1 || true

# 5.1 запрет входа root через pam_listfile
install -d -m 755 /etc/ssh
echo root > /etc/ssh/denied_users
chmod 644 /etc/ssh/denied_users
pam_prepend_listfile() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  grep -q 'pam_listfile.so.*denied_users' "$file" && return 0
  local tmp; tmp="$(mktemp)"
  {
    echo 'auth required pam_listfile.so onerr=fail item=user sense=deny file=/etc/ssh/denied_users'
    cat "$file"
  } > "$tmp"
  mv "$tmp" "$file"
}
pam_prepend_listfile /etc/pam.d/sshd
pam_prepend_listfile /etc/pam.d/login
log_cmd "pam_listfile denied_users sshd login"

# 5.2 проверка отдачи страницы
bash -c 'curl -sS "http://127.0.0.1/" -o /dev/null' || true
bash -c 'curl -sS "http://192.168.1.100/" -o /tmp/curl_ip.txt' || bash -c 'curl -sS "http://127.0.0.1/" -o /tmp/curl_ip.txt' || true
log_cmd "curl http://localhost"
log_cmd "curl http://192.168.1.100"

# логи nginx после запросов
journalctl -u nginx --since "5 minutes ago" > /tmp/nginx_recent_logs.txt 2>&1 || true
if [[ ! -s /tmp/nginx_recent_logs.txt ]] || grep -qi 'no journal\|no entries' /tmp/nginx_recent_logs.txt; then
  tail -n 20 /var/log/nginx/access.log > /tmp/nginx_recent_logs.txt 2>/dev/null || true
fi

# сбор артефактов
run cp /tmp/nginx_recent_logs.txt /root/nginx_recent_logs.txt
run cp /etc/fstab /root/fstab.txt
(getenforce > /root/selinux_status.txt 2>&1) || echo "Disabled" > /root/selinux_status.txt
(ls -Zd /data/mephi-web 2>/dev/null || ls -ld /data/mephi-web) > /root/file_contexts.txt
run getcap /usr/sbin/tcpdump > /root/tcpdump_capabilities.txt
run stat /data/mephi-web > /root/permissions.txt
run id mephi-admin > /root/users_groups.txt
run getent group mephi-devs >> /root/users_groups.txt
[[ -f /tmp/curl_ip.txt ]] && run cp /tmp/curl_ip.txt /root/curl_output.txt || true

bash -c "ping -c 4 8.8.8.8 > /root/network_check.txt" || true
bash -c "ping -c 4 192.168.1.1 >> /root/network_check.txt" || true

cat >> "${HISTORY_LOG}.tmp" <<'EOF'
journalctl -u nginx --since "5 minutes ago" > ~/nginx_recent_logs.txt
cp /etc/fstab ~/fstab.txt
getenforce > ~/selinux_status.txt
ls -Zd /data/mephi-web > ~/file_contexts.txt
getcap /usr/sbin/tcpdump > ~/tcpdump_capabilities.txt
stat /data/mephi-web > ~/permissions.txt
id mephi-admin > ~/users_groups.txt
getent group mephi-devs >> ~/users_groups.txt
curl -s http://192.168.1.100 > ~/curl_output.txt
ping -c 4 8.8.8.8 > ~/network_check.txt
ping -c 4 192.168.1.1 >> ~/network_check.txt
history > ~/project_history.txt
EOF

nl -ba "${HISTORY_LOG}.tmp" > "${HISTORY_LOG}" 2>/dev/null || cp "${HISTORY_LOG}.tmp" "${HISTORY_LOG}"

for pair in project_history.txt:/root/project_history.txt \
  network_check.txt:/root/network_check.txt \
  nginx_recent_logs.txt:/root/nginx_recent_logs.txt \
  fstab.txt:/root/fstab.txt \
  selinux_status.txt:/root/selinux_status.txt \
  file_contexts.txt:/root/file_contexts.txt \
  tcpdump_capabilities.txt:/root/tcpdump_capabilities.txt \
  permissions.txt:/root/permissions.txt \
  users_groups.txt:/root/users_groups.txt \
  index.html:/data/mephi-web/index.html \
  curl_output.txt:/root/curl_output.txt; do
  out="${pair%%:*}"; src="${pair##*:}"
  [[ -f "$src" ]] && cp -a "$src" "${ARTIFACTS}/${out}"
done
cp -a "${TCPDUMP_RPM}" "${ARTIFACTS}/tcpdump.rpm"

nginx -s quit 2>/dev/null || true
exec nginx -g 'daemon off;'
