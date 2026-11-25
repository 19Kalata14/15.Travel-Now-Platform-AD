#!/usr/bin/env bash
# МИС, ТУЕС. Час 9: сегментите на фирмата на gw, като network namespaces.
#
# Всеки офис/сегмент от сценария става отделно мрежово пространство (namespace) на gw,
# свързано с gw с виртуален кабел (veth). Трафикът между сегментите минава през
# веригата forward на gw, точно както при истински рутер. Услугите от сценария са
# заместители (ncat слушател на порта), които отговарят с "ok <име>".
# Сегментите са симулация. Защитната стена (nftables на gw) е истинска.
#
# Употреба (като root на gw):
#   ./postroi-segmenti.sh install                 пакети, форуардинг, папка /etc/h09
#   ./postroi-segmenti.sh up [firma.conf]         вдига сегментите и услугите
#   ./postroi-segmenti.sh down                    маха ги
#   ./postroi-segmenti.sh status                  сегменти, услуги, правила, постоянство
#   ./postroi-segmenti.sh skelet > moi.nft        скелет на ruleset с имената на твоите сегменти
#   ./postroi-segmenti.sh probvai moi.nft         прилага с автоматично връщане след 60 s без потвърждение
#   ./postroi-segmenti.sh zapazi moi.nft          записва в /etc/nftables.conf и го включва при зареждане
#   ./postroi-segmenti.sh proba <откъде> <адрес> <порт|ping> [udp]
#   ./postroi-segmenti.sh dosag <сегмент>         до колко услуги в други сегменти стига хост оттук
#   ./postroi-segmenti.sh zhurnal [брой]          последните откази от журнала на ядрото
#   ./postroi-segmenti.sh wg up|down|status       задача със звездичка: WireGuard клон
#
# <откъде> е име на сегмент (plovdiv), сегмент с конкретен адрес (plovdiv@10.1.0.21) или gw.
set -euo pipefail

ETC=/etc/h09
RUN=/run/h09
LIB=/var/lib/h09
CONF_DEFAULT=$ETC/firma.conf
SELF="$(readlink -f "$0")"

die() { echo "ГРЕШКА: $*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "изпълни като root (sudo)"; }

# ---------- четене на конфигурацията ----------
# Формат (редове, # е коментар):
#   firma   <ИМЕ>                                 префиксът в журнала става [ИМЕ-DROP]
#   segment <име> <мрежа/маска> <адрес на gw>     име до 10 знака, латиница
#   host    <сегмент> <адрес> [описание]          първият host е адресът по подразбиране за proba
#   usluga  <адрес> <порт> <tcp|udp> <име>        заместител; ако адресът е на gw, слуша на самия gw
FIRMA=""; SEGS=(); declare -A SNET SGW SHOSTS; USL=()
load_conf() {
    local f="${1:-$CONF_DEFAULT}"
    [[ -f "$f" ]] || die "няма $f (копирай конфигурацията на фирмата си там)"
    FIRMA=""; SEGS=(); SNET=(); SGW=(); SHOSTS=(); USL=()
    local kw a b c d
    while read -r kw a b c d; do
        [[ -z "${kw:-}" || "$kw" == \#* ]] && continue
        case "$kw" in
            firma)   FIRMA="$a" ;;
            segment) [[ ${#a} -le 10 && "$a" =~ ^[a-z][a-z0-9]*$ ]] || die "сегмент '$a': до 10 малки латински букви/цифри"
                     SEGS+=("$a"); SNET[$a]="$b"; SGW[$a]="$c"; SHOSTS[$a]="" ;;
            host)    [[ -n "${SNET[$a]:-}" ]] || die "host в непознат сегмент '$a'"
                     SHOSTS[$a]="${SHOSTS[$a]} $b" ;;
            usluga)  USL+=("$a $b $c ${d%% *}") ;;
            *) die "непознат ред в конфигурацията: $kw" ;;
        esac
    done < <(sed 's/#.*//' "$f")
    [[ -n "$FIRMA" ]] || die "липсва ред 'firma'"
    [[ ${#SEGS[@]} -ge 2 ]] || die "нужни са поне два сегмента"
}
plen() { echo "${1#*/}"; }
seg_of_addr() {   # в кой сегмент е адресът (по host редовете или по gw адреса)
    local ip="$1" s h
    for s in "${SEGS[@]}"; do
        [[ "${SGW[$s]}" == "$ip" ]] && { echo "gw"; return; }
        for h in ${SHOSTS[$s]}; do [[ "$h" == "$ip" ]] && { echo "$s"; return; }; done
    done
    echo ""
}

# ---------- install ----------
do_install() {
    need_root
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -y -q nftables ncat tcpdump iproute2
    echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/90-h09.conf
    sysctl -q -p /etc/sysctl.d/90-h09.conf
    mkdir -p "$ETC" "$LIB"
    install -m 755 "$SELF" /usr/local/sbin/postroi-segmenti.sh
    ln -sf /usr/local/sbin/postroi-segmenti.sh /usr/local/sbin/proba
    cat > /etc/systemd/system/h09-segmenti.service <<EOF
[Unit]
Description=MIS Chas 9: segmentite na firmata (namespaces)
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/postroi-segmenti.sh up
ExecStop=/usr/local/sbin/postroi-segmenti.sh down

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    echo
    echo "Готово. Следва:"
    echo "  1. копирай конфигурацията на фирмата си:  sudo cp NN-firma.conf $CONF_DEFAULT"
    echo "  2. sudo systemctl enable --now h09-segmenti   (вдига сегментите и при всяко зареждане)"
}

# ---------- up / down ----------
start_listener() {   # $1 netns или "" за самия gw, $2 адрес, $3 порт, $4 tcp|udp, $5 име
    local ns="$1" ip="$2" port="$3" proto="$4" name="$5" u=""
    [[ "$proto" == udp ]] && u="-u"
    local cmd=(ncat $u -l -k "$ip" "$port" -c "echo ok $name")
    [[ -n "$ns" ]] && cmd=(ip netns exec "$ns" "${cmd[@]}")
    setsid "${cmd[@]}" >/dev/null 2>&1 < /dev/null &
    echo $! >> "$RUN/pids"
}
do_up() {
    need_root
    local conf="${1:-$CONF_DEFAULT}"
    load_conf "$conf"
    do_down quiet
    mkdir -p "$RUN"; : > "$RUN/pids"
    [[ "$conf" == "$CONF_DEFAULT" ]] || cp "$conf" "$CONF_DEFAULT"
    sysctl -q -w net.ipv4.ip_forward=1
    local s ns v gwip
    # проверка за застъпване с вече съществуващи мрежи на gw (например LAN1 от Час 1)
    for s in "${SEGS[@]}"; do
        if [[ -n "$(ip -4 route show "${SNET[$s]}" 2>/dev/null)" ]]; then
            die "мрежата ${SNET[$s]} вече е на gw ($(ip -4 route show "${SNET[$s]}")). Смени адресите на LAN1/LAN2 или временно свали интерфейса."
        fi
    done
    for s in "${SEGS[@]}"; do
        ns="seg-$s"; v="v-$s"; gwip="${SGW[$s]}"
        ip netns add "$ns"
        ip link add "$v" type veth peer name eth0 netns "$ns"
        ip addr add "$gwip/$(plen "${SNET[$s]}")" dev "$v"
        ip link set "$v" up
        ip -n "$ns" link set lo up
        ip -n "$ns" link set eth0 up
        local h first=1
        for h in ${SHOSTS[$s]}; do
            # адрес извън мрежата на сегмента (подправен източник за anti-spoofing) се слага с /32
            if [[ "$(ipcalc_net "$h" "$(plen "${SNET[$s]}")")" == "${SNET[$s]%/*}" ]]; then
                ip -n "$ns" addr add "$h/$(plen "${SNET[$s]}")" dev eth0
            else
                ip -n "$ns" addr add "$h/32" dev eth0
            fi
        done
        # сегментът inet е "интернетът": няма маршрут обратно към вътрешните мрежи (нужен е NAT)
        if [[ "$s" != inet ]]; then
            ip -n "$ns" route add default via "$gwip"
        fi
    done
    local line ip port proto name seg
    for line in "${USL[@]}"; do
        read -r ip port proto name <<< "$line"
        seg="$(seg_of_addr "$ip")"
        [[ -n "$seg" ]] || die "услуга $name: адресът $ip не е нито host, нито адрес на gw"
        if [[ "$seg" == gw ]]; then start_listener "" "$ip" "$port" "$proto" "$name"
        else start_listener "seg-$seg" "$ip" "$port" "$proto" "$name"; fi
    done
    sleep 0.5
    echo "Фирма $FIRMA: ${#SEGS[@]} сегмента, ${#USL[@]} услуги заместители. Виж: $0 status"
}
ipcalc_net() {   # мрежовият адрес на $1 при маска /$2 (чист bash)
    local IFS=. a b c d m=$2; read -r a b c d <<< "$1"
    local n=$(( (a<<24)|(b<<16)|(c<<8)|d )); local mask=$(( m==0 ? 0 : (0xffffffff << (32-m)) & 0xffffffff ))
    n=$(( n & mask ))
    echo "$(( (n>>24)&255 )).$(( (n>>16)&255 )).$(( (n>>8)&255 )).$(( n&255 ))"
}
do_down() {
    [[ "${1:-}" == quiet ]] || need_root
    if [[ -f "$RUN/pids" ]]; then
        while read -r p; do kill "$p" 2>/dev/null || true; done < "$RUN/pids"
        rm -f "$RUN/pids"
    fi
    pkill -f 'ncat .*-c echo ok ' 2>/dev/null || true
    local ns
    for ns in $(ip netns list 2>/dev/null | awk '/^seg-/{print $1}'); do
        ip netns pids "$ns" 2>/dev/null | xargs -r kill 2>/dev/null || true
        ip netns del "$ns"
    done
    for v in $(ip -br link 2>/dev/null | awk '{print $1}' | grep -E '^v-' | sed 's/@.*//'); do
        ip link del "$v" 2>/dev/null || true
    done
    [[ "${1:-}" == quiet ]] || echo "Сегментите са махнати."
}

# ---------- proba ----------
do_proba() {
    need_root
    [[ $# -ge 3 ]] || die "proba <откъде> <адрес> <порт|ping> [udp]"
    load_conf
    local from="$1" dst="$2" port="$3" proto="${4:-tcp}" seg src ns=() out rc
    seg="${from%@*}"
    if [[ "$seg" == gw ]]; then
        src="gw"
    else
        [[ -n "${SNET[$seg]:-}" ]] || die "няма сегмент '$seg' (има: ${SEGS[*]})"
        ns=(ip netns exec "seg-$seg")
        if [[ "$from" == *@* ]]; then src="${from#*@}"; else src="$(echo ${SHOSTS[$seg]} | awk '{print $1}')"; fi
        [[ -n "$src" ]] || die "сегментът '$seg' няма host"
    fi
    local stamp label res
    stamp="$(date '+%F %T')"
    if [[ "$port" == ping ]]; then
        label="$from($src) -> $dst icmp"
        local sopt=(); [[ "$src" != gw ]] && sopt=(-I "$src")
        if out="$("${ns[@]}" ping -n -c1 -W2 "${sopt[@]}" "$dst" 2>&1)"; then res="МИНАВА"
        elif grep -qiE 'unreachable|prohibited' <<< "$out"; then res="ОТКАЗ (ICMP: недостижим/забранен)"
        else res="НЕ МИНАВА (няма отговор: drop)"; fi
    else
        label="$from($src) -> $dst:$port/$proto"
        local sopt=(); [[ "$src" != gw ]] && sopt=(-s "$src")
        set +e
        if [[ "$proto" == udp ]]; then
            out="$( (echo proba; sleep 2) | timeout 5 "${ns[@]}" ncat -u -w 2 "${sopt[@]}" "$dst" "$port" 2>&1)"; rc=$?
        else
            out="$(timeout 5 "${ns[@]}" ncat -w 3 --recv-only "${sopt[@]}" "$dst" "$port" 2>&1 </dev/null)"; rc=$?
        fi
        set -e
        if grep -q '^ok ' <<< "$out"; then res="МИНАВА, отговор: $(grep -m1 '^ok ' <<< "$out")"
        elif grep -qi 'refused' <<< "$out"; then res="ОТКАЗ (connection refused: reject или затворен порт)"
        elif [[ "$proto" == tcp && $rc -eq 0 ]]; then res="МИНАВА (връзка без отговор от заместител)"
        else res="НЕ МИНАВА (няма отговор: drop)"; fi
    fi
    printf '%s  %-44s %s\n' "$stamp" "$label" "$res"
}

# ---------- dosag: blast radius ----------
do_dosag() {
    need_root
    [[ $# -ge 1 ]] || die "dosag <сегмент>"
    load_conf
    local from="$1" seg="${1%@*}" line ip port proto name dseg n=0 ok=0 r
    [[ -n "${SNET[$seg]:-}" ]] || die "няма сегмент '$seg'"
    echo "Обхват от $from: до кои услуги на фирмата в ДРУГИ сегменти стига хост оттук (без inet)"
    for line in "${USL[@]}"; do
        read -r ip port proto name <<< "$line"
        dseg="$(seg_of_addr "$ip")"
        [[ "$dseg" == "$seg" || "$dseg" == inet ]] && continue
        n=$((n+1))
        r="$(do_proba "$from" "$ip" "$port" "$proto")"
        echo "$r"
        grep -q 'МИНАВА' <<< "$r" && ! grep -q 'НЕ МИНАВА' <<< "$r" && ok=$((ok+1))
    done
    echo "ОБХВАТ: $from стига до $ok от $n услуги в други сегменти"
}

# ---------- skelet ----------
do_skelet() {
    load_conf
    local wan mgmt s
    wan="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"; wan="${wan:-enp0s3}"
    mgmt="$(ip -4 -br addr 2>/dev/null | awk '$3 ~ /^192\.168\.56\./{print $1; exit}')"; mgmt="${mgmt:-$wan}"
    local up; up="$(echo "$FIRMA" | tr '[:lower:]' '[:upper:]')"
    cat <<EOF
#!/usr/sbin/nft -f
# МИС, Час 9. Защитна стена на gw за $up
# Генерирано от postroi-segmenti.sh skelet на $(date +%F). Попълни местата, отбелязани с >>>.
# Ред на работа: матрица на потоците -> правило с коментар "изискване N" -> proba разрешено и забранено -> zhurnal.
# Прилагане: ./postroi-segmenti.sh probvai moi.nft   (връща старото след 60 s без потвърждение)

flush ruleset

define MGMT = "$mgmt"      # интерфейсът, през който управляваш gw (ssh от лаптопа)
EOF
    for s in "${SEGS[@]}"; do
        printf 'define IF_%-10s = "v-%s"\n' "$(echo "$s" | tr '[:lower:]' '[:upper:]')" "$s"
    done
    for s in "${SEGS[@]}"; do
        printf 'define NET_%-9s = %s\n' "$(echo "$s" | tr '[:lower:]' '[:upper:]')" "${SNET[$s]}"
    done
    cat <<EOF

table inet firma {
    chain input {
        # трафик КЪМ самия gw
        type filter hook input priority filter; policy drop;
        ct state established,related accept
        ct state invalid drop
        iifname "lo" accept
        iifname \$MGMT tcp dport 22 accept comment "управление на gw"
        # >>> услуги на самия gw от сценария (например NTP на адреса на gw)
        counter log prefix "[$up-IN-DROP] "
    }

    chain forward {
        # трафик ПРЕЗ gw, между сегментите: тук е сегментацията
        type filter hook forward priority filter; policy drop;
        ct state established,related accept
        ct state invalid drop
        # >>> по едно правило за всяко изискване от сценария, с коментар
        # пример: iifname \$IF_PLOVDIV ip daddr 10.0.0.10 tcp dport 8080 accept comment "изискване 1: Пловдив към ERP"
        counter log prefix "[$up-DROP] "
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}

table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        # >>> DNAT, ако сценарият публикува услуга към интернет (сегмент inet)
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        # >>> masquerade, ако сценарият дава интернет на някой сегмент
        # пример: oifname \$IF_INET ip saddr \$NET_HQ masquerade
    }
}
EOF
}

# ---------- probvai / zapazi ----------
do_probvai() {
    need_root
    local f="${1:-}"; [[ -f "$f" ]] || die "probvai <файл.nft>"
    mkdir -p "$LIB"
    echo "== Проверка на синтаксиса (nft -c)"
    nft -c -f "$f" || die "синтаксисът не минава; нищо не е приложено"
    local ts; ts="$(date +%Y%m%d-%H%M%S)-$$"
    { echo "flush ruleset"; nft list ruleset; } > "$LIB/predi-$ts.nft"
    nft -f "$f"
    local flag="$LIB/chaka-$ts"; : > "$flag"
    setsid bash -c "sleep 60; if [ -f '$flag' ]; then nft -f '$LIB/predi-$ts.nft'; rm -f '$flag'; logger -t h09 'probvai: върнати старите правила'; fi" >/dev/null 2>&1 < /dev/null &
    echo "== Новите правила са активни. Старите са в $LIB/predi-$ts.nft"
    local ans=""
    read -r -t 60 -p "Ако още ме виждаш, напиши ДА в рамките на 60 s: " ans || true
    if [[ "$ans" == "ДА" || "$ans" == "da" || "$ans" == "DA" ]]; then
        rm -f "$flag"; echo "Потвърдено. Правилата остават (до рестарт: за постоянство виж zapazi)."
    else
        echo; echo "Без потвърждение: след малко се връщат старите правила."
    fi
}
do_zapazi() {
    need_root
    local f="${1:-}"; [[ -f "$f" ]] || die "zapazi <файл.nft>"
    nft -c -f "$f" || die "синтаксисът не минава"
    grep -q '^flush ruleset' "$f" || die "файлът трябва да започва с 'flush ruleset', иначе правилата се добавят към старите"
    [[ -f /etc/nftables.conf ]] && cp /etc/nftables.conf "/etc/nftables.conf.predi-h09"
    install -m 755 "$f" /etc/nftables.conf
    systemctl enable nftables >/dev/null 2>&1 || true
    nft -f /etc/nftables.conf
    echo "Записано в /etc/nftables.conf; nftables.service: $(systemctl is-enabled nftables 2>/dev/null || echo ?)."
}
postoyanstvo() {   # дали /etc/nftables.conf дава същите правила като активните
    local en; en="$(systemctl is-enabled nftables 2>/dev/null || true)"; en="${en:-няма systemd}"
    local live tmp
    live="$(nft -s list ruleset 2>/dev/null | md5sum | cut -c1-8)"
    if [[ -f /etc/nftables.conf ]]; then
        ip netns add h09-tmp 2>/dev/null || true
        tmp="$(ip netns exec h09-tmp sh -c 'nft -f /etc/nftables.conf 2>/dev/null && nft -s list ruleset' | md5sum | cut -c1-8)"
        ip netns del h09-tmp 2>/dev/null || true
    else tmp="няма файл"; fi
    echo "  nftables.service при зареждане: $en"
    if [[ "$live" == "$tmp" ]]; then echo "  /etc/nftables.conf съвпада с активните правила: ДА"
    else echo "  /etc/nftables.conf съвпада с активните правила: НЕ (след рестарт правилата ще са други)"; fi
}

# ---------- status / zhurnal ----------
do_status() {
    need_root
    load_conf
    echo "Фирма: $FIRMA   (конфигурация: $CONF_DEFAULT)"
    echo "Форуардинг: $(sysctl -n net.ipv4.ip_forward)"
    echo
    echo "  сегмент    мрежа              адрес на gw     жив    хостове"
    local s live
    for s in "${SEGS[@]}"; do
        if ip netns list | grep -q "^seg-$s\b"; then live="да "; else live="не "; fi
        printf '  %-10s %-18s %-15s %-6s %s\n' "$s" "${SNET[$s]}" "${SGW[$s]}" "$live" "$(echo ${SHOSTS[$s]})"
    done
    echo
    echo "  Услуги заместители (слушат ли):"
    local line ip port proto name seg ok
    for line in "${USL[@]}"; do
        read -r ip port proto name <<< "$line"; seg="$(seg_of_addr "$ip")"
        local pf=t; [[ "$proto" == udp ]] && pf=u
        if [[ "$seg" == gw ]]; then ok="$(ss -Hln$pf "src $ip:$port" | grep -c . || true)"
        else ok="$(ip netns exec "seg-$seg" ss -Hln$pf "src $ip:$port" 2>/dev/null | grep -c . || true)"; fi
        printf '    %-16s %-15s %5s/%s  %s\n' "$name" "$ip" "$port" "$proto" "$([[ $ok -gt 0 ]] && echo слуша || echo НЕ слуша)"
    done
    echo
    echo "  Защитна стена:"
    local pol
    for ch in input forward; do
        pol="$( (nft list chain inet firma $ch 2>/dev/null || true) | awk '/policy/{for(i=1;i<=NF;i++) if($i=="policy") {print $(i+1); exit}}' | tr -d ';')"
        echo "    $ch: политика ${pol:-(няма таблица inet firma)}"
    done
    postoyanstvo
}
do_zhurnal() {
    load_conf
    # всеки префикс от вида [ГЛАВНИ-БУКВИ-И-ТИРЕТА] (скелетът ползва [ФИРМА-DROP], сценарият може да иска свой)
    local n="${1:-20}" re='\[[A-Z][A-Z0-9-]*\] '
    if command -v journalctl >/dev/null && journalctl -k -n1 -q --no-pager 2>/dev/null | grep -q .; then
        journalctl -k -o short-iso --no-pager 2>/dev/null | grep -E "$re" | tail -n "$n" | grep . || echo "(няма записи с префикс)"
    else
        dmesg -T 2>/dev/null | grep -E "$re" | tail -n "$n" | grep . || echo "(няма записи с префикс)"
    fi
}

# ---------- wg: задача със звездичка ----------
# Клонът "vpnklon" е извън фирмата, с публичен адрес 198.51.100.2. Стига до gw (198.51.100.1)
# само по UDP 51820. Тунелът: gw 10.99.0.1, клон 10.99.0.2.
WG_DIR=$ETC/wg
wg_link() {   # $1 netns или "", $2 име: създава интерфейса (модул в ядрото, иначе wireguard-go)
    local ns="$1" name="$2" pre=()
    [[ -n "$ns" ]] && pre=(ip netns exec "$ns")
    if ! "${pre[@]}" ip link add "$name" type wireguard 2>/dev/null; then
        command -v wireguard-go >/dev/null || die "няма WireGuard в ядрото и няма wireguard-go"
        "${pre[@]}" env WG_QUIET=1 wireguard-go "$name" >/dev/null 2>&1
    fi
}
do_wg() {
    need_root
    case "${1:-status}" in
    up)
        command -v wg >/dev/null || { apt-get install -y -q wireguard-tools >/dev/null; }
        load_conf
        mkdir -p "$WG_DIR"; chmod 700 "$WG_DIR"
        local k; for k in gw klon; do
            [[ -f "$WG_DIR/$k.key" ]] || (umask 077; wg genkey > "$WG_DIR/$k.key")
            wg pubkey < "$WG_DIR/$k.key" > "$WG_DIR/$k.pub"
        done
        do_wg down quiet
        ip netns add seg-vpnklon
        ip link add v-vpnklon type veth peer name eth0 netns seg-vpnklon
        ip addr add 198.51.100.1/24 dev v-vpnklon; ip link set v-vpnklon up
        ip -n seg-vpnklon link set lo up; ip -n seg-vpnklon link set eth0 up
        ip -n seg-vpnklon addr add 198.51.100.2/24 dev eth0
        # клонът знае пътя към вътрешните мрежи само през тунела
        wg_link "" wg0
        wg set wg0 listen-port 51820 private-key "$WG_DIR/gw.key" \
            peer "$(cat "$WG_DIR/klon.pub")" allowed-ips 10.99.0.2/32
        ip addr add 10.99.0.1/24 dev wg0; ip link set wg0 up
        wg_link seg-vpnklon wg-klon
        local nets=() s; for s in "${SEGS[@]}"; do [[ "$s" == inet ]] || nets+=("${SNET[$s]}"); done
        ip netns exec seg-vpnklon wg set wg-klon private-key "$WG_DIR/klon.key" \
            peer "$(cat "$WG_DIR/gw.pub")" endpoint 198.51.100.1:51820 \
            allowed-ips "$(IFS=,; echo "10.99.0.0/24,${nets[*]}")" persistent-keepalive 25
        ip -n seg-vpnklon addr add 10.99.0.2/24 dev wg-klon; ip -n seg-vpnklon link set wg-klon up
        for s in "${nets[@]}"; do ip -n seg-vpnklon route add "$s" dev wg-klon; done
        # без тунел: трафикът с публичния адрес на клона отива в чист вид към gw
        # (за да се докаже, че стената, а не тунелът, спира прекия път)
        ip -n seg-vpnklon route add default via 198.51.100.1
        ip -n seg-vpnklon route add default via 198.51.100.1 table 100
        ip -n seg-vpnklon rule add from 198.51.100.2 lookup 100
        grep -q '^segment vpnklon' "$CONF_DEFAULT" || cat >> "$CONF_DEFAULT" <<EOF
# добавено от wg up (задача със звездичка)
segment vpnklon 198.51.100.0/24 198.51.100.1
host    vpnklon 198.51.100.2 klon-publichen
host    vpnklon 10.99.0.2    klon-tunel
EOF
        echo "WireGuard: gw wg0 10.99.0.1 (UDP 51820 на 198.51.100.1), клон 10.99.0.2."
        echo "Тунелът тръгва, след като input на gw пусне UDP 51820. После, за handshake:"
        echo "                    sudo ip netns exec seg-vpnklon ping -c3 10.99.0.1"
        echo "Проба през тунела:  proba vpnklon@10.99.0.2 <адрес> <порт>"
        echo "Проба без тунела:   proba vpnklon@198.51.100.2 <адрес> <порт>"
        echo "Какво се вижда на кабела:  tcpdump -ni v-vpnklon"
        ;;
    down)
        ip link del wg0 2>/dev/null || true
        pkill -f 'wireguard-go wg' 2>/dev/null || true
        ip netns exec seg-vpnklon ip link del wg-klon 2>/dev/null || true
        ip netns del seg-vpnklon 2>/dev/null || true
        ip link del v-vpnklon 2>/dev/null || true
        if [[ "${2:-}" != quiet && -f "$CONF_DEFAULT" ]]; then
            sed -i '/^# добавено от wg up/,$d' "$CONF_DEFAULT"; echo "WireGuard клонът е махнат."
        fi
        ;;
    status) wg show wg0 2>/dev/null || echo "wg0 няма"; echo; ip netns exec seg-vpnklon wg show wg-klon 2>/dev/null || true ;;
    *) die "wg up|down|status" ;;
    esac
}

if [[ "$(basename "$0")" == proba ]]; then do_proba "$@"; exit; fi

case "${1:-}" in
    install) do_install ;;
    up)      shift; do_up "$@" ;;
    down)    do_down ;;
    status)  do_status ;;
    skelet)  do_skelet ;;
    probvai) shift; do_probvai "$@" ;;
    zapazi)  shift; do_zapazi "$@" ;;
    proba)   shift; do_proba "$@" ;;
    dosag)   shift; do_dosag "$@" ;;
    zhurnal) shift; do_zhurnal "$@" ;;
    wg)      shift; do_wg "$@" ;;
    *) sed -n '2,25p' "$SELF" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
