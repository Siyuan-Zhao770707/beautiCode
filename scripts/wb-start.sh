#!/bin/sh
# wb-start.sh — WorkBuddy 自定义背景 · 一键启动
# 用法：直接把下面这段粘到 Terminal 回车；或保存后 sh wb-start.sh
# 效果：退出 WorkBuddy → 带 CDP 重启 → 等端口 → 编译 adapter → 起守护注入
# 退出：在守护的日志里 Ctrl+C（会自动清理注入节点），WorkBuddy 不受影响

set -e
WB_APP="/Applications/WorkBuddy.app/Contents/MacOS/Electron"
BC_REPO="/Users/zhaosiyuan/Projects/beautiCode"
PORT=9335

echo "[1/4] 退出 WorkBuddy（数据在 ~/.workbuddy/app，不受影响）…"
osascript -e 'tell application "WorkBuddy" to quit' 2>/dev/null || true
sleep 2

echo "[2/4] 带 CDP 重启 WorkBuddy…"
WORKBUDDY_REMOTE_DEBUGGING_PORT=$PORT "$WB_APP" >/dev/null 2>&1 &

echo "[3/4] 等 CDP 端口（最多 20 秒）…"
i=0
while [ $i -lt 20 ]; do
  if curl -s -m 1 "http://127.0.0.1:$PORT/json/version" >/dev/null 2>&1; then
    echo "      端口 $PORT 已开"; break
  fi
  i=$((i+1)); sleep 1
done
if [ $i -ge 20 ]; then echo "      ✗ 端口没开，WorkBuddy 可能没起来"; exit 1; fi

echo "[4/4] 编译 adapter 并起守护…"
cd "$BC_REPO"
./node_modules/.bin/tsc -p packages/adapter-workbuddy/tsconfig.json
echo "      守护运行中：侧栏会出现「自定义背景」；Ctrl+C 退出并自动清理"
node scripts/wb-cdp-runner.mjs