#!/usr/bin/env bash
set -u

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

mode="${1:-plain}"
sep="${CODEX_HOST_STATUS_SEPARATOR:-  }"
cache_dir="${XDG_RUNTIME_DIR:-/tmp}"
cache_prefix="${cache_dir%/}/codex-host-status-${UID:-user}"

style() {
    if [ "$mode" = "--tmux" ]; then
        printf '#[fg=%s]' "$1"
    fi
}

reset_style() {
    if [ "$mode" = "--tmux" ]; then
        printf '#[default]'
    fi
}

tcolor() {
    local val="${1:-0}" lo="${2:-50}" hi="${3:-80}"
    if [ "$val" -lt "$lo" ] 2>/dev/null; then
        printf 'green'
    elif [ "$val" -lt "$hi" ] 2>/dev/null; then
        printf 'yellow'
    else
        printf 'red'
    fi
}

segment() {
    local color="$1"
    local text="$2"
    [ -z "$text" ] && return
    if [ -n "${out:-}" ]; then
        out="${out}${sep}"
    fi
    out="${out}$(style "$color")${text}$(reset_style)"
}

cpu_pct_from_proc() {
    local stat total idle prev_total prev_idle delta_total delta_idle cache
    cache="${cache_prefix}.cpu"
    stat=$(awk '/^cpu / { idle=$5+$6; total=0; for (i=2; i<=NF; i++) total += $i; printf "%d %d", total, idle; exit }' /proc/stat 2>/dev/null) || true
    [ -n "$stat" ] || return 1
    read -r total idle <<< "$stat"

    if [ -r "$cache" ]; then
        read -r prev_total prev_idle < "$cache" || true
    fi
    printf '%s %s\n' "$total" "$idle" > "$cache" 2>/dev/null || true

    if [ -n "${prev_total:-}" ] && [ "$total" -gt "$prev_total" ] 2>/dev/null; then
        delta_total=$((total - prev_total))
        delta_idle=$((idle - prev_idle))
        awk -v dt="$delta_total" -v di="$delta_idle" 'BEGIN { printf "%d", ((dt - di) * 100 / dt) }'
        return 0
    fi

    return 1
}

cpu_pct_from_load() {
    local nproc_count cpu_load
    nproc_count=$(nproc 2>/dev/null || printf '1')
    cpu_load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || printf '0')
    awk -v load="$cpu_load" -v n="$nproc_count" 'BEGIN { v=int(load/n*100); if (v>100) v=100; print v }'
}

cpu_temp_c() {
    local hw name input raw zone
    for hw in /sys/class/hwmon/hwmon*; do
        [ -r "$hw/name" ] || continue
        name=$(cat "$hw/name" 2>/dev/null || true)
        case "$name" in
            coretemp|k10temp|zenpower|cpu_thermal|acpitz)
                for input in "$hw"/temp*_input; do
                    [ -r "$input" ] || continue
                    raw=$(cat "$input" 2>/dev/null || true)
                    if [ -n "$raw" ] && [ "$raw" -gt 0 ] 2>/dev/null; then
                        printf '%d' "$((raw / 1000))"
                        return 0
                    fi
                done
                ;;
        esac
    done

    for zone in /sys/class/thermal/thermal_zone*/temp; do
        [ -r "$zone" ] || continue
        raw=$(cat "$zone" 2>/dev/null || true)
        if [ -n "$raw" ] && [ "$raw" -gt 0 ] 2>/dev/null; then
            printf '%d' "$((raw / 1000))"
            return 0
        fi
    done

    printf '?'
}

memory_info() {
    awk '
        /MemTotal/ { total=$2 }
        /MemAvailable/ { available=$2 }
        END {
            used=total-available
            if (total > 0) {
                printf "%d %.1f %.0f", int(used*100/total), used/1048576, total/1048576
            }
        }
    ' /proc/meminfo 2>/dev/null
}

gpu_info() {
    command -v nvidia-smi >/dev/null 2>&1 || return 1

    local cache ttl age line gpu_index line_number
    ttl="${CODEX_HOST_STATUS_GPU_TTL:-5}"
    gpu_index="${CODEX_HOST_STATUS_GPU_INDEX:-0}"
    line_number=$((gpu_index + 1))
    cache="${cache_prefix}.gpu.${gpu_index}"
    age=999

    if [ -f "$cache" ]; then
        age=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || printf '0') ))
    fi

    if [ "$age" -ge "$ttl" ] 2>/dev/null; then
        line=$(
            nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,memory.used \
                --format=csv,noheader,nounits 2>/dev/null |
                awk -v n="$line_number" 'NR == n { print; exit }'
        ) || true
        if [ -n "$line" ]; then
            printf '%s\n' "$line" > "$cache" 2>/dev/null || true
        fi
    fi

    [ -r "$cache" ] || return 1
    cat "$cache" 2>/dev/null
}

env_name=""
if [ -n "${CONDA_DEFAULT_ENV:-}" ]; then
    env_name="$CONDA_DEFAULT_ENV"
elif [ -n "${VIRTUAL_ENV:-}" ]; then
    env_name="$(basename "$VIRTUAL_ENV")"
fi

cpu_pct=$(cpu_pct_from_proc || cpu_pct_from_load)
cpu_temp=$(cpu_temp_c)
mem_info=$(memory_info)

out=""
if [ -n "$env_name" ]; then
    segment magenta "🐍 ${env_name}"
fi

segment "$(tcolor "$cpu_pct" 50 80)" "⚙ CPU ${cpu_pct}% ${cpu_temp}C"

gpu_line=$(gpu_info || true)
if [ -n "$gpu_line" ]; then
    IFS=', ' read -r gpu_util gpu_temp gpu_mem_used <<< "$gpu_line"
    gpu_util=${gpu_util// /}
    gpu_temp=${gpu_temp// /}
    gpu_mem_used=${gpu_mem_used// /}
    if [ -n "$gpu_util" ] && [ -n "$gpu_temp" ]; then
        gpu_mem_gb=$(awk -v mb="${gpu_mem_used:-0}" 'BEGIN { printf "%.1f", mb/1024 }')
        segment "$(tcolor "$gpu_util" 50 80)" "🎮 GPU ${gpu_util}% ${gpu_temp}C ${gpu_mem_gb}G"
    fi
fi

if [ -n "$mem_info" ]; then
    read -r mem_pct mem_used_gb mem_total_gb <<< "$mem_info"
    segment "$(tcolor "$mem_pct" 50 80)" "💾 RAM ${mem_used_gb}/${mem_total_gb}G"
fi

segment cyan "🕒 $(date +"${CODEX_HOST_STATUS_CLOCK_FORMAT:-%H:%M}")"

printf '%s\n' "$out"
