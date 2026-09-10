#!/bin/sh
# 按编号顺序拼接分片，生成上级目录的路线图阅读产物；不替代系统规格
set -e
cd "$(dirname "$0")"
out="../brainstorming-ai-era-roadmap.md"
cat \
  "00-导读与维护说明.md" \
  "01-产品现状快照.md" \
  "02-AI时代关键判断.md" \
  "03-路线层级草案-已废弃.md" \
  "04-安全边界与约束原则.md" \
  "05-功能提案深度分析.md" \
  "06-待决问题清单.md" \
  "07-讨论记录.md" \
  "08-产品愿景.md" \
  "09-愿景讨论记录-已并入第七节.md" \
  "10-场景化产品设计.md" \
  "11-Skill开源标准调研.md" \
  "12-AI原生能力缺口分析.md" \
  "13-三条执行主线与自我迭代学习.md" \
  "14-未决事项调研.md" > "$out"
echo "已重组: openspec/brainstorming-ai-era-roadmap.md ($(wc -l < "$out") 行)"
