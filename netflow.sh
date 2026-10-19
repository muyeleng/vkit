#!/usr/bin/env bash
# NetFlow — 确定性 TCP 吞吐优化与流控工具
# 核心算法源自 tcpfit (v0.5.9) | 零测速依赖 · 固定 220ms 跨国 BDP 基准 · 1000Mbps 智能分流

set -uo pipefail
umask 022

VERSION="1.3"
FIXED_RTT=220
FIXED_ROLE="proxy"
SHAPE_MAX_BW=1000

# GitHub Raw 直链：支持 bash <(curl ...) 运行时自动将脚本安装至 /usr/local/bin/netflow
SELF_RAW_URL="${NETFLOW_RAW_URL:-https://raw.githubusercontent.com/muyeleng/vkit/main/netflow.sh}"

STATE_DIR="/var/lib/netflow"
SNAPSHOT="$STATE_DIR/origin.snapshot"
SYSCTL_FILE="/etc/sysctl.d/99-netflow.conf"
BBR_MODULE_FILE="/etc/modules-load.d/netflow-bbr.conf"
QDISC_SCRIPT="/usr/local/sbin/netflow-qdisc.sh"
QDISC_UNIT="/etc/systemd/system/netflow-qdisc.service"
ROUTE_HOOK="/etc/networkd-dispatcher/routable.d/50-netflow-initcwnd"
INITCWND_UNIT="/etc/systemd/system/netflow-initcwnd.service"
INITCWND_SCRIPT="/usr/local/sbin/netflow-initcwnd.sh"
NETWORKD_DIR="/etc/systemd/network"
INITCWND_DROPIN_NAME="50-netflow-initcwnd.conf"
INITCWND_MARKER="$STATE_DIR/initcwnd.owned"
INITCWND_VALS="$STATE_DIR/initcwnd.vals"
SELF_PATH="/usr/local/bin/netflow"
LOCK_FILE="/var/lock/netflow.lock"

# ── 视觉与排版 ──────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  green=$'\033[0;32m'; red=$'\033[0;31m'; yellow=$'\033[0;33m'
  cyan=$'\033[0;36m';  dim=$'\033[2m';    bold=$'\033[1m'; plain=$'\033[0m'
else
  green=''; red=''; yellow=''; cyan=''; dim=''; bold=''; plain=''
fi

ok(){   printf '  %s✓%s %s\n' "$green" "$plain" "$*"; }
info(){ printf '  %s·%s %s\n' "$cyan"  "$plain" "$*"; }
warn(){ printf '  %s!%s %s\n' "$yellow" "$plain" "$*" >&2; }
die(){  printf '  %s✕%s %s\n' "$red"   "$plain" "$1" >&2; exit "${2:-1}"; }
rule(){ printf '  %s─────────────────────────────────────────%s\n' "$dim" "$plain"; }

need_root(){ [ "$(id -u)" = 0 ] || die "请使用 root 权限运行"; }
have_tty(){ : 2>/dev/null </dev/tty; }

# 字符串匹配辅助函数 (避免在 set -o pipefail 下使用 grep -q 触发 SIGPIPE 141 错误)
has_word(){
  case "$1" in
    "$2"|"$2"[!A-Za-z0-9_]*|*[!A-Za-z0-9_]"$2"|*[!A-Za-z0-9_]"$2"[!A-Za-z0-9_]*) return 0 ;;
    *) return 1 ;;
  esac
}

# 并发文件锁：防止多个 SSH 窗口同时运行破坏 qdisc 队列或快照
take_lock(){
  command -v flock >/dev/null 2>&1 || return 0
  mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || return 0
  [ -w "$(dirname "$LOCK_FILE")" ] || return 0
  [ "${LOCK_HELD:-0}" = 1 ] && return 0
  exec 9>"$LOCK_FILE" || return 0
  flock -n 9 && { LOCK_HELD=1; return 0; }
  die "另一个 NetFlow 实例正在运行 (锁: $LOCK_FILE)"
}

# 清理终端输入缓冲残留，防止执行期间误触回车直接跳过结果页
drain_tty(){ while read -rsn1 -t 0.05 2>/dev/null </dev/tty; do :; done; return 0; }

is_posint(){
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge "$2" ] 2>/dev/null && [ "$1" -le "$3" ] 2>/dev/null
}

strip_zeros(){
  local v="$1"
  case "$v" in ''|*[!0-9]*) printf '%s' "$v"; return ;; esac
  while [ "${#v}" -gt 1 ] && [ "${v#0}" != "$v" ]; do v=${v#0}; done
  printf '%s' "$v"
}

human_bytes(){
  local b="${1:-0}"
  if   [ "$b" -ge 1048576 ] 2>/dev/null; then printf '%d MB' $(( b / 1048576 ))
  elif [ "$b" -ge 1024 ]    2>/dev/null; then printf '%d KB' $(( b / 1024 ))
  else printf '%s B' "$b"; fi
}

# 自动注册本地快捷命令: 兼容本地文件运行与 bash <(curl ...) 管道运行
self_install(){
  [ "$(id -u)" = 0 ] || return 0
  case "$0" in "$SELF_PATH") return 0 ;; esac
  if [ -f "$0" ] && [ -r "$0" ]; then
    cp -f "$0" "$SELF_PATH" 2>/dev/null && chmod 755 "$SELF_PATH" 2>/dev/null || true
  elif [ -n "$SELF_RAW_URL" ] && command -v curl >/dev/null 2>&1; then
    if curl -fsSL --max-time 10 "$SELF_RAW_URL" -o "${SELF_PATH}.tmp" 2>/dev/null &&
       [ -s "${SELF_PATH}.tmp" ] &&
       grep -q '^#!/usr/bin/env bash' "${SELF_PATH}.tmp" 2>/dev/null; then
      mv -f "${SELF_PATH}.tmp" "$SELF_PATH" && chmod 755 "$SELF_PATH"
    else
      rm -f "${SELF_PATH}.tmp"
    fi
  fi
}

# ── 环境检测 ────────────────────────────────────────────────────────────────
route_field(){
  local key="$1" line="${2-}"
  [ $# -ge 2 ] || line=$(ip -4 route show default 2>/dev/null | head -1)
  printf '%s\n' "$line" | awk -v k="$key" '{for(i=1;i<NF;i++) if($i==k){print $(i+1); exit}}'
}

detect_iface(){
  local i
  i=$(route_field dev)
  [ -n "$i" ] || i=$(route_field dev "$(ip -6 route show default 2>/dev/null | head -1)")
  [ -n "$i" ] || i=$(route_field dev "$(ip -4 route get 1.1.1.1 2>/dev/null | head -1)")
  [ -n "$i" ] || i=$(route_field dev "$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | head -1)")
  echo "$i"
}

detect_ram_mb(){ awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo; }

tc_rate_mbit(){
  local r
  r=$(grep -oE 'rate [0-9.]+[KMGTkmgt]?bit' <<<"${1:-}")
  r=${r%%$'\n'*}; r=${r#rate }
  [ -n "$r" ] || return 1
  awk -v s="$r" 'BEGIN{
    u = s; sub(/^[0-9.]+/, "", u); sub(/bit$/, "", u); v = s + 0
    if      (u == "K" || u == "k") v = v/1000
    else if (u == "G" || u == "g") v = v*1000
    else if (u == "T" || u == "t") v = v*1000000
    else if (u == "")              v = v/1000000
    if (v == int(v)) printf "%d", v; else printf "%g", v }'
}

# ── 核心推导算法 (100% 源自 tcpfit v0.5.9) ──────────────────────────────────
calc_bdp(){ awk -v b="$1" -v r="$2" 'BEGIN{printf "%d", b*1000000/8*(r/1000)}'; }

calc_tcp_mem(){
  awk -v m="$1" 'BEGIN{
    pg=m*1024/4;
    low=int(pg/16); pres=int(pg/8); max=int(pg/4);
    if(low<4096) low=4096; if(pres<8192) pres=8192; if(max<16384) max=16384;
    printf "%d %d %d", low, pres, max
  }'
}

calc_buf_max(){
  awk -v b="$1" -v m="$2" 'BEGIN{
    v   = b*2 + 2097152
    cap = m*32768
    if(cap > 268435456) cap = 268435456
    if(v > cap) v = cap
    if(v < 4194304) v = 4194304
    printf "%d", v
  }'
}

calc_buf_default(){
  local role="$1" bdp="$2"
  case "$role" in
    proxy) echo 1048576 ;;
    bulk)  awk -v b="$bdp" 'BEGIN{v=b; if(v<1048576)v=1048576; if(v>8388608)v=8388608; printf "%d", v}' ;;
    *)     echo 2097152 ;;
  esac
}

# ── 出厂基线快照 ────────────────────────────────────────────────────────────
TUNED_KEYS="
  net.core.default_qdisc
  net.ipv4.tcp_congestion_control
  net.core.rmem_max
  net.core.wmem_max
  net.core.rmem_default
  net.core.wmem_default
  net.ipv4.tcp_rmem
  net.ipv4.tcp_wmem
  net.ipv4.tcp_mem
  net.ipv4.tcp_window_scaling
  net.ipv4.tcp_moderate_rcvbuf
  net.ipv4.tcp_adv_win_scale
  net.core.netdev_max_backlog
  net.core.netdev_budget
  net.core.netdev_budget_usecs
  net.core.optmem_max
  net.core.somaxconn
  net.ipv4.tcp_max_syn_backlog
  net.ipv4.tcp_slow_start_after_idle
  net.ipv4.tcp_no_metrics_save
  net.ipv4.tcp_mtu_probing
  net.ipv4.tcp_sack
  net.ipv4.tcp_dsack
  net.ipv4.tcp_timestamps
  net.ipv4.tcp_fastopen
  net.ipv4.tcp_syncookies
  net.ipv4.tcp_tw_reuse
  net.ipv4.tcp_fin_timeout
  net.ipv4.tcp_keepalive_time
  net.ipv4.ip_local_port_range
  vm.min_free_kbytes
  fs.file-max
  vm.swappiness
"

take_snapshot(){
  mkdir -p "$STATE_DIR"
  [ -f "$SNAPSHOT" ] && return 0
  # 防污染保护：若已有配置文件但快照意外丢失，先移除旧配置并重载系统默认参数，再抓取出厂基线
  if [ -f "$SYSCTL_FILE" ] || [ -f "$QDISC_SCRIPT" ]; then
    warn "检测到已有配置但缺少出厂快照，正在先还原系统默认值以提取纯净基线..."
    rm -f "$SYSCTL_FILE"
    sysctl --system >/dev/null 2>&1 || true
  fi
  local iface tmp want got; iface=$(detect_iface)
  tmp=$(mktemp "${SNAPSHOT}.XXXXXX" 2>/dev/null) || die "无法创建快照文件 (只读文件系统或磁盘已满)"
  if ! {
    echo "# netflow origin snapshot $(date -u +%FT%TZ)"
    echo "KERNEL=$(uname -r)"
    for k in $TUNED_KEYS; do
      printf '%s = %s\n' "$k" "$(sysctl -n "$k" 2>/dev/null)"
    done
    echo "# route: $(ip -4 route show default 2>/dev/null | head -1)"
    echo "# qdisc: $(tc qdisc show dev "$iface" 2>/dev/null | head -1)"
  } > "$tmp"; then
    rm -f "$tmp"; die "快照写入失败"
  fi
  want=$(printf '%s\n' $TUNED_KEYS | grep -c .)
  got=$(grep -cE '^[a-z].* = ' "$tmp")
  if [ "$got" -lt "$want" ] 2>/dev/null; then
    rm -f "$tmp"; die "快照不完整 (${got}/${want} 项), 已中止"
  fi
  mv -- "$tmp" "$SNAPSHOT" || { rm -f "$tmp"; die "快照落盘失败"; }
  ok "已备份出厂基线"
}

# ── 路由首包窗口 (initcwnd) 与持久化 ────────────────────────────────────────
route_set_initcwnd(){
  local n="$1" route token skip=0
  local -a args=() clean=()
  route=$(ip -4 route show default 2>/dev/null | head -1)
  [ -n "$route" ] || return 1
  [ -n "$(route_field dev "$route")" ] || return 1
  read -r -a args <<< "$route"
  for token in "${args[@]}"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$token" in initcwnd|initrwnd) skip=1 ;; *) clean+=("$token") ;; esac
  done
  [ "${#clean[@]}" -gt 1 ] || return 1
  ip -4 route replace "${clean[@]}" initcwnd "$n" initrwnd "$n" 2>/dev/null
}

route_restore_windows(){
  local iface="$1"; shift
  local -a want=("$@")
  local line t skip rc=0 touched=0
  local -a args clean
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ -n "$iface" ]; then
      case " $line " in *" dev $iface "*) ;; *) continue ;; esac
    fi
    args=(); clean=(); skip=0
    read -r -a args <<< "$line"
    for t in "${args[@]}"; do
      if [ "$skip" = 1 ]; then skip=0; continue; fi
      case "$t" in initcwnd|initrwnd) skip=1 ;; *) clean+=("$t") ;; esac
    done
    [ "${#clean[@]}" -gt 1 ] || continue
    touched=1
    ip -4 route replace "${clean[@]}" "${want[@]+"${want[@]}"}" 2>/dev/null || rc=1
  done <<< "$(ip -4 route show default 2>/dev/null)"
  [ "$touched" = 1 ] || return 1
  return "$rc"
}

networkd_manages(){
  [ -n "${1:-}" ] || return 1
  command -v networkctl >/dev/null 2>&1 || return 1
  systemctl is-active -q systemd-networkd 2>/dev/null || return 1
  local st; st=$(networkctl status "$1" 2>/dev/null) || return 1
  grep -Eq 'State: [a-z-]+ \((configured|configuring)' <<< "$st"
}

write_networkd_dropin(){
  local iface="$1" cw="${2:-32}" rw="${3:-32}" ver nf dir route
  ver=$(systemctl --version 2>/dev/null | awk 'NR==1{print $2+0}')
  [ "${ver:-0}" -ge 255 ] 2>/dev/null || return 1
  route=$(ip -4 route show default 2>/dev/null | awk -v d="$iface" '{for(i=1;i<NF;i++) if($i=="dev" && $(i+1)==d){print; exit}}')
  case " $route " in *" proto dhcp "*) ;; *) return 1 ;; esac
  nf=$(networkctl status "$iface" 2>/dev/null) || return 1
  nf=$(awk -F': ' '/Network File:/{print $2; exit}' <<< "$nf")
  case "$nf" in /*.network) ;; *) return 1 ;; esac
  dir="$NETWORKD_DIR/${nf##*/}.d"
  mkdir -p "$dir" 2>/dev/null || return 1
  cat > "$dir/$INITCWND_DROPIN_NAME" <<EOF || return 1
[DHCPv4]
InitialCongestionWindow=$cw
InitialAdvertisedReceiveWindow=$rw
EOF
}

write_dispatcher_hook(){
  local iface="$1" val="${2:-32}" tmp
  [ -d "$(dirname "$ROUTE_HOOK")" ] || return 1
  tmp=$(mktemp "${ROUTE_HOOK}.XXXXXX" 2>/dev/null) || return 1
  {
    printf '#!/bin/sh\n'
    printf 'R=$(ip -4 route show default 2>/dev/null | awk -v d=%s \x27{for(i=1;i<NF;i++) if($i=="dev" && $(i+1)==d){print; exit}}\x27)\n' "$(printf '%q' "$iface")"
    printf '[ -n "$R" ] || exit 0\n'
    cat <<'IH'
C=$(printf '%s' "$R" | awk '{o="";for(i=1;i<=NF;i++){if($i=="initcwnd"||$i=="initrwnd"){i++;continue};o=o" "$i};print o}')
IH
    printf '[ -n "$C" ] && ip -4 route replace $C initcwnd %s initrwnd %s 2>/dev/null\n' "$val" "$val"
    printf 'exit 0\n'
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 755 "$tmp" && mv -- "$tmp" "$ROUTE_HOOK" || { rm -f "$tmp"; return 1; }
}

dispatcher_running(){
  systemctl is-enabled -q networkd-dispatcher 2>/dev/null || return 1
  systemctl start networkd-dispatcher >/dev/null 2>&1 || true
  systemctl is-active -q networkd-dispatcher 2>/dev/null
}

write_initcwnd_unit(){
  local iface="$1" val="${2:-32}"
  command -v systemctl >/dev/null 2>&1 || return 1
  [ -d "$(dirname "$INITCWND_UNIT")" ] || return 1
  mkdir -p "$(dirname "$INITCWND_SCRIPT")" 2>/dev/null || return 1
  {
    printf '#!/bin/sh\n'
    printf 'R=$(ip -4 route show default 2>/dev/null | awk -v d=%s \x27{for(i=1;i<NF;i++) if($i=="dev" && $(i+1)==d){print; exit}}\x27)\n' "$(printf '%q' "$iface")"
    printf '[ -n "$R" ] || exit 0\n'
    cat <<'IH'
C=$(printf '%s' "$R" | awk '{o="";for(i=1;i<=NF;i++){if($i=="initcwnd"||$i=="initrwnd"){i++;continue};o=o" "$i};print o}')
IH
    printf '[ -n "$C" ] && ip -4 route replace $C initcwnd %s initrwnd %s 2>/dev/null\n' "$val" "$val"
    printf 'exit 0\n'
  } > "$INITCWND_SCRIPT" || return 1
  chmod 755 "$INITCWND_SCRIPT" || return 1
  cat > "$INITCWND_UNIT" <<EOF || return 1
[Unit]
Description=NetFlow initcwnd/initrwnd on default route
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$INITCWND_SCRIPT
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now netflow-initcwnd.service >/dev/null 2>&1 &&
    systemctl is-enabled -q netflow-initcwnd.service 2>/dev/null
}

remove_initcwnd_persistence(){
  rm -f "$ROUTE_HOOK" "$INITCWND_SCRIPT" "$INITCWND_MARKER" "$INITCWND_VALS" 2>/dev/null || true
  systemctl disable --now netflow-initcwnd.service >/dev/null 2>&1 || true
  rm -f "$INITCWND_UNIT" 2>/dev/null || true
  local f
  for f in "$NETWORKD_DIR"/*.network.d/"$INITCWND_DROPIN_NAME"; do
    [ -e "$f" ] || continue
    rm -f "$f" 2>/dev/null || true
    rmdir "${f%/*}" 2>/dev/null || true
  done
}

persist_initcwnd(){
  local iface="$1" val="${2:-32}"
  remove_initcwnd_persistence
  mkdir -p "$STATE_DIR" && : > "$INITCWND_MARKER"
  printf 'initcwnd %s initrwnd %s\n' "$val" "$val" > "$INITCWND_VALS"
  if networkd_manages "$iface"; then
    write_networkd_dropin "$iface" "$val" "$val" && return 0
    if write_dispatcher_hook "$iface" "$val" && dispatcher_running; then return 0; fi
    rm -f "$ROUTE_HOOK"
  fi
  write_initcwnd_unit "$iface" "$val" && return 0
  return 1
}

# ── TC 队列管理与多队列 (mq) 保护 ───────────────────────────────────────────
qdisc_root_kind(){
  local out; out=$(tc qdisc show dev "$1" 2>/dev/null)
  awk '$1=="qdisc"{for(i=1;i<=NF;i++) if($i=="root"){print $2; exit}}' <<<"$out"
}

qdisc_remove_root(){
  local iface="$1" handle
  tc qdisc del dev "$iface" root 2>/dev/null && return 0
  if [ "$(qdisc_root_kind "$iface")" = mq ]; then
    tc qdisc replace dev "$iface" root handle 1: mq 2>/dev/null || return 1
    tc qdisc del dev "$iface" root 2>/dev/null
    return $?
  fi
  handle=$(tc qdisc show dev "$iface" 2>/dev/null | awk '$1=="qdisc"{for(i=1;i<=NF;i++) if($i=="root"){print $3; exit}}')
  [ "$handle" = "0:" ] && return 0
  return 1
}

qdisc_set_mq_leaves(){
  local iface="$1" kind="$2" out handle major parents p
  out=$(tc qdisc show dev "$iface" 2>/dev/null)
  handle=$(awk '$1=="qdisc" && $2=="mq"{for(i=1;i<=NF;i++) if($i=="root"){print $3; exit}}' <<<"$out")
  major=${handle%:}
  if [ -z "$major" ] || [ "$major" = 0 ]; then
    tc qdisc replace dev "$iface" root handle 1: mq 2>/dev/null || return 1
    out=$(tc qdisc show dev "$iface" 2>/dev/null)
    handle=$(awk '$1=="qdisc" && $2=="mq"{for(i=1;i<=NF;i++) if($i=="root"){print $3; exit}}' <<<"$out")
    major=${handle%:}
  fi
  [ -n "$major" ] || return 1
  parents=$(awk -v m="$major" '$1=="qdisc" && $0 ~ / parent /{
    for(i=1;i<=NF;i++) if($i=="parent"){
      p=$(i+1); if((m=="0" && (p ~ /^:/ || index(p,"0:")==1)) || (m!="0" && index(p,m ":")==1)) print p; break
    }}' <<<"$out")
  [ -n "$parents" ] || return 1
  for p in $parents; do
    tc qdisc replace dev "$iface" parent "$p" "$kind" 2>/dev/null || return 1
  done
}

qdisc_is_fq(){
  local out root handle major
  out=$(tc qdisc show dev "$1" 2>/dev/null)
  root=$(awk '$1=="qdisc"{for(i=1;i<=NF;i++) if($i=="root"){print $2; exit}}' <<<"$out")
  [ "$root" = fq ] && return 0
  [ "$root" = mq ] || return 1
  handle=$(awk '$1=="qdisc" && $2=="mq"{for(i=1;i<=NF;i++) if($i=="root"){print $3; exit}}' <<<"$out")
  major=${handle%:}
  [ -n "$major" ] || return 1
  awk -v m="$major" 'BEGIN{leaves=0; bad=0}
    $1=="qdisc" && $0 ~ / parent /{
      for(i=1;i<=NF;i++) if($i=="parent"){
        p=$(i+1)
        if((m=="0" && (p ~ /^:/ || index(p,"0:")==1)) || (m!="0" && index(p,m ":")==1)){
          leaves++; if($2!="fq") bad=1
        }
        break
      }
    }
    END{exit !(leaves>0 && bad==0)}' <<<"$out"
}

qdisc_set_fq(){
  local iface="$1" kind
  kind=$(qdisc_root_kind "$iface")
  case "$kind" in
    mq) qdisc_set_mq_leaves "$iface" fq || return 1 ;;
    fq) : ;;
    ""|noqueue) tc qdisc add dev "$iface" root fq 2>/dev/null || return 1 ;;
    *) qdisc_remove_root "$iface" || return 1
       kind=$(qdisc_root_kind "$iface")
       case "$kind" in
         mq) qdisc_set_mq_leaves "$iface" fq || return 1 ;;
         fq) : ;;
         *)  tc qdisc replace dev "$iface" root fq 2>/dev/null || return 1 ;;
       esac ;;
  esac
  qdisc_is_fq "$iface"
}

write_qdisc(){
  local rate="$1" iface="$2"
  mkdir -p "$(dirname "$QDISC_SCRIPT")"
  cat > "$QDISC_SCRIPT" <<EOF
#!/bin/bash
IF=\${NETFLOW_IF:-}
[ -n "\$IF" ] || IF=\$(ip -o -4 route show default 2>/dev/null | head -1 | awk '{for(i=1;i<NF;i++) if(\$i=="dev"){print \$(i+1); exit}}')
[ -n "\$IF" ] || IF=${iface}
RATE=\${1:-${rate}}
BURST=\$(awk -v r="\$RATE" 'BEGIN{v=r*500; if(v<32768)v=32768; printf "%d",v}')

if ! tc qdisc del dev \$IF root 2>/dev/null; then
  case "\$(tc qdisc show dev \$IF 2>/dev/null | head -1)" in
    *" mq "*) tc qdisc replace dev \$IF root handle 1: mq 2>/dev/null && tc qdisc del dev \$IF root 2>/dev/null ;;
  esac
fi

tc qdisc replace dev \$IF root handle 1: htb default 10 || exit 1
tc class replace dev \$IF parent 1: classid 1:10 htb rate \${RATE}mbit ceil \${RATE}mbit burst \${BURST} cburst \${BURST} quantum 1514 || exit 1
tc qdisc replace dev \$IF parent 1:10 handle 10: fq limit 40960 flow_limit 8192 maxrate \${RATE}mbit || exit 1
EOF
  chmod 755 "$QDISC_SCRIPT"
  cat > "$QDISC_UNIT" <<EOF
[Unit]
Description=NetFlow Egress Shaper (${rate} Mbps)
After=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$QDISC_SCRIPT $rate
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload >/dev/null 2>&1
  systemctl enable --now netflow-qdisc.service >/dev/null 2>&1
}

# ── 功能 1: 设定带宽与优化 (含 1000Mbps 智能分流) ───────────────────────────
apply_tuning(){
  local input_bw; input_bw=$(strip_zeros "$1")
  local iface ram
  iface=$(detect_iface); [ -n "$iface" ] || die "未检测到默认路由网卡"
  ram=$(detect_ram_mb)

  echo
  take_snapshot

  local bdp buf_max buf_def tcp_mem
  bdp=$(calc_bdp "$input_bw" "$FIXED_RTT")
  buf_max=$(calc_buf_max "$bdp" "$ram")
  buf_def=$(calc_buf_default "$FIXED_ROLE" "$bdp")
  tcp_mem=$(calc_tcp_mem "$ram")

  # 尊重现有 BBR 变种 (如 BBRv3)，否则加载 tcp_bbr 并持久化模块配置；若内核不支持则安全回退 cubic
  local cc avail_cc
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
  if [[ "$cc" != bbr* ]]; then
    modprobe tcp_bbr 2>/dev/null || true
    avail_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")
    if has_word "$avail_cc" bbr; then
      cc="bbr"
      mkdir -p "$(dirname "$BBR_MODULE_FILE")" 2>/dev/null || true
      echo tcp_bbr > "$BBR_MODULE_FILE" 2>/dev/null || true
    else
      warn "当前内核不支持 BBR，回退使用 cubic"
      cc="cubic"
    fi
  fi

  local _sc_tmp
  _sc_tmp=$(mktemp "${SYSCTL_FILE}.XXXXXX" 2>/dev/null) || die "无法创建临时配置文件"
  if ! cat > "$_sc_tmp" <<EOF
# Generated by NetFlow v$VERSION ($(date -u +%FT%TZ))
# Target=${input_bw}Mbps RTT=${FIXED_RTT}ms RAM=${ram}MB

net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = $cc

net.core.rmem_max = $buf_max
net.core.wmem_max = $buf_max
net.core.rmem_default = $buf_def
net.core.wmem_default = $buf_def
net.ipv4.tcp_rmem = 4096 $buf_def $buf_max
net.ipv4.tcp_wmem = 4096 $buf_def $buf_max
net.ipv4.tcp_mem = $tcp_mem

net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_adv_win_scale = 1

net.core.netdev_max_backlog = 16384
net.core.netdev_budget = 600
net.core.optmem_max = 65536
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192

net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_fastopen = 3

net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.ip_local_port_range = 1024 65535

vm.min_free_kbytes = 32768
fs.file-max = 1000000
# netflow-end
EOF
  then
    rm -f "$_sc_tmp"
    die "写入 $SYSCTL_FILE 失败 (磁盘已满或配额限制)"
  fi

  if ! tail -1 "$_sc_tmp" 2>/dev/null | grep -qx '# netflow-end'; then
    rm -f "$_sc_tmp"
    die "配置文件写入被截断，已中止"
  fi
  chmod 644 "$_sc_tmp" && mv -- "$_sc_tmp" "$SYSCTL_FILE" || {
    rm -f "$_sc_tmp"; die "配置文件落盘失败"
  }

  local _line _k _v _path
  while IFS= read -r _line; do
    case "$_line" in \#*|'') continue ;; *=*) ;; *) continue ;; esac
    _k=$(printf '%s' "${_line%%=*}" | tr -d ' \t')
    _v=$(printf '%s' "${_line#*=}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$_k" ] || continue
    _path="/proc/sys/$(printf '%s' "$_k" | tr '.' '/')"
    if [ ! -e "$_path" ] || ! sysctl -qw "$_k=$_v" 2>/dev/null; then
      sed -i "s%^[[:space:]]*${_k}[[:space:]]*=%# 内核不支持已注释: ${_k} =%" "$SYSCTL_FILE"
    fi
  done < "$SYSCTL_FILE"
  ok "已应用内核吞吐优化 (Max Buffer: $(human_bytes "$buf_max"))"

  # 路由首包窗口: >100M 开启 initcwnd 32; <=100M 保持默认 10 防打穿小水管令牌桶
  local _wif; _wif=$(route_field dev); [ -n "$_wif" ] || _wif="$iface"
  if [ "$input_bw" -gt 100 ]; then
    if route_set_initcwnd 32; then
      persist_initcwnd "$_wif" 32 || warn "initcwnd 仅本次生效，未找到可用的开机持久化入口"
      ok "已开启首包加速窗口 (initcwnd 32)"
    fi
  else
    remove_initcwnd_persistence
    route_restore_windows "$_wif" 2>/dev/null || true
    info "小带宽保护 (<=100 Mbps): 保持默认首包窗口防突发丢包"
  fi

  # 方案 B 智能分流：>= 1000 Mbps 自动切换纯 fq 释放多队列极限；< 1000 Mbps 启用 HTB 精准限速
  if [ "$input_bw" -ge "$SHAPE_MAX_BW" ]; then
    systemctl disable --now netflow-qdisc.service >/dev/null 2>&1 || true
    rm -f "$QDISC_UNIT" "$QDISC_SCRIPT"
    systemctl daemon-reload >/dev/null 2>&1 || true
    qdisc_set_fq "$iface" || warn "无法在 $iface 上启用 fq"
    ok "大带宽模式 (>=${SHAPE_MAX_BW} Mbps): 已挂载纯 fq 队列释放物理上限"
  else
    write_qdisc "$input_bw" "$iface"
    systemctl restart netflow-qdisc.service 2>/dev/null || "$QDISC_SCRIPT" "$input_bw"
    local applied
    applied=$(tc_rate_mbit "$(tc class show dev "$iface" 2>/dev/null)") || applied=""
    if [ -n "$applied" ] && awk -v a="$applied" -v r="$input_bw" 'BEGIN{exit !(a > r*0.99 && a < r*1.01)}' 2>/dev/null; then
      ok "已锁定端口速率上限 (${applied} Mbps)"
    else
      warn "端口限速下发异常，请检查网卡状态: tc qdisc show dev $iface"
    fi
  fi
}

# ── 功能 2: 还原出厂设置 ────────────────────────────────────────────────────
rollback_origin(){
  local iface; iface=$(detect_iface)
  echo
  rm -f "$SYSCTL_FILE" "$BBR_MODULE_FILE"
  remove_initcwnd_persistence
  systemctl disable --now netflow-qdisc.service >/dev/null 2>&1 || true
  rm -f "$QDISC_UNIT" "$QDISC_SCRIPT"
  systemctl daemon-reload >/dev/null 2>&1 || true

  if [ -f "$SNAPSHOT" ]; then
    local k v route snap_if snap_t snap_skip=0
    local -a snap_args=() snap_win=()
    while IFS='=' read -r k v; do
      k=$(echo "$k" | xargs); v=$(echo "$v" | xargs)
      [ -n "$k" ] && [ -n "$v" ] && sysctl -qw "$k=$v" 2>/dev/null || true
    done < <(grep -E '^(net|vm|fs)\.' "$SNAPSHOT")

    route=$(awk '/^# route: /{sub(/^# route: /, ""); print; exit}' "$SNAPSHOT")
    if [ -n "$route" ]; then
      snap_if=$(route_field dev "$route")
      read -r -a snap_args <<< "$route"
      for snap_t in "${snap_args[@]}"; do
        if [ "$snap_skip" = 1 ]; then snap_win+=("$snap_t"); snap_skip=0; continue; fi
        case "$snap_t" in initcwnd|initrwnd) snap_win+=("$snap_t"); snap_skip=1 ;; esac
      done
      route_restore_windows "$snap_if" "${snap_win[@]+"${snap_win[@]}"}" 2>/dev/null || true
    fi
    ok "已按出厂基线还原内核参数与路由"
  else
    sysctl --system >/dev/null 2>&1 || true
    route_restore_windows "$iface" 2>/dev/null || true
    warn "未找到出厂快照, 已移除配置并重载系统默认值"
  fi

  qdisc_remove_root "$iface" 2>/dev/null || true
  if [ "$(qdisc_root_kind "$iface")" = mq ]; then
    local def_qdisc
    def_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "fq_codel")
    qdisc_set_mq_leaves "$iface" "$def_qdisc" 2>/dev/null || true
  fi
  ok "已移除端口流控队列"
}

# ── 交互式主界面 (Apple 极简风) ─────────────────────────────────────────────
show_panel(){
  local iface ram cc rate buf target_bw status_str
  iface=$(detect_iface)
  ram=$(detect_ram_mb)
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
  rate=$(tc_rate_mbit "$(tc class show dev "$iface" 2>/dev/null)") || rate=""
  buf=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)

  if [ -f "$SYSCTL_FILE" ]; then
    target_bw=$(sed -n 's/^# Target=\([0-9]*\)Mbps.*/\1/p' "$SYSCTL_FILE" 2>/dev/null || echo "")
    if [ -n "$rate" ]; then
      status_str="${green}已优化 · 限速 ${rate} Mbps${plain} ${dim}(Buffer $(human_bytes "$buf"))${plain}"
    elif [ -n "$target_bw" ] && [ "$target_bw" -ge "$SHAPE_MAX_BW" ] 2>/dev/null; then
      status_str="${green}已优化 · 满速释放 (${target_bw} Mbps)${plain} ${dim}(Buffer $(human_bytes "$buf"))${plain}"
    else
      status_str="${yellow}已优化 · 限速未生效${plain} ${dim}(Buffer $(human_bytes "$buf"))${plain}"
    fi
  else
    status_str="${yellow}出厂默认${plain}"
  fi

  clear 2>/dev/null || true
  echo
  printf "  ${bold}NetFlow${plain}                              ${dim}v%s${plain}\n" "$VERSION"
  rule
  printf "  状态    %s\n" "$status_str"
  printf "  环境    %s MB · %s · %s\n" "$ram" "$cc" "$iface"
  rule
  echo
  printf "  ${bold}网络调控${plain}\n"
  printf "    1. 设定带宽与优化\n"
  printf "    2. 还原出厂设置\n"
  echo
  printf "  ${bold}系统工具${plain}\n"
  printf "    3. 配置内存压缩 (ZRAM)           ${dim}待添加${plain}\n"
  printf "    4. 系统清理与维护                ${dim}待添加${plain}\n"
  echo
  printf "    0. 退出\n"
  echo
  rule
}

menu_loop(){
  need_root
  if ! have_tty; then
    die "未检测到可交互的终端。非交互环境请直接带参数运行: netflow <带宽数字 | rollback>"
  fi
  take_lock
  self_install
  while true; do
    show_panel
    local choice=""
    read -rp "  选择 [0-4]: " choice 2>/dev/null </dev/tty || exit 0
    case "$choice" in
      1)
        echo
        local bw=""
        while true; do
          read -rp "  目标带宽 (Mbps): " bw 2>/dev/null </dev/tty || exit 0
          if is_posint "$bw" 1 100000; then
            apply_tuning "$bw"
            break
          fi
          warn "请输入正整数 (如 50、200；填 >=1000 自动启用纯 fq 满速模式)"
        done
        echo
        drain_tty
        read -rsn1 -p "  按任意键返回..." 2>/dev/null </dev/tty || true
        ;;
      2)
        rollback_origin
        echo
        drain_tty
        read -rsn1 -p "  按任意键返回..." 2>/dev/null </dev/tty || true
        ;;
      3|4)
        echo
        info "该模块预留中，后续可随时在 GitHub 仓库内扩展。"
        echo
        drain_tty
        read -rsn1 -p "  按任意键返回..." 2>/dev/null </dev/tty || true
        ;;
      0|"")
        echo
        drain_tty
        exit 0
        ;;
      *)
        ;;
    esac
  done
}

# 支持直接带参数静默执行，如: netflow 200 或 netflow rollback
if [ $# -gt 0 ]; then
  need_root
  take_lock
  self_install
  case "$1" in
    rollback|reset) rollback_origin ;;
    *)
      if is_posint "$1" 1 100000; then
        apply_tuning "$1"
      else
        die "用法: netflow [正整数带宽 | rollback]"
      fi
      ;;
  esac
else
  menu_loop
fi
