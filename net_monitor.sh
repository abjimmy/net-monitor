#!/usr/bin/env bash
set -euo pipefail

# 实时监控 IP 网卡与 RDMA(IB/RoCEv2) 网卡速率与累积流量。
# 尽量只依赖基础 Linux 能力: /proc, /sys, awk, sed, date, sleep.

INTERVAL="${INTERVAL:-1}"
SHOW_LOOPBACK="${SHOW_LOOPBACK:-0}"
RDMA_WORD_BYTES="${RDMA_WORD_BYTES:-4}"

usage() {
  cat <<'USAGE'
用法:
  ./net_monitor.sh [interval_seconds]

环境变量:
  INTERVAL         刷新周期(秒)，默认 1
  SHOW_LOOPBACK    是否显示 lo 网卡: 1 显示, 0 不显示(默认)
  RDMA_WORD_BYTES  RDMA port_*_data 计数单位字节数，默认 4

说明:
  - IP 网卡数据来源: /proc/net/dev (单位: 字节)
  - RDMA 数据优先来源: /sys/class/infiniband/*/ports/*/hw_counters/{rx_bytes,tx_bytes}
  - 若 hw_counters 不存在，则回退到 counters/port_{rcv,xmit}_data，按 RDMA_WORD_BYTES 换算字节
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ge 1 ]]; then
  INTERVAL="$1"
fi

if ! awk "BEGIN{exit !($INTERVAL>0)}"; then
  echo "错误: interval 必须是正数" >&2
  exit 1
fi

fmt_bytes() {
  local b="$1"
  awk -v b="$b" 'BEGIN {
    split("B KiB MiB GiB TiB PiB", u, " ");
    i=1;
    while (b >= 1024 && i < 6) { b/=1024; i++; }
    if (i == 1) printf "%.0f %s", b, u[i];
    else printf "%.2f %s", b, u[i];
  }'
}

fmt_rate() {
  local bytes_delta="$1"
  local sec="$2"
  awk -v d="$bytes_delta" -v s="$sec" 'BEGIN {
    split("B/s KiB/s MiB/s GiB/s TiB/s", u, " ");
    r=d/s; i=1;
    while (r >= 1024 && i < 5) { r/=1024; i++; }
    if (i == 1) printf "%.0f %s", r, u[i];
    else printf "%.2f %s", r, u[i];
  }'
}

read_ip_stats() {
  awk -v show_lo="$SHOW_LOOPBACK" 'NR>2 {
    gsub(":", "", $1);
    iface=$1;
    if (!show_lo && iface=="lo") next;
    rx=$2; tx=$10;
    print iface "|" rx "|" tx;
  }' /proc/net/dev
}

rdma_lines_for_device_port() {
  local dev="$1"
  local port="$2"
  local base="/sys/class/infiniband/$dev/ports/$port"

  local rx tx mode
  if [[ -r "$base/hw_counters/rx_bytes" && -r "$base/hw_counters/tx_bytes" ]]; then
    rx="$(<"$base/hw_counters/rx_bytes")"
    tx="$(<"$base/hw_counters/tx_bytes")"
    mode="bytes"
  elif [[ -r "$base/counters/port_rcv_data" && -r "$base/counters/port_xmit_data" ]]; then
    local rxw txw
    rxw="$(<"$base/counters/port_rcv_data")"
    txw="$(<"$base/counters/port_xmit_data")"
    rx="$((rxw * RDMA_WORD_BYTES))"
    tx="$((txw * RDMA_WORD_BYTES))"
    mode="words"
  else
    return 0
  fi

  local nets=""
  if [[ -d "/sys/class/infiniband/$dev/device/net" ]]; then
    nets="$(ls "/sys/class/infiniband/$dev/device/net" 2>/dev/null | sed ':a;N;$!ba;s/\n/,/g')"
  fi
  [[ -z "$nets" ]] && nets="-"

  echo "$dev/$port|$nets|$rx|$tx|$mode"
}

read_rdma_stats() {
  local ibroot="/sys/class/infiniband"
  [[ -d "$ibroot" ]] || return 0

  local dev portdir port
  for devpath in "$ibroot"/*; do
    [[ -d "$devpath" ]] || continue
    dev="$(basename "$devpath")"
    for portdir in "$devpath"/ports/*; do
      [[ -d "$portdir" ]] || continue
      port="$(basename "$portdir")"
      rdma_lines_for_device_port "$dev" "$port"
    done
  done
}

# baseline

declare -A ip_prev_rx ip_prev_tx ip_base_rx ip_base_tx
declare -A rd_prev_rx rd_prev_tx rd_base_rx rd_base_tx rd_mode rd_netdev

while IFS='|' read -r k rx tx; do
  ip_prev_rx["$k"]="$rx"
  ip_prev_tx["$k"]="$tx"
  ip_base_rx["$k"]="$rx"
  ip_base_tx["$k"]="$tx"
done < <(read_ip_stats)

while IFS='|' read -r k net rx tx mode; do
  [[ -n "${k:-}" ]] || continue
  rd_prev_rx["$k"]="$rx"
  rd_prev_tx["$k"]="$tx"
  rd_base_rx["$k"]="$rx"
  rd_base_tx["$k"]="$tx"
  rd_mode["$k"]="$mode"
  rd_netdev["$k"]="$net"
done < <(read_rdma_stats)

print_header() {
  if [[ -t 1 ]]; then clear; else printf "\033c"; fi 2>/dev/null || true
  echo "实时网络监控  时间: $(date '+%F %T %Z')  间隔: ${INTERVAL}s"
  echo
  echo "[IP 网卡]"
  printf "%-14s %-14s %-14s %-14s %-14s\n" "IFACE" "RX速率" "TX速率" "RX累计(启动后)" "TX累计(启动后)"
  printf "%-14s %-14s %-14s %-14s %-14s\n" "--------------" "--------------" "--------------" "--------------" "--------------"
}

print_rdma_header() {
  echo
  echo "[RDMA 端口]"
  printf "%-16s %-14s %-14s %-14s %-14s %-10s %-10s\n" "DEV/PORT" "关联NETDEV" "RX速率" "TX速率" "RX累计" "TX累计" "源"
  printf "%-16s %-14s %-14s %-14s %-14s %-10s %-10s\n" "----------------" "--------------" "--------------" "--------------" "--------------" "----------" "----------"
}

loop() {
  while true; do
    sleep "$INTERVAL"

    declare -A ip_cur_rx=() ip_cur_tx=()
    declare -A rd_cur_rx=() rd_cur_tx=() rd_cur_mode=() rd_cur_net=()

    while IFS='|' read -r k rx tx; do
      ip_cur_rx["$k"]="$rx"
      ip_cur_tx["$k"]="$tx"
      [[ -n "${ip_base_rx[$k]+x}" ]] || ip_base_rx["$k"]="$rx"
      [[ -n "${ip_base_tx[$k]+x}" ]] || ip_base_tx["$k"]="$tx"
    done < <(read_ip_stats)

    while IFS='|' read -r k net rx tx mode; do
      [[ -n "${k:-}" ]] || continue
      rd_cur_rx["$k"]="$rx"
      rd_cur_tx["$k"]="$tx"
      rd_cur_mode["$k"]="$mode"
      rd_cur_net["$k"]="$net"
      [[ -n "${rd_base_rx[$k]+x}" ]] || rd_base_rx["$k"]="$rx"
      [[ -n "${rd_base_tx[$k]+x}" ]] || rd_base_tx["$k"]="$tx"
    done < <(read_rdma_stats)

    print_header
    while IFS= read -r k; do
      local prev_rx="${ip_prev_rx[$k]:-${ip_cur_rx[$k]}}"
      local prev_tx="${ip_prev_tx[$k]:-${ip_cur_tx[$k]}}"
      local drx=$(( ip_cur_rx[$k] - prev_rx ))
      local dtx=$(( ip_cur_tx[$k] - prev_tx ))
      ((drx < 0)) && drx=0
      ((dtx < 0)) && dtx=0

      local trx=$(( ip_cur_rx[$k] - ip_base_rx[$k] ))
      local ttx=$(( ip_cur_tx[$k] - ip_base_tx[$k] ))
      ((trx < 0)) && trx=0
      ((ttx < 0)) && ttx=0

      printf "%-14s %-14s %-14s %-14s %-14s\n" \
        "$k" "$(fmt_rate "$drx" "$INTERVAL")" "$(fmt_rate "$dtx" "$INTERVAL")" \
        "$(fmt_bytes "$trx")" "$(fmt_bytes "$ttx")"

      ip_prev_rx["$k"]="${ip_cur_rx[$k]}"
      ip_prev_tx["$k"]="${ip_cur_tx[$k]}"
    done < <(printf '%s\n' "${!ip_cur_rx[@]}" | sort)

    print_rdma_header
    if [[ ${#rd_cur_rx[@]} -eq 0 ]]; then
      echo "(未发现 RDMA 设备或无可读计数器)"
    else
      while IFS= read -r k; do
        local prev_rx="${rd_prev_rx[$k]:-${rd_cur_rx[$k]}}"
        local prev_tx="${rd_prev_tx[$k]:-${rd_cur_tx[$k]}}"
        local drx=$(( rd_cur_rx[$k] - prev_rx ))
        local dtx=$(( rd_cur_tx[$k] - prev_tx ))
        ((drx < 0)) && drx=0
        ((dtx < 0)) && dtx=0

        local trx=$(( rd_cur_rx[$k] - rd_base_rx[$k] ))
        local ttx=$(( rd_cur_tx[$k] - rd_base_tx[$k] ))
        ((trx < 0)) && trx=0
        ((ttx < 0)) && ttx=0

        rd_mode["$k"]="${rd_cur_mode[$k]}"
        rd_netdev["$k"]="${rd_cur_net[$k]}"

        printf "%-16s %-14s %-14s %-14s %-14s %-10s %-10s\n" \
          "$k" "${rd_netdev[$k]}" "$(fmt_rate "$drx" "$INTERVAL")" "$(fmt_rate "$dtx" "$INTERVAL")" \
          "$(fmt_bytes "$trx")" "$(fmt_bytes "$ttx")" "${rd_mode[$k]}"

        rd_prev_rx["$k"]="${rd_cur_rx[$k]}"
        rd_prev_tx["$k"]="${rd_cur_tx[$k]}"
      done < <(printf '%s\n' "${!rd_cur_rx[@]}" | sort)
    fi
  done
}

loop
