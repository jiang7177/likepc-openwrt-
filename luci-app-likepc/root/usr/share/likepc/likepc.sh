#!/bin/sh
#===============================================================================
# 模拟pc (不含认证)  for OpenWrt / ImmortalWrt
#
# 这个是「自动认证」那套的衍生版：认证相关的部分全部去掉（门户探测、
# 提交表单、账号密码、认证重试……都没有），认证以外的东西原样保留：
#   外网检测、被拉黑换 WAN MAC、一键防火墙规则、一键伪装 Windows 电脑、
#   连续失败告警、开机运行 / 防掉线检测。
#
# 用法: likepc.sh <命令>
#   check       检测外网连通性
#   recover     检测外网；不通且开了自动换 MAC 时，轮换 MAC 后再检测
#   once        等待启动延迟后检测一轮(开机单次模式)
#   daemon      常驻运行，按间隔检测外网，连续不通时按开关换 MAC / 告警
#   status      打印网络状态
#   genmac      重新生成 5 个 WAN MAC
#   macnext     立即切换到 MAC 池中的下一个(首次则应用第一个)
#   macrestore  恢复 WAN 原始 MAC
#   fwadd/fwdel/fwshow     一键添加 / 移除 / 查看防火墙规则(自动判断 fw3 / fw4)
#                          fw3 -> iptables 脚本；fw4 -> firewall.include(nftables)
#   fwadd4/fwdel4          只操作 firewall4(nftables) 那一份规则
#   deps/depinstall        检测 / 安装缺失的扩展
#   pcfake/pcrestore       一键伪装成 Windows 电脑 / 恢复原始参数
#   pcnewid     换一个新的电脑名（伪装状态下重新生成一次）
#   harden      出网特征体检：列出「从外面看不像电脑」的地方
#   hd-ipv6 / hd-ipv6-undo          关掉 IPv6（含前缀请求）/ 恢复
#   hd-offload / hd-offload-undo    关掉流量卸载与限速 / 恢复
#   hd-sig / hd-sig-undo            统一出网特征 TTL+MSS / 撤销
#   hd-dhcp / hd-dhcp-undo          伪装 DHCP 指纹 / 恢复
#   hd-quiet / hd-quiet-undo        掐掉定时联网的服务 / 恢复
#   hd-routing / hd-routing-undo    关掉 OSPF/RIP/BGP/PIM/IGMP 与 IGMP 嗅探 / 恢复
#   applyall    一键应用(防火墙 + 伪装 + MAC 池)，然后检测一次外网
#   alertclear  清除「连续检测失败」告警，计数归零
#   info        输出环境信息给界面
#
# 配置: /etc/config/likepc（由 LuCI「服务 -> 模拟pc」写入）
#===============================================================================

. /lib/functions.sh

CONF=likepc
SECTION=main
LIB_DIR=/usr/share/likepc

LOG_FILE=/tmp/likepc.log
STATE_FILE=/tmp/likepc.state
ALERT_FILE=/tmp/likepc.alert
FAILS_FILE=/tmp/likepc.fails

PING_HOST="119.29.29.29"
PING_HOSTS="119.29.29.29"
PING_COUNT=1
PING_TIMEOUT=3
CHECK_INTERVAL=30
FAIL_THRESHOLD=3
START_DELAY=15
ALERT_ENABLE=1
ALERT_THRESHOLD=3

MAC_POOL=""
MAC_COUNT=0
MAC_INDEX=0
MAC_AUTO=0
MAC_MAX_ROTATE=5
MAC_COOLDOWN=600
MAC_SETTLE=10

for lib in mac fw pc harden; do
	[ -f "$LIB_DIR/$lib.sh" ] && . "$LIB_DIR/$lib.sh"
done

#--------------------------------------------------------------- 基础工具函数
num() {
	case "$1" in
		''|*[!0-9]*) echo "$2" ;;
		*) echo "$1" ;;
	esac
}

log() {
	logger -t likepc "$*"
	printf '%s [%s] %s\n' "$$" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"

	local size
	size=$(wc -c <"$LOG_FILE" 2>/dev/null)
	if [ -n "$size" ] && [ "$size" -gt 32768 ]; then
		tail -n 300 "$LOG_FILE" >"$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
	fi
}

set_state() {
	printf 'status=%s\nmessage=%s\ntime=%s\n' "$1" "$2" "$(date '+%Y-%m-%d %H:%M:%S')" >"$STATE_FILE"

	# 只要外网恢复正常，就把连续失败计数和告警清掉
	[ "$1" = "ok" ] && alert_reset

	return 0
}

#--------------------------------------------------------------- 失败告警
# 连续检测失败次数记在 /tmp/likepc.fails；
# 达到阈值后写一份 /tmp/likepc.alert 给 LuCI 顶部横幅显示。
fails_get() {
	local n

	n=$(cat "$FAILS_FILE" 2>/dev/null)
	case "$n" in
		''|*[!0-9]*) echo 0 ;;
		*) echo "$n" ;;
	esac
}

alert_reset() {
	# 什么都没有的时候不折腾磁盘
	[ -f "$FAILS_FILE" ] || [ -f "$ALERT_FILE" ] || return 0

	rm -f "$FAILS_FILE" "$ALERT_FILE" 2>/dev/null
	return 0
}

# 一轮检测仍不通时调用：累加连续失败次数，够阈值就生成告警
alert_fail() {
	local n level msg

	n=$(fails_get)
	n=$((n + 1))
	echo "$n" >"$FAILS_FILE" 2>/dev/null

	if [ "$ALERT_ENABLE" != "1" ]; then
		rm -f "$ALERT_FILE" 2>/dev/null
		return 0
	fi

	[ "$n" -ge "$ALERT_THRESHOLD" ] || return 0

	if [ "$n" -ge $((ALERT_THRESHOLD * 3)) ]; then
		level=crit
		msg="已连续 ${n} 次检测到外网不通，仍未恢复，请检查线路或校园网状态"
	else
		level=warn
		msg="已连续 ${n} 次检测到外网不通"
	fi

	{
		printf 'level=%s\n' "$level"
		printf 'count=%s\n' "$n"
		printf 'message=%s\n' "$msg"
		printf 'time=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
	} >"$ALERT_FILE"

	return 0
}

load_config() {
	config_load "$CONF" 2>/dev/null

	config_get PING_HOST "$SECTION" ping_host "119.29.29.29"
	config_get PING_COUNT "$SECTION" ping_count 1
	config_get PING_TIMEOUT "$SECTION" ping_timeout 3
	config_get CHECK_INTERVAL "$SECTION" check_interval 30
	config_get FAIL_THRESHOLD "$SECTION" fail_threshold 3
	config_get START_DELAY "$SECTION" start_delay 15
	config_get ALERT_ENABLE "$SECTION" alert_enable 1
	config_get ALERT_THRESHOLD "$SECTION" alert_threshold 3

	PING_COUNT=$(num "$PING_COUNT" 1)
	PING_TIMEOUT=$(num "$PING_TIMEOUT" 3)
	CHECK_INTERVAL=$(num "$CHECK_INTERVAL" 30)
	FAIL_THRESHOLD=$(num "$FAIL_THRESHOLD" 3)
	START_DELAY=$(num "$START_DELAY" 15)
	ALERT_ENABLE=$(num "$ALERT_ENABLE" 1)
	ALERT_THRESHOLD=$(num "$ALERT_THRESHOLD" 3)

	[ "$PING_COUNT" -lt 1 ] && PING_COUNT=1
	[ "$FAIL_THRESHOLD" -lt 1 ] && FAIL_THRESHOLD=1
	[ "$CHECK_INTERVAL" -lt 5 ] && CHECK_INTERVAL=5
	[ "$ALERT_THRESHOLD" -lt 1 ] && ALERT_THRESHOLD=1

	PING_HOSTS=$(echo "$PING_HOST" | tr ',\t' '  ')
	[ -z "$PING_HOSTS" ] && PING_HOSTS="119.29.29.29"
}

# 检测外网：只要有一个检测地址能 ping 通就算在线
check_net() {
	local host

	for host in $PING_HOSTS; do
		ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$host" >/dev/null 2>&1 && return 0
	done

	return 1
}

#-------------------------------------------------------------- 检测与恢复
# 检测一轮：外网通就记录正常；不通就累加失败计数（够阈值出告警），
# 并按开关决定要不要轮换 WAN MAC 再试。
net_round() {
	local round=0

	if check_net; then
		log "外网正常"
		set_state ok "外网正常"
		return 0
	fi

	log "外网不通"
	alert_fail
	set_state fail "外网不通"

	[ "$MAC_AUTO" = "1" ] || return 1

	while [ "$round" -lt "$MAC_MAX_ROTATE" ]; do
		# 冷却中 / MAC 池不够时 mac_rotate_auto 会返回失败，本次就不再换
		mac_rotate_auto || return 1

		round=$((round + 1))
		log "已更换 WAN MAC，重新检测外网（第 ${round} 次更换）"

		if check_net; then
			log "换 MAC 后外网已恢复"
			set_state ok "换 MAC 后外网恢复"
			return 0
		fi
	done

	log "已连续更换 ${round} 次 MAC 仍未恢复，暂停（等下一轮检测）"
	set_state fail "外网不通（已换 ${round} 次 MAC）"
	return 1
}

cmd_recover() {
	load_config
	mac_pool_load
	mac_init
	net_round
}

cmd_once() {
	load_config
	mac_pool_load

	if [ "$START_DELAY" -gt 0 ]; then
		log "等待 ${START_DELAY} 秒后开始检测"
		sleep "$START_DELAY"
	fi

	net_round
}

cmd_daemon() {
	local fails=0 first=1

	load_config
	mac_pool_load
	log "防掉线守护进程启动：检测间隔 ${CHECK_INTERVAL}s，连续 ${FAIL_THRESHOLD} 次不通后按开关处理（换 MAC / 告警）"

	trap 'log "防掉线守护进程退出"; exit 0' TERM INT

	if [ "$START_DELAY" -gt 0 ]; then
		log "等待 ${START_DELAY} 秒后开始检测"
		sleep "$START_DELAY"
	fi

	while :; do
		if check_net; then
			[ "$first" = "1" ] && log "外网正常"
			first=0
			fails=0
			alert_reset
			set_state ok "外网正常"
			mac_write_state
		else
			if [ "$first" = "1" ]; then
				# 刚开机 WAN 可能还没起来，先不急着处理，等下一轮再判断
				first=0
				fails=0
				log "刚启动时外网不通，等下一轮检测再判断"
			else
				fails=$((fails + 1))
				log "外网不通（连续第 ${fails} 次检测）"
				if [ "$fails" -ge "$FAIL_THRESHOLD" ]; then
					fails=0
					log "连续 ${FAIL_THRESHOLD} 次不通，开始处理"
					net_round
				fi
			fi
		fi

		sleep "$CHECK_INTERVAL"
	done
}

cmd_check() {
	load_config

	if check_net; then
		echo "network=ok"
		set_state ok "外网正常"
		return 0
	fi

	echo "network=fail"
	set_state fail "外网不通"
	return 1
}

cmd_status() {
	load_config
	mac_pool_load

	if check_net; then
		echo "network=ok"
	else
		echo "network=fail"
	fi

	[ -f "$STATE_FILE" ] && cat "$STATE_FILE"
	mac_write_state
	[ -f "$MAC_STATE" ] && cat "$MAC_STATE"

	return 0
}

#-------------------------------------------------------------- MAC 相关命令
cmd_genmac() {
	load_config
	mac_pool_load
	mac_gen_pool
	mac_pool_load
	mac_write_state
	mac_write_info
	return 0
}

cmd_macnext() {
	local cur

	load_config
	mac_pool_load

	if [ "$MAC_COUNT" -eq 0 ]; then
		log "MAC 池为空，先生成 5 个 MAC"
		mac_gen_pool
		mac_pool_load
	fi

	cur=$(current_wan_mac)
	case " $(echo $MAC_POOL) " in
		*" $cur "*)
			MAC_INDEX=$(( (MAC_INDEX + 1) % MAC_COUNT ))
			uci -q set likepc.main.mac_index="$MAC_INDEX"
			uci -q commit likepc
			;;
		*)
			# 当前 MAC 不在池里，直接应用当前这一个
			;;
	esac

	mac_apply "$(mac_wanted)"
	date +%s >"$MAC_TS"
	mac_write_state
	mac_write_info
	return 0
}

cmd_macrestore() {
	load_config
	mac_pool_load
	mac_restore
	mac_write_info
	return 0
}

#-------------------------------------------------------------- 防火墙命令
cmd_fwadd() {
	load_config
	fw_add
	mac_write_info
	return 0
}

cmd_fwdel() {
	load_config
	fw_del
	return 0
}

cmd_fwshow() {
	load_config
	fw_show
	return 0
}

cmd_fwadd4() {
	load_config
	fw4_add
	return 0
}

cmd_fwdel4() {
	load_config
	fw4_del
	return 0
}

cmd_deps() {
	load_config
	mac_pool_load
	deps_check
	mac_write_info
	return 0
}

cmd_depinstall() {
	load_config
	deps_install
	mac_write_info
	return 0
}

#-------------------------------------------------------------- 伪装 PC 命令
cmd_pcfake() {
	load_config
	mac_pool_load
	pc_fake
	return 0
}

cmd_pcrestore() {
	load_config
	mac_pool_load
	pc_restore
	return 0
}

#-------------------------------------------------------------- 出网特征加固
cmd_harden() {
	load_config
	mac_pool_load
	hd_report
	return 0
}

cmd_hd_ipv6() {
	load_config
	mac_pool_load
	hd_ipv6
	return 0
}

cmd_hd_ipv6_undo() {
	load_config
	mac_pool_load
	hd_ipv6_undo
	return 0
}

cmd_hd_offload() {
	load_config
	mac_pool_load
	hd_offload
	return 0
}

cmd_hd_offload_undo() {
	load_config
	mac_pool_load
	hd_offload_undo
	return 0
}

cmd_hd_sig() {
	load_config
	mac_pool_load
	hd_sig
	return 0
}

cmd_hd_sig_undo() {
	load_config
	mac_pool_load
	hd_sig_undo
	return 0
}

cmd_hd_dhcp() {
	load_config
	mac_pool_load
	hd_dhcp
	return 0
}

cmd_hd_dhcp_undo() {
	load_config
	mac_pool_load
	hd_dhcp_undo
	return 0
}

cmd_hd_quiet() {
	load_config
	mac_pool_load
	hd_quiet
	return 0
}

cmd_hd_quiet_undo() {
	load_config
	mac_pool_load
	hd_quiet_undo
	return 0
}

cmd_hd_routing() {
	load_config
	mac_pool_load
	hd_routing
	return 0
}

cmd_hd_routing_undo() {
	load_config
	mac_pool_load
	hd_routing_undo
	return 0
}

cmd_pcnewid() {
	load_config
	mac_pool_load
	pc_newid
	return 0
}

#------------------------------------------------------------------ 组合命令
cmd_applyall() {
	load_config
	mac_pool_load

	log "==== 一键应用开始 ===="

	if [ "$(fw_version)" = "3" ]; then
		fw_add
	elif [ "$(fw_version)" = "4" ]; then
		log "检测到 firewall4，改用 nft 兼容规则"
		fw4_add
	fi

	pc_fake

	if [ "$MAC_AUTO" = "1" ]; then
		mac_init
	else
		log "防拉黑换 MAC 未启用，跳过应用 MAC 池"
	fi

	log "==== 一键应用结束，开始检测外网 ===="

	net_round
}

cmd_alertclear() {
	load_config
	alert_reset
	log "已清除外网不通告警，连续失败计数归零"
	mac_write_info
	return 0
}

cmd_info() {
	load_config
	mac_pool_load
	mac_write_state
	mac_write_info
	return 0
}

cmd_usage() {
	echo "用法: likepc.sh <命令>"
	echo "  check       检测外网连通性"
	echo "  recover     检测外网；不通且开了自动换 MAC 时轮换 MAC 后再检测"
	echo "  once        等待启动延迟后检测一轮"
	echo "  daemon      常驻检测（防掉线）"
	echo "  status      打印网络状态"
	echo "  genmac | macnext | macrestore         MAC 池管理"
	echo "  fwadd | fwdel | fwshow | fwadd4 | fwdel4"
	echo "  deps | depinstall | pcfake | pcrestore | pcnewid | applyall | alertclear | info"
	echo "  harden                                出网特征体检"
	echo "  hd-ipv6 | hd-offload | hd-sig | hd-dhcp | hd-quiet | hd-routing      逐项加固"
	echo "  hd-ipv6-undo | hd-offload-undo | hd-sig-undo | hd-dhcp-undo | hd-quiet-undo"
	echo "  hd-routing-undo"
	return 1
}

case "$1" in
	check)      cmd_check ;;
	recover)    cmd_recover ;;
	once)       cmd_once ;;
	daemon)     cmd_daemon ;;
	status)     cmd_status ;;
	genmac)     cmd_genmac ;;
	macnext)    cmd_macnext ;;
	macrestore) cmd_macrestore ;;
	fwadd)      cmd_fwadd ;;
	fwdel)      cmd_fwdel ;;
	fwshow)     cmd_fwshow ;;
	fwadd4)     cmd_fwadd4 ;;
	fwdel4)     cmd_fwdel4 ;;
	deps)       cmd_deps ;;
	depinstall) cmd_depinstall ;;
	pcfake)     cmd_pcfake ;;
	pcrestore)  cmd_pcrestore ;;
	pcnewid)    cmd_pcnewid ;;
	harden)     cmd_harden ;;
	hd-ipv6)         cmd_hd_ipv6 ;;
	hd-ipv6-undo)    cmd_hd_ipv6_undo ;;
	hd-offload)      cmd_hd_offload ;;
	hd-offload-undo) cmd_hd_offload_undo ;;
	hd-sig)          cmd_hd_sig ;;
	hd-sig-undo)     cmd_hd_sig_undo ;;
	hd-dhcp)         cmd_hd_dhcp ;;
	hd-dhcp-undo)    cmd_hd_dhcp_undo ;;
	hd-quiet)        cmd_hd_quiet ;;
	hd-quiet-undo)   cmd_hd_quiet_undo ;;
	hd-routing)      cmd_hd_routing ;;
	hd-routing-undo) cmd_hd_routing_undo ;;
	applyall)   cmd_applyall ;;
	alertclear) cmd_alertclear ;;
	info)       cmd_info ;;
	*)          cmd_usage ;;
esac

exit $?