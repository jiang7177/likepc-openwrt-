#!/bin/sh
# WAN 口伪装成 Windows 电脑（随机主机名 + DHCP 指纹）
# 由 likepc.sh source，不单独运行

# 常见 PC 厂商 OUI（仅用于伪装，可自行修改）
PC_OUI_LIST="00:1B:21 00:14:22 00:1F:29 00:59:07 00:1F:C6 00:1E:33"

pc_prefix() {
	local p r

	p=$(uci -q get likepc.main.pc_prefix 2>/dev/null)
	case "$p" in
		LAPTOP|laptop) echo LAPTOP; return 0 ;;
		DESKTOP|desktop) echo DESKTOP; return 0 ;;
	esac

	r=$(rand_mod 2)
	if [ "$r" = "0" ]; then
		echo LAPTOP
	else
		echo DESKTOP
	fi
}

# LAPTOP-XXXXXXX（7 位随机大写字母数字）
# 每次调用生成一个新的，不落盘。电脑名只在两件事发生时才会变：
# 被拉黑自动换了 MAC，或者手动点了「换一个电脑身份」。
# 两件都不发生，它就一直是同一个 —— 没必要、也不应该每次重随机。
pc_hostname() {
	local prefix chars s i idx

	prefix=$(pc_prefix)
	chars="0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	s=""
	i=0

	while [ "$i" -lt 7 ]; do
		idx=$(rand_mod 36)
		s="$s$(echo "$chars" | cut -c$((idx + 1)))"
		i=$((i + 1))
	done

	echo "${prefix}-${s}"
}

# 换一个新的电脑名写进 WAN 口（调用方负责 commit network）
pc_newhost() {
	local iface host

	iface=$(wan_iface)
	[ -n "$iface" ] || return 0

	host=$(pc_hostname)
	uci -q set "network.$iface.hostname=$host"
	echo "$host"
	return 0
}

# 手动换一个全新的电脑身份：伪装开着就整个重来一遍
pc_newid() {
	if [ "$(uci -q get likepc.main.pc_fake 2>/dev/null)" = "1" ]; then
		pc_fake
	else
		log "还没开启 PC 伪装，先用「一键伪装 Windows 电脑」打开"
	fi

	return 0
}

pc_mac_random() {
	local list n idx i o

	list=$(uci -q get likepc.main.pc_mac_oui 2>/dev/null | tr ',' ' ')
	[ -z "$list" ] && list="$PC_OUI_LIST"

	n=0
	for o in $list; do
		n=$((n + 1))
	done
	[ "$n" -lt 1 ] && { gen_one_mac "00:1B:21"; return 0; }

	idx=$(rand_mod "$n")
	i=0
	for o in $list; do
		if [ "$i" = "$idx" ]; then
			gen_one_mac "$o"
			return 0
		fi
		i=$((i + 1))
	done

	gen_one_mac "00:1B:21"
}

pc_backup() {
	local iface

	[ -n "$(uci -q get likepc.main.pc_backup_done 2>/dev/null)" ] && return 0

	iface=$(wan_iface)

	uci -q set likepc.main.pc_backup_done='1'
	uci -q set likepc.main.pc_orig_hostname="$(uci -q get "network.$iface.hostname" 2>/dev/null)"
	uci -q set likepc.main.pc_orig_vendorid="$(uci -q get "network.$iface.vendorid" 2>/dev/null)"
	uci -q set likepc.main.pc_orig_clientid="$(uci -q get "network.$iface.clientid" 2>/dev/null)"
	uci -q set likepc.main.pc_orig_reqopts="$(uci -q get "network.$iface.reqopts" 2>/dev/null)"
	uci -q commit likepc

	log "已备份 WAN 原有 DHCP 参数"

	return 0
}

pc_fake() {
	local iface host mac

	iface=$(wan_iface)
	pc_backup

	host=$(pc_newhost)

	uci -q set "network.$iface.vendorid=MSFT 5.0"
	uci -q set "network.$iface.reqopts=1 3 6 15 31 33 43 44 46 47 119 121 249 252"

	mac=$(current_wan_mac)
	[ -z "$mac" ] && mac=$(uci -q get likepc.main.mac_original 2>/dev/null)
	if [ -n "$mac" ]; then
		uci -q set "network.$iface.clientid=01$(echo "$mac" | tr -d ':')"
	fi

	uci -q set likepc.main.pc_fake='1'
	uci -q commit likepc
	uci -q commit network

	if [ "$(uci -q get likepc.main.pc_random_mac 2>/dev/null)" = "1" ]; then
		local newmac
		newmac=$(pc_mac_random)
		log "同时把 WAN MAC 换成普通 PC 网卡风格：$newmac"
		mac_apply "$newmac"
	else
		/etc/init.d/network reload >/dev/null 2>&1
		sleep 2
		ifup "$iface" >/dev/null 2>&1
	fi

	log "已伪装成 Windows 电脑：主机名 ${host}、vendorid MSFT 5.0、clientid 01$(echo "$mac" | tr -d ':')"
	log "提示：UA 等流量层面的伪装建议继续用 ua3f，本插件只改 DHCP 特征"

	mac_write_info
	return 0
}

pc_restore() {
	local iface v

	iface=$(wan_iface)

	v=$(uci -q get likepc.main.pc_orig_hostname 2>/dev/null)
	if [ -n "$v" ]; then
		uci -q set "network.$iface.hostname=$v"
	else
		uci -q delete "network.$iface.hostname" 2>/dev/null
	fi

	v=$(uci -q get likepc.main.pc_orig_vendorid 2>/dev/null)
	if [ -n "$v" ]; then
		uci -q set "network.$iface.vendorid=$v"
	else
		uci -q delete "network.$iface.vendorid" 2>/dev/null
	fi

	v=$(uci -q get likepc.main.pc_orig_clientid 2>/dev/null)
	if [ -n "$v" ]; then
		uci -q set "network.$iface.clientid=$v"
	else
		uci -q delete "network.$iface.clientid" 2>/dev/null
	fi

	v=$(uci -q get likepc.main.pc_orig_reqopts 2>/dev/null)
	if [ -n "$v" ]; then
		uci -q set "network.$iface.reqopts=$v"
	else
		uci -q delete "network.$iface.reqopts" 2>/dev/null
	fi

	uci -q set likepc.main.pc_fake='0'
	uci -q commit likepc
	uci -q commit network

	/etc/init.d/network reload >/dev/null 2>&1
	sleep 2
	ifup "$iface" >/dev/null 2>&1

	log "已恢复 WAN 原有 DHCP 参数"
	mac_write_info
	return 0
}