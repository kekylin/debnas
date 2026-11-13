#!/bin/bash
# ops-report: 报告入口 loader（数据采集 / 渲染 / CLI 分文件）
# 说明：函数按职责拆到 report-common.sh / report-collect.sh /
#       report-render.sh / report-cli.sh，调用方仍只需 source report.sh。
set -euo pipefail
IFS=$'\n\t'

_ops_report_src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_ops_report_src_dir}/report-common.sh"
source "${_ops_report_src_dir}/report-collect.sh"
source "${_ops_report_src_dir}/report-render.sh"
source "${_ops_report_src_dir}/report-cli.sh"
unset _ops_report_src_dir
