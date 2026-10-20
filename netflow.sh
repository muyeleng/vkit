#!/usr/bin/env bash
# NetFlow — 确定性 TCP 吞吐优化与流控工具
# 核心算法源自 tcpfit (v0.5.9) | 零测速依赖 · 固定 220ms 跨国 BDP 基准 · 1000Mbps 智能分流
#
# 快捷指令:
#   netflow                  唤出交互式主面板
#   netflow <正整数带宽>     直接设定目标带宽并优化 (如: netflow 300 或 netflow 1000)
#   netflow status           查看当前核心参数、出厂基线对比与系统健康度
#   netflow rollback         还原出厂设置并重置基线快照
#   netflow uninstall        彻底卸载 NetFlow (还原出厂 + 清理全部文件)
#   netflow help             显示此帮助指南

set -uo pipefail
umask 022

VERSION="1.7"
FIXED_RTT=220
FIXED_ROLE="proxy"
SHAPE_MAX_BW=1000

# GitHub Raw 直链：支持 bash <(curl ...) 运行时自动安装或更新 /usr/local/bin/netflow
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

# ── 视觉与排版 (Apple 极简风) ───────────────────────────────────────────────
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
rule(){ printf '  %s──────────────────────────────────────────────────────%s\n' "$dim" "$plain"; }

# CJK 中英文混合显示宽度计算 (确保双列对齐严丝合缝，不依赖 gawk)
_dispw(){
  printf '%s' "$1" | LC_ALL=C od -An -tu1 2>/dev/null | awk '
    {for(i=1;i<=NF;i++){b=$i
       if(b<128)            n++
       else if(b<192)       continue
       else if(b<224)       n++
       else if(b==226){ nx=$(i+1); if(nx==148||nx==149){ n++; i+=2; continue } n+=2 }
       else                 n+=2
    }} END{print n+0}'
}
kv(){
  local w; w=$(_dispw "$1")
  local pad=$(( 18 - w )); [ "$pad" -lt 1 ] && pad=1
  printf '  %s%s%*s%s%s\n' "$dim" "$1" "$pad" "" "$plain" "$2"
}

need_root(){ [ "$(id -u)" = 0 ] || die "请使用 root 权限运行"; }
have_tty(){ : 2>/dev/null </dev/tty; }

prompt_input(){
  local msg="$1" var=""
  printf '%s' "$msg" >&2
  read -r var 2>/dev/null </dev/tty || return 1
  printf '%s' "$var"
}

pause_return(){
  echo
  drain_tty
  printf "  %s按任意键返回主面板...%s" "$dim" "$plain" >&2
  read -rsn1 2>/dev/null </dev/tty || read -r 2>/dev/null </dev/tty || true
  echo
}

# 原生字符串匹配函数 (避免在 set -o pipefail 下使用 grep -q 引发 SIGPIPE 141 错误)
starts_with(){ case "$1" in "$2"*) return 0 ;; *) return 1 ;; esac; }
not_blank(){ case "$1" in *[!$'\n']*) return 0 ;; *) return 1 ;; esac; }
has_word(){
  case "$1" in
    "$2"|"$2"[!A-Za-z0-9_]*|*[!A-Za-z0-9_]"$2"|*[!A-Za-z0-9_]"$2"[!A-Za-z0-9_]*) return 0 ;;
    *) return 1 ;;
  esac
}
first_or(){
  local s="${1%%$'\n'*}"
  if [ -n "$s" ]; then printf '%s' "$s"; else printf '%s' "$2"; fi
}

take_lock(){
  command -v flock >/dev/null 2>&1 || return 0
  mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || return 0
  [ -w "$(dirname "$LOCK_FILE")" ] || return 0
  [ "${LOCK_HELD:-0}" = 1 ] && return 0
  exec 9>"$LOCK_FILE" || return 0
  flock -n 9 && { LOCK_HELD=1; return 0; }
  die "另一个 NetFlow 实例正在运行 (锁: $LOCK_FILE)"
}

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

self_install(){
  [ "$(id -u)" = 0 ] || return 0
  case "$0" in "$SELF_PATH") return 0 ;; esac
  if [ -f "$0" ] && [ -r "$0" ]; then
    cp -f "$0" "$SELF_PATH" 2>/dev/null && chmod 755 "$SELF_PATH" 2>/dev/null || true
  elif [ -n "$SELF_RAW_URL" ] && command -v curl >/dev/null 2>&1; then
    local inst_ver=""
    [ -f "$SELF_PATH" ] && inst_ver=$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$SELF_PATH" 2>/dev/null || echo "")
    if [ "$inst_ver" != "$VERSION" ]; then
      if curl -fsSL --max-time 10 "$SELF_RAW_URL" -o "${SELF_PATH}.tmp" 2>/dev/null &&
         [ -s "${SELF_PATH}.tmp" ] &&
         starts_with "$(head -n 1 "${SELF_PATH}.tmp" 2>/dev/null)" '#!'; then
        mv -f "${SELF_PATH}.tmp" "$SELF_PATH" && chmod 755 "$SELF_PATH"
      else
        rm -f "${SELF_PATH}.tmp"
      fi
    fi
  fi
}

# ── 帮助说明 (netflow help) ─────────────────────────────────────────────────
usage_help(){
  echo
  printf "  ${bold}NetFlow${plain} — 确定性 TCP 吞吐优化与流控工具              ${dim}v%s${plain}\n" "$VERSION"
  rule
  printf "  ${bold}交互面板${plain}\n"
  kv "netflow"          "唤出交互式主面板 (推荐日常使用)"
  echo
  printf "  ${bold}无交互快捷指令${plain}\n"
  kv "netflow <Mbps>"   "按指定带宽计算内存并配置流控 (如: netflow 300)"
  kv ""                 "${dim}· 输入 < 1000  : 开启 HTB 精准限速 + fq 平滑发包${plain}"
  kv ""                 "${dim}· 输入 >= 1000 : 挂载纯 fq 队列释放多核物理满速${plain}"
  kv "netflow status"   "查看当前核心参数、出厂基线对比与系统健康度"
  kv "netflow rollback" "一键还原至出厂默认设置，并重置基线快照"
  kv "netflow uninstall" "彻底卸载 NetFlow (还原出厂 + 清理全部残留文件)"
  kv "netflow help"     "显示本帮助说明 (别名: -h, --help)"
  rule
  echo
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

# 原版推导原因解释函数：说明缓冲区上限是由 2×BDP 决定，还是被物理内存安全预算 (RAM/32) 封顶
buf_max_reason(){
  awk -v b="$1" -v m="$2" -v v="$3" 'BEGIN{
    target = b*2 + 2097152
    cap = m*32768; if(cap > 268435456) cap = 268435456
    if(v <= 4194304 && target < 4194304) { print "触发 4MB 保底下限"; exit }
    if(v >= cap && target > cap)         { print "受 RAM/32 内存安全上限封顶"; exit }
    print "2×BDP + 2MB 余量"
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

snap_val(){
  [ -f "$SNAPSHOT" ] || return 1
  awk -F'=' -v k="$1" '
    $1 ~ "^[[:space:]]*"k"[[:space:]]*$" {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      print $2; exit
    }' "$SNAPSHOT"
}

take_snapshot(){
  mkdir -p "$STATE_DIR"
  # 已有快照则保留最早那一份出厂状态 (与原版一致，提示用户快照已锁定)
  if [ -f "$SNAPSHOT" ]; then
    info "出厂快照已存在，继续保留最早的纯净基线 ($SNAPSHOT)"
    return 0
  fi
  if [ -f "$SYSCTL_FILE" ] || [ -f "$QDISC_SCRIPT" ]; then
    warn "检测到已有调优配置但缺少出厂快照，正在先还原系统默认值以提取纯净基线..."
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
  ok "已建立出厂基线快照: $SNAPSHOT"
}

# ── 路由首包窗口 (initcwnd) 与持久化 (含原版路径追踪) ───────────────────────
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
  local line t skip rc=0 touched=0 now
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
  now=$(ip -4 route show default 2>/dev/null)
  if [ -n "$iface" ]; then
    now=$(printf '%s\n' "$now" | awk -v d="$iface" '{for(i=1;i<NF;i++) if($i=="dev" && $(i+1)==d){print; next}}')
  fi
  if [ "${#want[@]}" = 0 ]; then
    case "$now" in *initcwnd*|*initrwnd*) rc=1 ;; esac
  else
    case "$now" in *"${want[*]}"*) ;; *) rc=1 ;; esac
  fi
  return "$rc"
}

networkd_manages(){
  [ -n "${1:-}" ] || return 1
  command -v networkctl >/dev/null 2>&1 || return 1
  systemctl is-active -q systemd-networkd 2>/dev/null || return 1
  local st; st=$(networkctl status "$1" 2>/dev/null) || return 1
  grep -Eq 'State: [a-z-]+ \((configured|configuring)' <<< "$st"
}

INITCWND_DROPIN_PATH=""
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
  INITCWND_DROPIN_PATH="$dir/$INITCWND_DROPIN_NAME"
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

INITCWND_VIA=""
persist_initcwnd(){
  local iface="$1" val="${2:-32}"
  INITCWND_VIA=""
  remove_initcwnd_persistence
  mkdir -p "$STATE_DIR" && : > "$INITCWND_MARKER"
  printf 'initcwnd %s initrwnd %s\n' "$val" "$val" > "$INITCWND_VALS"
  if networkd_manages "$iface"; then
    if write_networkd_dropin "$iface" "$val" "$val"; then
      INITCWND_VIA="systemd-networkd 配置 ($INITCWND_DROPIN_PATH)"
      return 0
    fi
    if write_dispatcher_hook "$iface" "$val" && dispatcher_running; then
      INITCWND_VIA="networkd-dispatcher 钩子"
      return 0
    fi
    rm -f "$ROUTE_HOOK"
  fi
  if write_initcwnd_unit "$iface" "$val"; then
    INITCWND_VIA="netflow-initcwnd.service (开机自启单元)"
    return 0
  fi
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

# ── 功能 2: 查看状态与出厂基线对比 ──────────────────────────────────────────
show_status(){
  local iface ram; iface=$(detect_iface); ram=$(detect_ram_mb)
  local cc def_q act_q shaper rmem_max rmem_def tmem backlog cwnd svc_state
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
  def_q=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
  act_q=$(qdisc_root_kind "$iface"); [ -n "$act_q" ] || act_q="none"
  shaper=$(tc_rate_mbit "$(tc class show dev "$iface" 2>/dev/null)") || shaper=""
  rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
  rmem_def=$(sysctl -n net.core.rmem_default 2>/dev/null || echo 0)
  tmem=$(sysctl -n net.ipv4.tcp_mem 2>/dev/null | awk '{printf "%.0fM / %.0fM / %.0fM", $1*4/1024,$2*4/1024,$3*4/1024}')
  backlog=$(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo "?")
  cwnd=$(ip -4 route show default 2>/dev/null | grep -oE 'initcwnd [0-9]+' | awk '{print $2}')
  svc_state=$(systemctl is-enabled netflow-qdisc.service 2>/dev/null || echo "未安装")

  local orig_cc="" orig_rmem="" orig_tmem="" orig_backlog=""
  if [ -f "$SNAPSHOT" ]; then
    orig_cc=$(snap_val "net.ipv4.tcp_congestion_control")
    local _orm; _orm=$(snap_val "net.core.rmem_max")
    [ -n "$_orm" ] && orig_rmem=$(human_bytes "$_orm")
    local _otm; _otm=$(snap_val "net.ipv4.tcp_mem")
    [ -n "$_otm" ] && orig_tmem=$(echo "$_otm" | awk '{printf "%.0fM / %.0fM / %.0fM", $1*4/1024,$2*4/1024,$3*4/1024}')
    orig_backlog=$(snap_val "net.core.netdev_max_backlog")
  fi

  local target_bw="" buf_note=""
  if [ -f "$SYSCTL_FILE" ]; then
    target_bw=$(sed -n 's/^# Target=\([0-9]*\)Mbps.*/\1/p' "$SYSCTL_FILE" 2>/dev/null || echo "")
    if [ -n "$target_bw" ]; then
      local _bdp; _bdp=$(calc_bdp "$target_bw" "$FIXED_RTT")
      buf_note=" · $(buf_max_reason "$_bdp" "$ram" "$rmem_max")"
    fi
  fi

  echo
  printf "  %s当前参数与出厂对比%s\n" "$bold" "$plain"
  rule
  kv "内核版本"      "$(uname -r)"
  kv "拥塞控制"      "${cc}${orig_cc:+  ${dim}(出厂: ${orig_cc})${plain}}"
  kv "队列调度"      "当前 ${act_q} / 默认 ${def_q}"
  if [ -n "$shaper" ]; then
    local burst_kb; burst_kb=$(awk -v r="$shaper" 'BEGIN{v=r*500; if(v<32768)v=32768; printf "%.0f KB", v/1024}')
    kv "端口限速"    "${green}${shaper} Mbps${plain}  ${dim}(HTB burst ${burst_kb} · 服务 ${svc_state})${plain}"
  else
    if [ -n "$target_bw" ] && [ "$target_bw" -ge "$SHAPE_MAX_BW" ] 2>/dev/null; then
      kv "端口限速"  "${green}无限制 · 纯 fq 满速释放${plain}  ${dim}(按 ${target_bw} Mbps 调优)${plain}"
    else
      kv "端口限速"  "未启用"
    fi
  fi
  kv "最大缓冲区"    "$(human_bytes "$rmem_max")  ${dim}(默认 $(human_bytes "$rmem_def")${buf_note}${orig_rmem:+ · 出厂: ${orig_rmem}})${plain}"
  kv "全局 TCP 内存" "${tmem}  ${dim}(RAM 1/16, 1/8, 1/4${orig_tmem:+ · 出厂: ${orig_tmem}})${plain}"
  kv "网卡队列上限"  "${backlog}${orig_backlog:+  ${dim}(出厂: ${orig_backlog})${plain}}"
  kv "首包窗口"      "${cwnd:-10 (系统默认)}"
  kv "出厂快照"      "$([ -f "$SNAPSHOT" ] && echo "${green}已锁定${plain} ${dim}($SNAPSHOT)${plain}" || echo "${yellow}尚未生成 (首次调优时自动建立)${plain}")"

  echo
  printf "  %s系统健康度 (Health)%s\n" "$bold" "$plain"
  rule
  local snmp rt drops oom_cnt
  snmp=$(awk '/^Tcp: [0-9]/{print $12, $13}' /proc/net/snmp 2>/dev/null || echo "")
  rt=$(echo "$snmp" | awk '{if($1>0) printf "%.3f%%", $2*100/$1; else print "n/a"}')
  drops=$(tc -s class show dev "$iface" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i~/^dropped$/){gsub(/[^0-9]/,"",$(i+1)); print $(i+1); exit}}')
  oom_cnt=$(journalctl --since '-1 hour' 2>/dev/null | grep -c 'oom-kill' || true)

  kv "累计重传率"    "${rt}  ${dim}(开机至今累计)${plain}"
  kv "限速队列丢包"  "${drops:-0}"
  kv "物理内存"      "$(free -m | awk '/Mem:/{printf "已用 %s MB / 可用 %s MB / 共 %s MB", $3, $7, $2}')"
  kv "虚拟内存 Swap" "$(free -m | awk '/Swap:/{if($2==0) print "未开启 (小内存机器建议开启)"; else printf "已用 %s MB / 共 %s MB", $3, $2}')"
  kv "近 1 小时 OOM" "${oom_cnt:-0} 次"
  rule
}

# ── 功能 1: 设定带宽与优化 (完整保留原版 tcpfit 诊断提示) ──────────────────
apply_tuning(){
  local input_bw; input_bw=$(strip_zeros "$1")
  local iface ram
  iface=$(detect_iface); [ -n "$iface" ] || die "未检测到默认路由网卡"
  ram=$(detect_ram_mb)

  echo
  take_snapshot

  local bdp buf_max buf_def tcp_mem bdp_mb reason_str tmem_str
  bdp=$(calc_bdp "$input_bw" "$FIXED_RTT")
  buf_max=$(calc_buf_max "$bdp" "$ram")
  buf_def=$(calc_buf_default "$FIXED_ROLE" "$bdp")
  tcp_mem=$(calc_tcp_mem "$ram")
  bdp_mb=$(awk -v v="$bdp" 'BEGIN{printf "%.1f MB", v/1048576}')
  reason_str=$(buf_max_reason "$bdp" "$ram" "$buf_max")
  tmem_str=$(echo "$tcp_mem" | awk '{printf "%.0fM / %.0fM / %.0fM", $1*4/1024, $2*4/1024, $3*4/1024}')

  # 原版推导过程展示：清晰交代 BDP、缓冲区上限原因 (是否触发 RAM/32 封顶) 与全局内存池
  info "参数推导基准: 带宽 ${input_bw} Mbps / 延迟 ${FIXED_RTT} ms / 内存 ${ram} MB / 角色 ${FIXED_ROLE}"
  printf "    %s· 理论 BDP      : %s%s\n" "$dim" "$bdp_mb" "$plain"
  printf "    %s· 最大缓冲区    : %s (%s)%s\n" "$dim" "$(human_bytes "$buf_max")" "$reason_str" "$plain"
  printf "    %s· 全局 TCP 内存 : %s (物理内存的 1/16, 1/8, 1/4)%s\n" "$dim" "$tmem_str" "$plain"

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
      warn "当前内核不支持 BBR，回退使用 cubic (跨国吞吐增益将显著受限)"
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

  if [ "$(tail -n 1 "$_sc_tmp" 2>/dev/null)" != "# netflow-end" ]; then
    rm -f "$_sc_tmp"
    die "配置文件写入被截断，已中止"
  fi
  chmod 644 "$_sc_tmp" && mv -- "$_sc_tmp" "$SYSCTL_FILE" || {
    rm -f "$_sc_tmp"; die "配置文件落盘失败"
  }

  # 原版内核参数逐项校验：将本机内核拒绝的项自动注释并打印明确提示，加深对当前服务器内核的认识
  local _bad=0 _line _k _v _path
  while IFS= read -r _line; do
    case "$_line" in \#*|'') continue ;; *=*) ;; *) continue ;; esac
    _k=$(printf '%s' "${_line%%=*}" | tr -d ' \t')
    _v=$(printf '%s' "${_line#*=}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$_k" ] || continue
    _path="/proc/sys/$(printf '%s' "$_k" | tr '.' '/')"
    if [ ! -e "$_path" ] || ! sysctl -qw "$_k=$_v" 2>/dev/null; then
      sed -i "s%^[[:space:]]*${_k}[[:space:]]*=%# 本内核不支持, 自动注释: ${_k} =%" "$SYSCTL_FILE"
      warn "  内核不接受 ${_k} = ${_v} —— 已在配置中自动注释跳过"
      _bad=$(( _bad + 1 ))
    fi
  done < "$SYSCTL_FILE"

  if [ "$_bad" -gt 0 ]; then
    ok "内核参数已应用: $SYSCTL_FILE (${_bad} 项被本内核拒绝已注释，不影响其余调优)"
  else
    ok "内核参数已全部应用: $SYSCTL_FILE"
  fi

  # 原版首包窗口 (initcwnd) 诊断与持久化路径反馈
  local _wif; _wif=$(route_field dev); [ -n "$_wif" ] || _wif="$iface"
  if [ "$input_bw" -gt 100 ]; then
    if route_set_initcwnd 32; then
      ok "已开启首包加速窗口 (initcwnd / initrwnd = 32)"
      if persist_initcwnd "$_wif" 32; then
        info "initcwnd 开机持久化: ${INITCWND_VIA}"
      else
        warn "initcwnd 仅在本次生效，重启后会丢失 —— 本机没有可用的持久化入口"
        printf "    %s注意: sysctl (BBR/缓冲区) 和端口限速是持久的，仅路由首包窗口这一项重启后恢复默认。%s\n" "$dim" "$plain"
      fi
    else
      if [ -z "$(ip -4 route show default 2>/dev/null)" ]; then
        warn "initcwnd 未设置: 主路由表里没有默认路由 (可能使用了策略路由或双 /1 路由)"
      else
        warn "initcwnd 未生效: 当前虚拟化架构不支持修改路由窗口"
      fi
    fi
  else
    remove_initcwnd_persistence
    route_restore_windows "$_wif" 2>/dev/null || true
    info "小带宽保护 (<=100 Mbps): 保持内核默认首包窗口 (10)，防止首轮突发打穿小水管令牌桶"
  fi

  # 方案 B 智能分流：>= 1000 Mbps 自动切换纯 fq 释放多队列极限；< 1000 Mbps 启用 HTB 精准限速
  if [ "$input_bw" -ge "$SHAPE_MAX_BW" ]; then
    systemctl disable --now netflow-qdisc.service >/dev/null 2>&1 || true
    rm -f "$QDISC_UNIT" "$QDISC_SCRIPT"
    systemctl daemon-reload >/dev/null 2>&1 || true
    qdisc_set_fq "$iface" || warn "无法在 $iface 上启用 fq"
    ok "大带宽模式 (>=${SHAPE_MAX_BW} Mbps): 已挂载纯 fq 队列释放多核物理上限 (BBR 逐连接 pacing 仍生效)"
  else
    write_qdisc "$input_bw" "$iface"
    systemctl restart netflow-qdisc.service 2>/dev/null || "$QDISC_SCRIPT" "$input_bw"
    local applied
    applied=$(tc_rate_mbit "$(tc class show dev "$iface" 2>/dev/null)") || applied=""
    if [ -n "$applied" ] && awk -v a="$applied" -v r="$input_bw" 'BEGIN{exit !(a > r*0.99 && a < r*1.01)}' 2>/dev/null; then
      ok "已锁定端口速率上限: HTB ${applied} Mbps + fq leaf pacing (网卡 ${iface})"
    else
      warn "端口限速在 ${iface} 上未生效 —— 请检查: tc qdisc show dev ${iface}"
    fi
    if systemctl is-enabled netflow-qdisc.service >/dev/null 2>&1; then
      ok "netflow-qdisc.service 开机自启已启用 (重启后持久生效)"
    else
      warn "netflow-qdisc.service 未能启用 —— 端口限速在重启后会丢失"
    fi
  fi

  # 原版小内存无 Swap 安全提醒
  if [ "$ram" -le 1024 ] && ! not_blank "$(swapon --show 2>/dev/null)"; then
    echo
    warn "本机物理内存仅 ${ram} MB 且未开启 Swap/ZRAM，高负载下建议配置 ZRAM 或 Swap 防进程被杀"
  fi

  show_status
}

# ── 功能 3: 还原出厂设置 (含快照安全销毁闭环) ───────────────────────────────
rollback_origin(){
  local quiet="${1:-0}"
  local iface failed=0; iface=$(detect_iface)
  echo
  rm -f "$SYSCTL_FILE" "$BBR_MODULE_FILE" || failed=1
  remove_initcwnd_persistence
  systemctl disable --now netflow-qdisc.service >/dev/null 2>&1 || true
  rm -f "$QDISC_UNIT" "$QDISC_SCRIPT" || failed=1
  systemctl daemon-reload >/dev/null 2>&1 || true

  if [ -f "$SNAPSHOT" ]; then
    local k v route snap_if snap_t snap_skip=0
    local -a snap_args=() snap_win=()
    while IFS='=' read -r k v; do
      k=$(echo "$k" | xargs); v=$(echo "$v" | xargs)
      [ -n "$k" ] && [ -n "$v" ] || continue
      if ! sysctl -qw "$k=$v" 2>/dev/null; then
        warn "参数还原失败: $k"
        failed=1
      fi
    done < <(grep -E '^(net|vm|fs)\.' "$SNAPSHOT")

    route=$(awk '/^# route: /{sub(/^# route: /, ""); print; exit}' "$SNAPSHOT")
    if [ -n "$route" ]; then
      snap_if=$(route_field dev "$route")
      read -r -a snap_args <<< "$route"
      for snap_t in "${snap_args[@]}"; do
        if [ "$snap_skip" = 1 ]; then snap_win+=("$snap_t"); snap_skip=0; continue; fi
        case "$snap_t" in initcwnd|initrwnd) snap_win+=("$snap_t"); snap_skip=1 ;; esac
      done
      if ! route_restore_windows "$snap_if" "${snap_win[@]+"${snap_win[@]}"}" 2>/dev/null; then
        warn "默认路由窗口未完全还原"
        failed=1
      fi
    fi
    if [ "$failed" = 0 ]; then
      rm -f "$SNAPSHOT" 2>/dev/null || true
      ok "已按出厂基线还原全部参数，并重置基线快照"
    else
      warn "部分参数还原异常，已保留出厂快照 ($SNAPSHOT) 供重试"
    fi
  else
    sysctl --system >/dev/null 2>&1 || true
    route_restore_windows "$iface" 2>/dev/null || true
    warn "未找到出厂快照, 已移除调优文件并重载系统默认值"
  fi

  qdisc_remove_root "$iface" 2>/dev/null || true
  if [ "$(qdisc_root_kind "$iface")" = mq ]; then
    local def_qdisc
    def_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "fq_codel")
    qdisc_set_mq_leaves "$iface" "$def_qdisc" 2>/dev/null || true
  fi
  ok "已移除端口流控队列，恢复出厂状态"
  [ "$quiet" = 1 ] || show_status
}

# ── 隐藏式 CLI 彻底卸载功能 (netflow uninstall) ─────────────────────────────
uninstall_self(){
  rollback_origin 1
  rm -rf "$STATE_DIR" "$LOCK_FILE" "$SELF_PATH" 2>/dev/null || true
  ok "NetFlow 已彻底卸载，所有配置与快捷命令已清除"
  echo
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
    status_str="${yellow}出厂默认${plain} ${dim}(Buffer $(human_bytes "$buf"))${plain}"
  fi

  clear 2>/dev/null || true
  echo
  printf "  ${bold}NetFlow${plain}                                           ${dim}v%s${plain}\n" "$VERSION"
  rule
  printf "  状态    %s\n" "$status_str"
  printf "  环境    %s MB · %s · %s · %s\n" "$ram" "$cc" "$iface" "$(uname -r)"
  rule
  echo
  printf "  ${bold}网络调控${plain}\n"
  printf "    1. 设定带宽与优化\n"
  printf "    2. 查看状态与基线对比\n"
  printf "    3. 还原出厂设置\n"
  echo
  printf "  ${bold}系统工具${plain}\n"
  printf "    4. 配置内存压缩 (ZRAM)                        ${dim}待添加${plain}\n"
  printf "    5. 系统清理与维护                             ${dim}待添加${plain}\n"
  echo
  printf "    0. 退出                              ${dim}命令行: netflow help${plain}\n"
  echo
  rule
}

menu_loop(){
  need_root
  if ! have_tty; then
    die "未检测到可交互的终端。非交互环境请运行: netflow help 查看指令"
  fi
  take_lock
  self_install
  while true; do
    show_panel
    local choice=""
    choice=$(prompt_input "  请选择 [0-5]: ") || exit 0
    case "$choice" in
      1)
        echo
        if [ ! -f "$SNAPSHOT" ]; then
          info "首次运行：将在 $SNAPSHOT 建立出厂基线备份"
          printf "    %s后续调整带宽仅覆盖优化参数，出厂备份永久保留，随时可一键还原。%s\n\n" "$dim" "$plain"
        fi
        printf "  %s提示：输入 <1000 开启 HTB 精准限速；输入 >=1000 挂载纯 fq 满速释放 (直接回车取消)%s\n" "$dim" "$plain"
        local bw=""
        while true; do
          bw=$(prompt_input "  目标带宽 (Mbps): ") || exit 0
          [ -z "$bw" ] && break
          if is_posint "$bw" 1 100000; then
            apply_tuning "$bw"
            pause_return
            break
          fi
          warn "请输入 1 ~ 100000 之间的正整数 (如 200、500、1000)"
        done
        ;;
      2)
        show_status
        pause_return
        ;;
      3)
        echo
        local ans=""
        ans=$(prompt_input "  确认还原至出厂默认状态？[y/N]: ") || exit 0
        if [[ "$ans" =~ ^[Yy]$ ]]; then
          rollback_origin
          pause_return
        fi
        ;;
      4|5)
        echo
        info "该模块预留中，后续可随时在 GitHub 仓库内扩展。"
        pause_return
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

# 支持本地二次快速调参: netflow 300 | netflow status | netflow rollback | netflow uninstall | netflow help
if [ $# -gt 0 ]; then
  case "$1" in
    -h|--help|help)
      usage_help
      exit 0
      ;;
  esac
  need_root
  take_lock
  case "$1" in
    status|st)        self_install; show_status ;;
    rollback|reset)   self_install; rollback_origin ;;
    uninstall|remove) uninstall_self ;;
    *)
      if is_posint "$1" 1 100000; then
        self_install
        apply_tuning "$1"
      else
        warn "未知指令或无效带宽: $1"
        usage_help
        exit 1
      fi
      ;;
  esac
else
  menu_loop
fi
