#!/bin/bash
# ops-report: systemd、Docker、VM 状态采集
set -euo pipefail
IFS=$'\n\t'

ops_collect_services() {
  OPS_SYSTEMD_FAILED_COUNT=0
  OPS_SYSTEMD_FAILED_LIST=""
  OPS_DOCKER_PS=""
  OPS_DOCKER_RUNNING_COUNT=0
  OPS_DOCKER_STOPPED_COUNT=0
  OPS_DOCKER_RESTARTS=""
  OPS_DOCKER_SERVICE_NAMES=""
  OPS_VM_LIST=""
  OPS_VM_RUNNING_COUNT=0
  OPS_VM_COUNT=0
  OPS_LISTEN_PORTS=""
  OPS_SERVICE_STABILITY=""
  OPS_JOURNAL_ERROR_COUNT=0
  OPS_TIMER_TASKS=""

  if command -v systemctl >/dev/null 2>&1; then
    OPS_SYSTEMD_FAILED_LIST=$(systemctl --failed --no-legend --no-pager 2>/dev/null || true)
    OPS_SYSTEMD_FAILED_COUNT=$(printf '%s\n' "${OPS_SYSTEMD_FAILED_LIST}" | grep -v '^$' | wc -l || true)

    local service_name service_errors service_restarts service_start service_state
    local -a service_names=()
    local -A seen=()
    local svc
    while read -r svc; do
      svc="${svc%.service}"
      [[ -n "$svc" ]] || continue
      [[ "$svc" =~ ^(ssh|cron|docker|nginx|apache2|postgresql|mariadb|mysql|redis-server|smbd|nmbd|tailscaled|jellyfin|radarr|sonarr|prowlarr|qbittorrent|transmission-daemon|plexmediaserver|emby-server|portainer|homeassistant|nodered|nextcloud|cockpit|fail2ban|exim4|postfix|bind9|named)$ ]] || continue
      [[ -n "${seen[$svc]:-}" ]] && continue
      seen[$svc]=1
      service_names+=("$svc")
    done < <(systemctl list-units --type=service --state=running --no-legend --no-pager 2>/dev/null \
      | awk '{print $1}' | sort -u)
    while read -r svc; do
      svc="${svc%.service}"
      [[ -n "$svc" ]] || continue
      [[ -n "${seen[$svc]:-}" ]] && continue
      seen[$svc]=1
      service_names+=("$svc")
    done < <(systemctl --failed --no-legend --no-pager 2>/dev/null \
      | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /\.service$/) { sub(/\.service$/, "", $i); print $i } }')
    for svc in ssh cron docker nginx fail2ban cockpit postgresql mariadb smbd tailscaled jellyfin radarr; do
      [[ -n "${seen[$svc]:-}" ]] && continue
      if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
        seen[$svc]=1
        service_names+=("$svc")
      fi
    done
    for service_name in "${service_names[@]}"; do
      service_errors=$(timeout 20 journalctl -u "${service_name}" --since "${OPS_REPORT_SINCE:-$(date '+%Y-%m-%d %H:%M:%S')}" \
        --no-pager 2>/dev/null | grep -cEi 'fail|error|panic|oom' || true)
      service_restarts=$(timeout 20 journalctl -u "${service_name}" \
        --since "${OPS_REPORT_SINCE:-$(date '+%Y-%m-%d %H:%M:%S')}" \
        --no-pager 2>/dev/null \
        | grep -cEi 'Starting|Started|Stopped|Failed to start' || true)
      [[ "$service_restarts" =~ ^[0-9]+$ ]] || service_restarts=0
      service_start=$(systemctl show "${service_name}" -p ExecMainStartTimestamp --value 2>/dev/null || true)
      [[ -n "$service_start" ]] || service_start="-"
      service_state=$(systemctl is-active "${service_name}" 2>/dev/null || true)
      if [[ "$service_state" == "inactive" || "$service_state" == "unknown" ]]; then
        if systemctl is-active --quiet "${service_name}.socket" 2>/dev/null; then
          service_state="active"
        fi
      fi
      case "$service_state" in
        active) service_state="正常" ;;
        failed) service_state="failed" ;;
        inactive|unknown) service_state="已停止" ;;
        *) service_state="${service_state:-未知}" ;;
      esac
      OPS_SERVICE_STABILITY="${OPS_SERVICE_STABILITY:+${OPS_SERVICE_STABILITY}
}${service_name}|${service_errors}|${service_restarts}|${service_start}|${service_state}"
    done

    OPS_JOURNAL_ERROR_COUNT=$(timeout 20 journalctl -p err --since "${OPS_REPORT_SINCE:-$(date '+%Y-%m-%d %H:%M:%S')}" \
      --no-pager 2>/dev/null | grep -v '^$' | wc -l || true)
    OPS_TIMER_TASKS=$(systemctl list-timers --all --no-pager --no-legend 2>/dev/null \
      | grep -v '^$' | wc -l || true)
  fi

  if command -v docker >/dev/null 2>&1 && [[ "${OPS_INCLUDE_DOCKER:-1}" -eq 1 ]]; then
    OPS_DOCKER_PS=$(timeout 15 docker ps -a --format '{{.Names}}\t{{.State}}\t{{.Status}}' 2>/dev/null || true)
    OPS_DOCKER_RUNNING_COUNT=$(printf '%s\n' "${OPS_DOCKER_PS}" | awk -F '\t' '$2 == "running" {n++} END {print n+0}' || true)
    OPS_DOCKER_STOPPED_COUNT=$(printf '%s\n' "${OPS_DOCKER_PS}" | awk -F '\t' '$2 != "running" && $2 != "" {n++} END {print n+0}' || true)

    local containers
    containers=$(timeout 10 docker ps -aq 2>/dev/null || true)
    if [[ -n "$containers" ]]; then
      OPS_DOCKER_RESTARTS=$(timeout 20 docker inspect -f '{{.Name}} {{.RestartCount}}' $containers 2>/dev/null || true)
    fi
  fi

  if command -v virsh >/dev/null 2>&1 && [[ "${OPS_INCLUDE_VM:-1}" -eq 1 ]]; then
    OPS_VM_LIST=$(timeout 10 virsh list --all --name 2>/dev/null || true)
    OPS_VM_COUNT=$(printf '%s\n' "${OPS_VM_LIST}" | grep -v '^$' | wc -l || true)
    OPS_VM_RUNNING_COUNT=$(timeout 10 virsh list --name 2>/dev/null | grep -v '^$' | wc -l || true)
    if [[ "${OPS_VM_COUNT:-0}" -gt 0 ]]; then
      OPS_SERVICE_STABILITY="${OPS_SERVICE_STABILITY:+${OPS_SERVICE_STABILITY}
}VM DSM|0|0|-|${OPS_VM_RUNNING_COUNT} 个运行"
    fi
  fi

  if command -v ss >/dev/null 2>&1; then
    OPS_LISTEN_PORTS=$(ss -tulnH 2>/dev/null | head -30 || true)
  fi
}
