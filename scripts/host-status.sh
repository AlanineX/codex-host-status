#!/usr/bin/env bash
set -u

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

mode="${1:-plain}"
cache_dir="${XDG_RUNTIME_DIR:-/tmp}"
cache_prefix="${cache_dir%/}/codex-host-status-${UID:-user}"
status_columns="${CODEX_STATUS_COLUMNS:-${COLUMNS:-}}"
if ! [ "$status_columns" -gt 0 ] 2>/dev/null; then
    status_columns=$(tput cols 2>/dev/null || printf '120')
fi

status_style="${CODEX_HOST_STATUS_STYLE:-auto}"
if [ "$status_style" = "auto" ]; then
    if [ "$status_columns" -lt 95 ] 2>/dev/null; then
        status_style="tiny"
    elif [ "$status_columns" -lt 135 ] 2>/dev/null; then
        status_style="compact"
    else
        status_style="long"
    fi
fi

if [ -n "${CODEX_HOST_STATUS_SEPARATOR+x}" ]; then
    sep="$CODEX_HOST_STATUS_SEPARATOR"
elif [ "$status_style" = "long" ]; then
    sep="  "
else
    sep=" "
fi

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

shorten() {
    local text="$1" max="$2"
    if [ "${#text}" -le "$max" ]; then
        printf '%s' "$text"
    else
        printf '%s+' "${text:0:$((max - 1))}"
    fi
}

sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

codex_rollout_path() {
    local codex_home state_db cwd cwd_sql rollout
    codex_home="${CODEX_HOME:-${HOME}/.codex}"
    state_db="${codex_home%/}/state_5.sqlite"

    if [ -n "${CODEX_STATUS_ROLLOUT_PATH:-}" ] && [ -r "$CODEX_STATUS_ROLLOUT_PATH" ]; then
        printf '%s\n' "$CODEX_STATUS_ROLLOUT_PATH"
        return 0
    fi

    command -v sqlite3 >/dev/null 2>&1 || return 1
    [ -r "$state_db" ] || return 1

    cwd="${CODEX_STATUS_CWD:-${PWD:-}}"
    if [ -n "$cwd" ]; then
        cwd_sql=$(sql_escape "$cwd")
        rollout=$(
            sqlite3 -readonly "$state_db" \
                "select rollout_path from threads where archived=0 and source='cli' and cwd='${cwd_sql}' order by recency_at_ms desc, updated_at_ms desc limit 1;" \
                2>/dev/null
        ) || true
        if [ -n "$rollout" ] && [ -r "$rollout" ]; then
            printf '%s\n' "$rollout"
            return 0
        fi
    fi

    rollout=$(
        sqlite3 -readonly "$state_db" \
            "select rollout_path from threads where archived=0 and source='cli' order by recency_at_ms desc, updated_at_ms desc limit 1;" \
            2>/dev/null
    ) || true
    [ -n "$rollout" ] && [ -r "$rollout" ] || return 1
    printf '%s\n' "$rollout"
}

codex_usage_info() {
    command -v jq >/dev/null 2>&1 || return 1

    local rollout payload
    rollout=$(codex_rollout_path) || return 1
    payload=$(
        tail -n "${CODEX_HOST_STATUS_TOKEN_TAIL:-800}" "$rollout" 2>/dev/null |
            jq -rc 'select(.type=="event_msg" and .payload.type=="token_count") | .payload' 2>/dev/null |
            tail -n 1
    ) || true
    [ -n "$payload" ] || return 1

    printf '%s\n' "$payload" | jq -r '
        [
            (.info.last_token_usage.input_tokens // 0),
            (.info.model_context_window // 0),
            (.info.total_token_usage.input_tokens // 0),
            (.info.total_token_usage.cached_input_tokens // 0),
            (.info.total_token_usage.output_tokens // 0),
            (.info.total_token_usage.reasoning_output_tokens // 0),
            (.info.total_token_usage.total_tokens // 0),
            (.rate_limits.primary.used_percent // ""),
            (.rate_limits.secondary.used_percent // "")
        ] | @tsv
    ' 2>/dev/null
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
codex_info=$(codex_usage_info || true)

out=""
if [ -n "$env_name" ]; then
    if [ "$status_style" = "long" ]; then
        segment magenta "🐍 ${env_name}"
    else
        segment magenta "🐍$(shorten "$env_name" 10)"
    fi
fi

if [ -n "$codex_info" ]; then
    read -r ctx_input ctx_window total_input cached_input total_output reasoning_output total_tokens rate_5h rate_7d <<< "$codex_info"
    if [ "${ctx_window:-0}" -gt 0 ] 2>/dev/null; then
        ctx_pct=$(awk -v used="${ctx_input:-0}" -v total="${ctx_window:-0}" 'BEGIN { v=int(used*100/total); if (v>100) v=100; print v }')
        if [ "$status_style" = "long" ]; then
            segment "$(tcolor "$ctx_pct" 50 80)" "🧠 ${ctx_pct}%"
        else
            segment "$(tcolor "$ctx_pct" 50 80)" "🧠${ctx_pct}%"
        fi
    fi

    uncached_input=$(( ${total_input:-0} - ${cached_input:-0} ))
    if [ "$uncached_input" -lt 0 ] 2>/dev/null; then
        uncached_input=0
    fi
    pseudo_cost=$(awk \
        -v uncached="$uncached_input" \
        -v cached="${cached_input:-0}" \
        -v output="${total_output:-0}" \
        'BEGIN { printf "%.2f", (uncached + cached * 0.1 + output * 4) / 1000000 }')
    pseudo_cost_int=$(awk -v v="$pseudo_cost" 'BEGIN { print int(v) }')
    if [ "$status_style" = "long" ]; then
        segment "$(tcolor "$pseudo_cost_int" 2 10)" "💰 ${pseudo_cost}u"
    elif [ "$status_style" = "tiny" ]; then
        pseudo_cost_short=$(awk -v v="$pseudo_cost" 'BEGIN { printf "%.1f", v }')
        segment "$(tcolor "$pseudo_cost_int" 2 10)" "💰${pseudo_cost_short}"
    else
        pseudo_cost_short=$(awk -v v="$pseudo_cost" 'BEGIN { printf "%.1f", v }')
        segment "$(tcolor "$pseudo_cost_int" 2 10)" "💰${pseudo_cost_short}u"
    fi

    if [ -n "${rate_5h:-}" ]; then
        rate_5h_int=$(awk -v v="$rate_5h" 'BEGIN { print int(v) }')
        if [ "$status_style" = "long" ]; then
            segment "$(tcolor "$rate_5h_int" 50 80)" "⌛ 5h ${rate_5h_int}%"
        elif [ "$status_style" = "tiny" ]; then
            segment "$(tcolor "$rate_5h_int" 50 80)" "⌛${rate_5h_int}%"
        else
            segment "$(tcolor "$rate_5h_int" 50 80)" "⌛5h${rate_5h_int}%"
        fi
    fi
    if [ -n "${rate_7d:-}" ]; then
        rate_7d_int=$(awk -v v="$rate_7d" 'BEGIN { print int(v) }')
        if [ "$status_style" = "long" ]; then
            segment "$(tcolor "$rate_7d_int" 50 80)" "📅 7d ${rate_7d_int}%"
        elif [ "$status_style" = "tiny" ]; then
            segment "$(tcolor "$rate_7d_int" 50 80)" "📅${rate_7d_int}%"
        else
            segment "$(tcolor "$rate_7d_int" 50 80)" "📅7d${rate_7d_int}%"
        fi
    fi
fi

case "$status_style" in
    long)
        segment "$(tcolor "$cpu_pct" 50 80)" "🧮 CPU ${cpu_pct}% ${cpu_temp}C"
        ;;
    tiny)
        segment "$(tcolor "$cpu_pct" 50 80)" "🧮${cpu_pct}%"
        ;;
    *)
        segment "$(tcolor "$cpu_pct" 50 80)" "🧮${cpu_pct}%/${cpu_temp}c"
        ;;
esac

gpu_line=$(gpu_info || true)
if [ -n "$gpu_line" ]; then
    IFS=', ' read -r gpu_util gpu_temp gpu_mem_used <<< "$gpu_line"
    gpu_util=${gpu_util// /}
    gpu_temp=${gpu_temp// /}
    gpu_mem_used=${gpu_mem_used// /}
    if [ -n "$gpu_util" ] && [ -n "$gpu_temp" ]; then
        gpu_mem_gb=$(awk -v mb="${gpu_mem_used:-0}" 'BEGIN { printf "%.1f", mb/1024 }')
        case "$status_style" in
            long)
                segment "$(tcolor "$gpu_util" 50 80)" "🎮 GPU ${gpu_util}% ${gpu_temp}C ${gpu_mem_gb}G"
                ;;
            tiny)
                segment "$(tcolor "$gpu_util" 50 80)" "🎮${gpu_util}%"
                ;;
            *)
                segment "$(tcolor "$gpu_util" 50 80)" "🎮${gpu_util}%/${gpu_temp}c/${gpu_mem_gb}G"
                ;;
        esac
    fi
fi

if [ -n "$mem_info" ]; then
    read -r mem_pct mem_used_gb mem_total_gb <<< "$mem_info"
    case "$status_style" in
        long)
            segment "$(tcolor "$mem_pct" 50 80)" "💾 RAM ${mem_used_gb}/${mem_total_gb}G"
            ;;
        tiny)
            segment "$(tcolor "$mem_pct" 50 80)" "💾${mem_used_gb}G"
            ;;
        *)
            segment "$(tcolor "$mem_pct" 50 80)" "💾${mem_used_gb}/${mem_total_gb}G"
            ;;
    esac
fi

if [ "$status_style" = "long" ]; then
    segment cyan "🕒 $(date +"${CODEX_HOST_STATUS_CLOCK_FORMAT:-%H:%M}")"
else
    segment cyan "🕒$(date +"${CODEX_HOST_STATUS_CLOCK_FORMAT:-%H:%M}")"
fi

printf '%s\n' "$out"
