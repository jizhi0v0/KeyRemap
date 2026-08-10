#!/bin/sh
#
# 集成测试。不需要 root，不改动真实键盘的映射。
#
#   sh Tests/run.sh              构建后跑全部
#   SKIP_BUILD=1 sh Tests/run.sh 用已有的 build/KeyRemap.app
#
# 覆盖的历史故障：
#   · 1.0.1 修的：daemon 用「抠出来的可执行文件」导致签名失效，launchd exec 时被
#     CS_KILL 杀掉（last exit reason = OS_REASON_EXEC）→ 这里断言 bundle 副本能起来
#   · 1.0.2 修的：没指定 deployment target，二进制 minos 等于构建机系统版本，
#     在低版本 macOS 上报 “is damaged” → 这里断言 minos 与 Info.plist 一致
#   · 1.0.4 / 1.0.5 修的：空规则的保存与清空语义 → 在 --selftest 里断言

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/KeyRemap.app"
EXEC="$APP/Contents/MacOS/KeyRemap"
WANT_MIN_OS=14.0
TMP="$(mktemp -d)"
UID_NUM="$(id -u)"
PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  ✗ %s%s\n' "$1" "${2:+  —— $2}"; }
skip() { printf '  ~ %s（跳过：%s）\n' "$1" "$2"; }
check() { if [ "$1" = "0" ]; then ok "$2"; else bad "$2" "${3:-}"; fi; }

cleanup() {
	launchctl bootout "gui/$UID_NUM/local.KRIntegrationA" 2>/dev/null
	launchctl bootout "gui/$UID_NUM/local.KRIntegrationB" 2>/dev/null
	rm -f "$HOME/Library/LaunchAgents/local.KRIntegration"*.plist
	rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

if [ "${SKIP_BUILD:-}" != "1" ]; then
	echo "构建"
	if sh "$ROOT/build.sh" >"$TMP/build.log" 2>&1; then ok "build.sh 成功"
	else bad "build.sh 失败" "见 $TMP/build.log"; cat "$TMP/build.log"; exit 1; fi
fi
[ -x "$EXEC" ] || { bad "找不到 $EXEC"; exit 1; }

echo "构建产物"
archs="$(lipo -archs "$EXEC" 2>/dev/null)"
case "$archs" in *arm64*) ok "含 arm64 slice" ;; *) bad "缺 arm64 slice" "$archs" ;; esac
case "$archs" in *x86_64*) ok "含 x86_64 slice" ;; *) bad "缺 x86_64 slice" "$archs" ;; esac

# 每个 slice 的 minos 都要等于 Info.plist 声明的最低系统版本
bad_minos=""
for v in $(otool -l "$EXEC" | awk '/minos/{print $2}'); do
	[ "$v" = "$WANT_MIN_OS" ] || bad_minos="$bad_minos $v"
done
[ -z "$bad_minos" ] && ok "所有 slice 的 minos 都是 $WANT_MIN_OS" \
	|| bad "有 slice 的 minos 不对" "$bad_minos"
plist_min="$(plutil -extract LSMinimumSystemVersion raw "$APP/Contents/Info.plist" 2>/dev/null)"
[ "$plist_min" = "$WANT_MIN_OS" ] && ok "Info.plist 的 LSMinimumSystemVersion 与二进制一致" \
	|| bad "Info.plist 声明与二进制不一致" "plist=$plist_min binary=$WANT_MIN_OS"

codesign --verify --strict "$APP" 2>/dev/null
check $? "app bundle 签名有效"

echo "daemon 载荷的签名"
ditto "$APP" "$TMP/copy.app"
codesign --verify --strict "$TMP/copy.app" 2>/dev/null
check $? "整个 bundle 拷走后签名依然有效（daemon 就是这样安装的）"
cp "$EXEC" "$TMP/loose-exec"
if codesign --verify --strict "$TMP/loose-exec" 2>/dev/null; then
	printf '  ~ 单独拷可执行文件时签名居然有效（ad-hoc 构建下如此，不影响结论）\n'
else
	ok "单独拷可执行文件会让签名失效 —— 这正是必须拷整个 bundle 的原因"
fi

echo "纯逻辑自测"
if "$EXEC" --selftest >"$TMP/selftest.log" 2>&1; then
	ok "--selftest 全部通过（$(grep -c '✓' "$TMP/selftest.log") 项）"
else
	bad "--selftest 有失败项"; grep '✗' "$TMP/selftest.log"
fi

echo "daemon 能被 launchd 拉起并常驻"
# 用一个不存在的设备（PID 0xFFFE）作为规则目标，绝不碰真实键盘
cat > "$TMP/rules.json" <<'JSON'
{
  "version": 1,
  "rules": [
    {
      "deviceID": "ext:65534",
      "label": "ghost",
      "matches": ["{\"Built-In\":0,\"PrimaryUsage\":6,\"PrimaryUsagePage\":1,\"ProductID\":65534}"],
      "srcUsage": 230,
      "dstUsage": 38
    }
  ]
}
JSON

agent() {   # $1=label  $2=program
	cat > "$HOME/Library/LaunchAgents/local.KRIntegration$1.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>local.KRIntegration$1</string>
	<key>ProgramArguments</key><array><string>$2</string><string>--daemon</string></array>
	<key>EnvironmentVariables</key><dict><key>KEYREMAP_RULES</key><string>$TMP/rules.json</string></dict>
	<key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
	mkdir -p "$HOME/Library/LaunchAgents"
	launchctl bootout "gui/$UID_NUM/local.KRIntegration$1" 2>/dev/null
	launchctl bootstrap "gui/$UID_NUM" "$HOME/Library/LaunchAgents/local.KRIntegration$1.plist"
}

state() { launchctl print "gui/$UID_NUM/local.KRIntegration$1" 2>/dev/null | awk -F' = ' '/^\tstate/{print $2}'; }
reason() { launchctl print "gui/$UID_NUM/local.KRIntegration$1" 2>/dev/null | grep 'last exit reason' | head -1; }

agent A "$TMP/copy.app/Contents/MacOS/KeyRemap"
sleep 3
[ "$(state A)" = "running" ] && ok "bundle 副本：state = running" \
	|| bad "bundle 副本没跑起来" "state=$(state A) $(reason A)"

# 再等两轮巡检（3 秒一轮），确认它不是起来就崩
sleep 7
[ "$(state A)" = "running" ] && ok "10 秒后仍在运行（没有崩溃重启循环）" \
	|| bad "daemon 没能常驻" "state=$(state A) $(reason A)"

agent B "$TMP/loose-exec"
sleep 3
if [ "$(state B)" = "running" ]; then
	printf '  ~ 单独拷的可执行文件也能跑（说明本次构建是 ad-hoc 签名）\n'
else
	ok "单独拷的可执行文件起不来：$(reason B | tr -d '\t')"
fi

echo "全局映射未被测试污染"
[ -z "$(hidutil property --get UserKeyMapping | tr -d '() \n\t')" ] \
	&& ok "全局 UserKeyMapping 仍为空" || bad "测试污染了全局映射"

printf '\n%s\n' "通过 $PASS，失败 $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
