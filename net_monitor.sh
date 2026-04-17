#!/usr/bin/env bash
set -euo pipefail

# 实时监控 IP 网卡与 RDMA(IB/RoCEv2) 网卡速率与流量统计。
# 依赖基础 Linux 能力: /proc, /sys, awk, sed, date, sleep.

INTERVAL="1"
SHOW_LOOPBACK="${SHOW_LOOPBACK:-0}"
RDMA_WORD_BYTES="${RDMA_WORD_BYTES:-4}"
declare -a FILTERS=()

usage() {
  cat <<'USAGE'
用法:
  ./net_monitor.sh [-h] [-t seconds] [-d interface_name ...]

参数:
  -h                 显示帮助
  -t seconds         刷新周期(秒)，默认 1
  -d interface_name  指定监控对象，可重复使用
                     可填 IP 网卡名(如 eth0)、RDMA dev/port(如 mlx5_0/1)、
                     RDMA dev(如 mlx5_0) 或与 RDMA 关联的 netdev 名。

环境变量:
  SHOW_LOOPBACK    是否显示 lo 网卡: 1 显示, 0 不显示(默认)
  RDMA_WORD_BYTES  RDMA port_*_data 计数单位字节数，默认 4

过滤规则:
  - 不指定 -d: 显示全部 IP 与 RDMA。
  - 指定 -d: 按 "IP<->RDMA 关联关系" 自动扩展显示范围。
    例如指定 IP 网卡时，会自动显示其对应 RDMA 端口；
    指定 RDMA 端口时，也会自动显示其关联 IP 网卡。
    多个 -d 有重叠会自动并集去重。

统计口径:
  - 开机总流量: 从内核计数器读取的历史总量（系统启动以来）。
  - 本次累计流量: 从脚本启动时刻开始累计。
USAGE
}

while getopts ":ht:d:" opt; do
  case "$opt" in
    h)
      usage
      exit 0
      ;;
    t)
      INTERVAL="$OPTARG"
      ;;
    d)
      FILTERS+=("$OPTARG")
      ;;
    :)
      echo "错误: -$OPTARG 缺少参数" >&2
      usage
      exit 1
      ;;
    \?)
      echo "错误: 不支持的参数 -$OPTARG" >&2
      usage
      exit 1
      ;;
  esac
done
shift $((OPTIND - 1))

if [[ $# -gt 0 ]]; then
  echo "错误: 存在无法识别的位置参数: $*" >&2
  usage
  exit 1
fi

if ! awk "BEGIN{exit !($INTERVAL>0)}"; then
  echo "错误: -t interval 必须是正数" >&2
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

csv_has_item() {
  local csv="$1" item="$2"
  [[ "$csv" == "-" || -z "$csv" ]] && return 1
  local x
  IFS=',' read -r -a __arr <<< "$csv"
  for x in "${__arr[@]}"; do
    [[ "$x" == "$item" ]] && return 0
  done
  return 1
}

rdma_dev_from_key() {
  local key="$1"
  echo "${key%%/*}"
}

should_show_ip() {
  local iface="$1"
  if [[ ${#FILTERS[@]} -eq 0 ]]; then
    return 0
  fi
  [[ -n "${sel_ip[$iface]+x}" ]]
}

should_show_rdma() {
  local key="$1"
  if [[ ${#FILTERS[@]} -eq 0 ]]; then
    return 0
  fi
  [[ -n "${sel_rd[$key]+x}" ]]
}

build_selection_sets() {
  declare -gA sel_ip=() sel_rd=()

  if [[ ${#FILTERS[@]} -eq 0 ]]; then
    return 0
  fi

  local token k nets dev n

  # 1) seed by direct matches
  for token in "${FILTERS[@]}"; do
    if [[ -n "${ip_cur_rx[$token]+x}" ]]; then
      sel_ip["$token"]=1
    fi

    for k in "${!rd_cur_rx[@]}"; do
      nets="${rd_netdev[$k]:--}"
      dev="$(rdma_dev_from_key "$k")"
      if [[ "$token" == "$k" || "$token" == "$dev" ]]; then
        sel_rd["$k"]=1
      fi
      if csv_has_item "$nets" "$token"; then
        sel_rd["$k"]=1
        if [[ -n "${ip_cur_rx[$token]+x}" ]]; then
          sel_ip["$token"]=1
        fi
      fi
    done
  done

  # 2) closure: IP -> RDMA, RDMA -> IP, until stable
  local changed=1
  while ((changed)); do
    changed=0

    for n in "${!sel_ip[@]}"; do
      for k in "${!rd_cur_rx[@]}"; do
        nets="${rd_netdev[$k]:--}"
        if csv_has_item "$nets" "$n" && [[ -z "${sel_rd[$k]+x}" ]]; then
          sel_rd["$k"]=1
          changed=1
        fi
      done
    done

    for k in "${!sel_rd[@]}"; do
      nets="${rd_netdev[$k]:--}"
      [[ "$nets" == "-" ]] && continue
      IFS=',' read -r -a __arr <<< "$nets"
      for n in "${__arr[@]}"; do
        if [[ -n "${ip_cur_rx[$n]+x}" && -z "${sel_ip[$n]+x}" ]]; then
          sel_ip["$n"]=1
          changed=1
        fi
      done
    done
  done
}

# baseline
declare -A ip_prev_rx ip_prev_tx ip_base_rx ip_base_tx
declare -A rd_prev_rx rd_prev_tx rd_base_rx rd_base_tx rd_mode rd_netdev
declare -A ip_hwid rd_hwid

declare -A sel_ip sel_rd

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

repeat_char() {
  local char="$1" count="$2"
  awk -v c="$char" -v n="$count" 'BEGIN{for(i=0;i<n;i++) printf "%s", c; printf "\n"}'
}

get_ip_hwid() {
  local iface="$1"
  if [[ -n "${ip_hwid[$iface]+x}" ]]; then
    echo "${ip_hwid[$iface]}"
    return 0
  fi
  local p="/sys/class/net/$iface/device"
  if [[ -e "$p" ]]; then
    ip_hwid["$iface"]="$(basename "$(readlink -f "$p")")"
  else
    ip_hwid["$iface"]="-"
  fi
  echo "${ip_hwid[$iface]}"
}

get_rdma_hwid() {
  local key="$1"
  if [[ -n "${rd_hwid[$key]+x}" ]]; then
    echo "${rd_hwid[$key]}"
    return 0
  fi
  local dev
  dev="$(rdma_dev_from_key "$key")"
  local p="/sys/class/infiniband/$dev/device"
  if [[ -e "$p" ]]; then
    rd_hwid["$key"]="$(basename "$(readlink -f "$p")")"
  else
    rd_hwid["$key"]="-"
  fi
  echo "${rd_hwid[$key]}"
}

print_header() {
  if [[ -t 1 ]]; then clear; else printf "\033c"; fi 2>/dev/null || true
  echo "实时网络监控  时间: $(date '+%F %T %Z')  间隔: ${INTERVAL}s"
  if [[ ${#FILTERS[@]} -gt 0 ]]; then
    echo "过滤: ${FILTERS[*]} (自动合并并扩展 IP<->RDMA 对应关系)"
  fi
  echo
  local w_if=30 w_type=6 w_dir=3 w_rate=14 w_sess=14 w_total=14
  local total_width=$((w_if + w_type + w_dir + w_rate + w_sess + w_total + 5*3 + 6))
  repeat_char "=" "$total_width"
  printf "%-${w_if}s | %-${w_type}s | %-${w_dir}s | %-${w_rate}s | %-${w_sess}s | %-${w_total}s\n" \
    "INTERFACE (PCI/HW)" "TYPE" "DIR" "CURRENT RATE" "SESSION CUM" "TOTAL (BOOT)"
  repeat_char "=" "$total_width"
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
      rd_mode["$k"]="$mode"
      rd_netdev["$k"]="$net"
      [[ -n "${rd_base_rx[$k]+x}" ]] || rd_base_rx["$k"]="$rx"
      [[ -n "${rd_base_tx[$k]+x}" ]] || rd_base_tx["$k"]="$tx"
    done < <(read_rdma_stats)

    build_selection_sets

    print_header
    local w_if=30 w_type=6 w_dir=3 w_rate=14 w_sess=14 w_total=14
    local total_width=$((w_if + w_type + w_dir + w_rate + w_sess + w_total + 5*3 + 6))
    local shown_any=0

    local prev_group=""
    while IFS='|' read -r grp typ k hwid; do
      [[ -n "${grp:-}" && -n "${typ:-}" && -n "${k:-}" ]] || continue
      if [[ $shown_any -eq 1 && "$grp" != "$prev_group" ]]; then
        repeat_char "-" "$total_width"
      fi
      shown_any=1
      prev_group="$grp"

      local iface_label
      local in_rate out_rate in_sess out_sess in_total out_total

      if [[ "$typ" == "IP" ]]; then
        iface_label="$k ($hwid)"
        local prev_rx="${ip_prev_rx[$k]:-${ip_cur_rx[$k]}}"
        local prev_tx="${ip_prev_tx[$k]:-${ip_cur_tx[$k]}}"
        local drx=$(( ip_cur_rx[$k] - prev_rx ))
        local dtx=$(( ip_cur_tx[$k] - prev_tx ))
        ((drx < 0)) && drx=0
        ((dtx < 0)) && dtx=0
        in_rate="$(fmt_rate "$drx" "$INTERVAL")"
        out_rate="$(fmt_rate "$dtx" "$INTERVAL")"

        local run_rx=$(( ip_cur_rx[$k] - ip_base_rx[$k] ))
        local run_tx=$(( ip_cur_tx[$k] - ip_base_tx[$k] ))
        ((run_rx < 0)) && run_rx=0
        ((run_tx < 0)) && run_tx=0
        in_sess="$(fmt_bytes "$run_rx")"
        out_sess="$(fmt_bytes "$run_tx")"
        in_total="$(fmt_bytes "${ip_cur_rx[$k]}")"
        out_total="$(fmt_bytes "${ip_cur_tx[$k]}")"
      else
        iface_label="$k ($hwid)"
        local prev_rx="${rd_prev_rx[$k]:-${rd_cur_rx[$k]}}"
        local prev_tx="${rd_prev_tx[$k]:-${rd_cur_tx[$k]}}"
        local drx=$(( rd_cur_rx[$k] - prev_rx ))
        local dtx=$(( rd_cur_tx[$k] - prev_tx ))
        ((drx < 0)) && drx=0
        ((dtx < 0)) && dtx=0
        in_rate="$(fmt_rate "$drx" "$INTERVAL")"
        out_rate="$(fmt_rate "$dtx" "$INTERVAL")"

        local run_rx=$(( rd_cur_rx[$k] - rd_base_rx[$k] ))
        local run_tx=$(( rd_cur_tx[$k] - rd_base_tx[$k] ))
        ((run_rx < 0)) && run_rx=0
        ((run_tx < 0)) && run_tx=0
        in_sess="$(fmt_bytes "$run_rx")"
        out_sess="$(fmt_bytes "$run_tx")"
        in_total="$(fmt_bytes "${rd_cur_rx[$k]}")"
        out_total="$(fmt_bytes "${rd_cur_tx[$k]}")"
      fi

      printf "%-${w_if}s | %-${w_type}s | %-${w_dir}s | %-${w_rate}s | %-${w_sess}s | %-${w_total}s\n" \
        "$iface_label" "$typ" "IN" "$in_rate" "$in_sess" "$in_total"
      printf "%-${w_if}s | %-${w_type}s | %-${w_dir}s | %-${w_rate}s | %-${w_sess}s | %-${w_total}s\n" \
        "" "" "OUT" "$out_rate" "$out_sess" "$out_total"
    done < <(
      {
        for k in "${!ip_cur_rx[@]}"; do
          should_show_ip "$k" || continue
          local hwid group
          hwid="$(get_ip_hwid "$k")"
          if [[ "$hwid" == "-" ]]; then
            group="IP:$k"
          else
            group="$hwid"
          fi
          echo "$group|IP|$k|$hwid"
        done
        for k in "${!rd_cur_rx[@]}"; do
          should_show_rdma "$k" || continue
          local hwid group
          hwid="$(get_rdma_hwid "$k")"
          if [[ "$hwid" == "-" ]]; then
            group="RDMA:$k"
          else
            group="$hwid"
          fi
          echo "$group|RDMA|$k|$hwid"
        done
      } | sort -t'|' -k1,1 -k2,2 -k3,3
    )

    if [[ $shown_any -eq 0 ]]; then
      echo "(按当前过滤条件未匹配到可显示对象)"
      repeat_char "-" "$total_width"
    else
      repeat_char "-" "$total_width"
    fi

    for k in "${!ip_cur_rx[@]}"; do
      ip_prev_rx["$k"]="${ip_cur_rx[$k]}"
      ip_prev_tx["$k"]="${ip_cur_tx[$k]}"
    done
    for k in "${!rd_cur_rx[@]}"; do
      rd_prev_rx["$k"]="${rd_cur_rx[$k]}"
      rd_prev_tx["$k"]="${rd_cur_tx[$k]}"
    done
  done
}

loop
