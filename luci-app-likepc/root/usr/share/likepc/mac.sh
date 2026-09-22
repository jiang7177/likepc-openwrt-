#!/bin/sh
# WAN MAC 生成 / 应用 / 轮换（防拉黑）
# 由 likepc.sh source，不单独运行

MAC_STATE=/tmp/likepc.mac
MAC_INFO=/tmp/likepc.info
MAC_TS=/tmp/likepc.mac-ts
MAC_HISTORY=/etc/likepc/mac-history

# ------------------------------------------------------------ 随机数工具
# 用内核 UUID 取随机十六进制，避免依赖 od / hexdump
RND_SEQ_FILE=/tmp/.likepc-rnd

# 取一个自增序号。rnd_hex 每次都在子 shell 里跑，变量存不住，
# 所以用文件记数：保证同一秒内的连续调用也不会拿到相同的种子。
rnd_seq() {
	local c

	c=$(cat "$RND_SEQ_FILE" 2>/dev/null)
	case "$c" in
		''|*[!0-9]*) c=0 ;;
	esac

	c=$((c + 1))
	[ "$c" -gt 1000000 ] && c=1

	echo "$c" >"$RND_SEQ_FILE" 2>/dev/null
	echo "$c"
}

rnd_hex() {
	local n="$1" u

	u=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | sed 's/[^0-9a-fA-F]//g')
	if [ -z "$u" ]; then
		u=$(awk -v t="$(date +%s)" -v p="$$" -v s="$(rnd_seq)" \
			'BEGIN{srand(t * 1000 + p * 7 + s);printf "%08x%08x", int(rand()*4294967295), int(rand()*4294967295)}' 2>/dev/null)
	fi
	if [ -z "$u" ]; then
		u=$(printf '%08x%08x' "$(( $(rnd_seq) * 2654435761 % 4294967295 ))" "$$")
	fi
	[ -z "$u" ] && u="0123456789abcdef"

	echo "$u" | cut -c1-"$n"
}

# 安全的 0..n-1 随机数
rand_mod() {
	local n="$1" h

	[ "$n" -gt 0 ] 2>/dev/null || { echo 0; return 0; }

	h=$(rnd_hex 2)
	case "$h" in
		[0-9a-fA-F][0-9a-fA-F]) ;;
		*) h="00" ;;
	esac

	echo $(( (0x$h) % n ))
}

# 每台设备唯一的因子（混进随机 MAC，两台设备同时生成也不会相同）
device_xor() {
	local seed x

	seed=$(cat /etc/machine-id 2>/dev/null)
	[ -z "$seed" ] && seed=$(ip link show dev br-lan 2>/dev/null | awk '/link\/ether/{print $2; exit}')
	[ -z "$seed" ] && seed=$(ip link show 2>/dev/null | awk '/link\/ether/{print $2; exit}')
	[ -z "$seed" ] && seed=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
	[ -z "$seed" ] && seed=$(hostname 2>/dev/null)

	x=$(echo "$seed" | cksum 2>/dev/null | awk '{print $1}')
	case "$x" in
		''|*[!0-9]*) x=0 ;;
	esac

	echo $(( x % 256 ))
}

is_hex2() {
	case "$1" in
		[0-9a-fA-F][0-9a-fA-F]) return 0 ;;
		*) return 1 ;;
	esac
}

# ------------------------------------------------------------ OUI / MAC 生成
# 随机挑一个前缀（默认螃蟹 Realtek 00:e0:4c）
pick_oui() {
	local list n idx o i

	list=$(uci -q get likepc.main.mac_oui 2>/dev/null | tr ',' ' ')
	[ -z "$list" ] && list="00:e0:4c"

	n=0
	for o in $list; do n=$((n + 1)); done
	[ "$n" -lt 1 ] && n=1

	idx=$(rand_mod "$n")
	i=0
	for o in $list; do
		if [ "$i" = "$idx" ]; then
			echo "$o"
			return 0
		fi
		i=$((i + 1))
	done

	echo "$list" | awk '{print $1}'
}

# 生成一个 MAC：OUI + 3 字节随机（第三字节与设备因子异或，保证跨设备不同）
gen_one_mac() {
	local oui="$1" xor r b1 b2 b3 tries

	[ -z "$oui" ] && oui="00:e0:4c"
	xor=$(device_xor)
	tries=0

	while [ "$tries" -lt 30 ]; do
		tries=$((tries + 1))
		r=$(rnd_hex 6)
		b1=$(echo "$r" | cut -c1-2)
		b2=$(echo "$r" | cut -c3-4)
		b3=$(echo "$r" | cut -c5-6)

		is_hex2 "$b1" || continue
		is_hex2 "$b2" || continue
		is_hex2 "$b3" || continue

		b3=$(printf '%02x' $(( (0x$b3 ^ xor) & 0xff )))
		[ "$b1$b2$b3" = "000000" ] && continue

		echo "${oui}:${b1}:${b2}:${b3}"
		return 0
	done

	echo "${oui}:$(rnd_hex 2):$(rnd_hex 2):$(rnd_hex 2)"
}

mac_history_add() {
	local m

	mkdir -p /etc/likepc
	for m in $1; do
		echo "$m" >>"$MAC_HISTORY"
	done
	tail -n 50 "$MAC_HISTORY" >"$MAC_HISTORY.tmp" 2>/dev/null && mv "$MAC_HISTORY.tmp" "$MAC_HISTORY"
}

mac_history_list() {
	[ -f "$MAC_HISTORY" ] && cat "$MAC_HISTORY" 2>/dev/null
}

# 重新生成 5 个 MAC（互不相同，且与历史不重复）
mac_gen_pool() {
	local oui pool m i guard known

	oui=$(pick_oui)
	pool=""
	i=0
	guard=0
	known=$(mac_history_list | tr '\n' ' ')

	# 取满 5 个互不相同（且不在历史里）的 MAC 才停手
	while [ "$i" -lt 5 ] && [ "$guard" -lt 300 ]; do
		guard=$((guard + 1))
		m=$(gen_one_mac "$oui")
		[ -n "$m" ] || continue

		case " $pool $known " in
			*" $m "*) continue ;;
		esac

		pool="$pool $m"
		i=$((i + 1))
	done

	[ "$i" -lt 5 ] && log "警告：只生成了 $i 个不重复的 MAC（随机源可能不可用）"

	uci -q delete likepc.main.mac_pool
	for m in $pool; do
		uci -q add_list likepc.main.mac_pool="$m"
	done
	uci -q set likepc.main.mac_index='0'
	uci -q commit likepc

	mac_history_add "$pool"

	log "已生成 5 个 WAN MAC（前缀 ${oui}）：$(echo $pool | tr ' ' ',')"
	log "提示：点“立即切换到下一个 MAC”即可马上启用其中一个。"
}

# ------------------------------------------------------------ WAN 设备识别
wan_device() {
	local conf dev

	conf=$(uci -q get likepc.main.wan_device 2>/dev/null)
	case "$conf" in
		''|auto|自动) ;;
		*) echo "$conf"; return 0 ;;
	esac

	dev=$(ubus -S call network.interface.wan status 2>/dev/null | grep -o '"device": *"[^"]*"' | head -1 | cut -d'"' -f4)
	case "$dev" in
		''|lo) dev="" ;;
	esac
	if [ -z "$dev" ]; then
		dev=$(ubus -S call network.interface.wan status 2>/dev/null | grep -o '"l3_device": *"[^"]*"' | head -1 | cut -d'"' -f4)
		case "$dev" in
			''|lo) dev="" ;;
		esac
	fi

	if [ -z "$dev" ]; then
		dev=$(ip route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
	fi

	case "$dev" in
		pppoe-*|ppp*)
			dev=$(uci -q get network.wan.device 2>/dev/null)
			[ -z "$dev" ] && dev=$(uci -q get network.wan.ifname 2>/dev/null)
			;;
	esac

	echo "$dev"
}

wan_iface() {
	local s want

	s=$(uci -q get likepc.main.wan_iface 2>/dev/null)
	case "$s" in
		''|auto|自动) ;;
		*) echo "$s"; return 0 ;;
	esac

	if [ -n "$(uci -q get network.wan.proto 2>/dev/null)" ]; then
		echo wan
		return 0
	fi

	want=$(wan_device)
	if [ -n "$want" ]; then
		for s in $(uci -q show network 2>/dev/null | grep '=interface$' | cut -d. -f2 | cut -d= -f1); do
			case "$(uci -q get network.$s.device 2>/dev/null)$(uci -q get network.$s.ifname 2>/dev/null)" in
				*"$want"*) echo "$s"; return 0 ;;
			esac
		done
	fi

	echo wan
}

current_wan_mac() {
	local dev

	dev=$(wan_device)
	[ -z "$dev" ] && return 1

	ip link show dev "$dev" 2>/dev/null | awk '/link\/ether/{print $2; exit}'
}

network_device_section() {
	local dev="$1" id

	for id in $(uci -q show network 2>/dev/null | grep '=device$' | cut -d. -f2 | cut -d= -f1); do
		if [ "$(uci -q get network.$id.name 2>/dev/null)" = "$dev" ]; then
			echo "$id"
			return 0
		fi
	done

	return 1
}

# ------------------------------------------------------------ MAC 池读写
_mac_pool_add() {
	MAC_POOL="$MAC_POOL $1"
}

mac_pool_load() {
	local s m

	config_load likepc 2>/dev/null
	MAC_POOL=""
	config_list_foreach main mac_pool _mac_pool_add 2>/dev/null

	if [ -z "$(echo $MAC_POOL)" ]; then
		config_get s main mac_pool ""
		MAC_POOL=$(echo "$s" | tr ',' ' ')
	fi

	MAC_COUNT=0
	for m in $MAC_POOL; do
		MAC_COUNT=$((MAC_COUNT + 1))
	done

	MAC_INDEX=$(num "$(uci -q get likepc.main.mac_index)" 0)
	[ "$MAC_COUNT" -gt 0 ] && [ "$MAC_INDEX" -ge "$MAC_COUNT" ] && MAC_INDEX=0

	MAC_AUTO=$(num "$(uci -q get likepc.main.mac_auto)" 0)
	MAC_MAX_ROTATE=$(num "$(uci -q get likepc.main.mac_max_rotate)" 5)
	MAC_COOLDOWN=$(num "$(uci -q get likepc.main.mac_cooldown)" 600)
	MAC_SETTLE=$(num "$(uci -q get likepc.main.mac_settle)" 10)

	[ "$MAC_MAX_ROTATE" -lt 1 ] && MAC_MAX_ROTATE=1
	[ "$MAC_INDEX" -lt 0 ] && MAC_INDEX=0

	return 0
}

mac_wanted() {
	local i=0 m

	for m in $MAC_POOL; do
		if [ "$i" = "$MAC_INDEX" ]; then
			echo "$m"
			return 0
		fi
		i=$((i + 1))
	done

	echo $MAC_POOL | awk '{print $1}'
}

mac_write_state() {
	local dev cur orig

	dev=$(wan_device)
	cur=$(current_wan_mac)
	[ -z "$cur" ] && cur=$(cat "/sys/class/net/$dev/address" 2>/dev/null)
	orig=$(uci -q get likepc.main.mac_original 2>/dev/null)

	{
		printf 'device=%s\n' "$dev"
		printf 'current=%s\n' "$cur"
		printf 'original=%s\n' "$orig"
		printf 'index=%s\n' "${MAC_INDEX:-0}"
		printf 'count=%s\n' "${MAC_COUNT:-0}"
		printf 'pool=%s\n' "$(echo $MAC_POOL | tr ' ' ',')"
		printf 'time=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
	} >"$MAC_STATE"

	return 0
}

mac_write_info() {
	local fw dev

	fw=$(fw_version 2>/dev/null)
	[ -z "$fw" ] && fw=0
	dev=$(wan_device)

	# 顺便刷新「缺什么依赖」，界面要靠它弹提示
	command -v deps_write >/dev/null 2>&1 && deps_write

	{
		printf 'fw_ver=%s\n' "$fw"
		printf 'fw_name=%s\n' "$(fw_name 2>/dev/null)"
		printf 'fw_desc=%s\n' "$(fw_desc 2>/dev/null)"
		printf 'fw_rules=%s\n' "$(fw_rules_present 2>/dev/null && echo 1 || echo 0)"
		printf 'iptables=%s\n' "$(command -v iptables >/dev/null 2>&1 && echo 1 || echo 0)"
		printf 'nft=%s\n' "$(command -v nft >/dev/null 2>&1 && echo 1 || echo 0)"
		printf 'string=%s\n' "$(fw_string_ok 2>/dev/null && echo 1 || echo 0)"
		printf 'ttl=%s\n' "$(fw_ttl_ok 2>/dev/null && echo 1 || echo 0)"
		printf 'wan_device=%s\n' "$dev"
		printf 'wan_mac=%s\n' "$(current_wan_mac)"
		printf 'wan_host=%s\n' "$(uci -q get network.$(wan_iface).hostname 2>/dev/null)"
		printf 'pc_fake=%s\n' "$(uci -q get likepc.main.pc_fake 2>/dev/null)"
		printf 'mac_auto=%s\n' "$(uci -q get likepc.main.mac_auto 2>/dev/null)"
		printf 'mac_pool_count=%s\n' "${MAC_COUNT:-0}"
		printf 'alert_enable=%s\n' "$(uci -q get likepc.main.alert_enable 2>/dev/null)"
		printf 'alert_threshold=%s\n' "$(uci -q get likepc.main.alert_threshold 2>/dev/null)"
		printf 'deps_missing=%s\n' "${DEPS_MISSING:-}"
		printf 'deps_note=%s\n' "${DEPS_NOTE:-}"
		printf 'probe_block=%s\n' "${FW_PROBE_BLOCK:-}"
		printf 'probe_cidr=%s\n' "${FW_PROBE_CIDR:-}"
		printf 'time=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
	} >"$MAC_INFO"

	return 0
}

# ------------------------------------------------------------ 应用 / 轮换
# DHCP client-id 同步。
# Windows 发出去的 client-id 就是「01 + 自己的 MAC」，两者对不上反而是个特征，
# 所以只要当前 client-id 长得像「01 + 12 位十六进制」，就让它跟着新 MAC 走；
# 开着「伪装成 Windows 电脑」但它是空的，也顺手补上；
# 其它写法（固定字符串之类）一律不碰。
mac_sync_clientid() {
	local iface mac cur hex pc

	mac="$1"
	iface=$(wan_iface)
	[ -n "$iface" ] && [ -n "$mac" ] || return 0

	cur=$(uci -q get "network.$iface.clientid" 2>/dev/null)
	pc=$(uci -q get likepc.main.pc_fake 2>/dev/null)
	hex=""

	case "$cur" in
		01*)
			hex=${cur#01}
			case "$hex" in
				*[!0-9a-fA-F]*) hex="" ;;
			esac
			[ ${#hex} -eq 12 ] || hex=""
			;;
	esac

	if [ -n "$hex" ]; then
		# 记下原值，点「恢复原始 MAC」时一起还原（伪装 PC 时由 pc.sh 自己记账）
		if [ "$pc" != "1" ] && [ -z "$(uci -q get likepc.main.mac_orig_clientid 2>/dev/null)" ]; then
			uci -q set likepc.main.mac_orig_clientid="$cur"
			uci -q commit likepc
		fi
		uci -q set "network.$iface.clientid=01$(echo "$mac" | tr -d ':')"
		return 0
	fi

	if [ -z "$cur" ] && [ "$pc" = "1" ]; then
		uci -q set "network.$iface.clientid=01$(echo "$mac" | tr -d ':')"
	fi

	return 0
}

mac_apply() {
	local mac="$1" dev sec iface cur

	[ -n "$mac" ] || { log "没有可用的 MAC"; return 1; }

	dev=$(wan_device)
	if [ -z "$dev" ]; then
		log "无法识别 WAN 设备，跳过 MAC 修改（可在界面里手动指定 WAN 设备名）"
		return 1
	fi

	iface=$(wan_iface)

	# 首次修改时记录原始 MAC，便于一键恢复
	if [ -z "$(uci -q get likepc.main.mac_original 2>/dev/null)" ]; then
		cur=$(current_wan_mac)
		if [ -n "$cur" ]; then
			uci -q set likepc.main.mac_original="$cur"
			uci -q commit likepc
			log "已记录 WAN 原始 MAC: $cur"
		fi
	fi

	sec=$(network_device_section "$dev")
	if [ -n "$sec" ]; then
		uci -q set "network.$sec.macaddr=$mac"
	else
		uci -q add network device
		uci -q set "network.@device[-1].name=$dev"
		uci -q set "network.@device[-1].macaddr=$mac"
	fi

	# 接口段自己写了 macaddr 的话同步一下，避免两边打架
	if [ -n "$(uci -q get "network.$iface.macaddr" 2>/dev/null)" ]; then
		uci -q set "network.$iface.macaddr=$mac"
	fi

	# DHCP client-id 跟着新 MAC 走（Windows 发的是 01+自身MAC，对不上就是特征）
	mac_sync_clientid "$mac"

	# 伪装 PC 的时候，电脑名跟着 MAC 一起换 —— 被拉黑换 MAC 就等于换了一台机器，
	# 名字也该跟着换；没开伪装或没换 MAC 时，这个名字一直不变。
	if [ "$(uci -q get likepc.main.pc_fake 2>/dev/null)" = "1" ]; then
		local newhost
		newhost=$(pc_newhost)
		[ -n "$newhost" ] && log "电脑名一起换成: $newhost"
	fi

	uci -q commit network

	log "正在更换 WAN($dev) MAC -> $mac"
	/etc/init.d/network reload >/dev/null 2>&1
	sleep 2
	ifup "$iface" >/dev/null 2>&1

	if [ "${MAC_SETTLE:-0}" -gt 0 ]; then
		sleep "$MAC_SETTLE"
	fi

	local now
	now=$(current_wan_mac)
	log "WAN MAC 现在为: ${now:-未知}"

	return 0
}

mac_rotate_auto() {
	local last now

	now=$(date +%s)
	last=$(cat "$MAC_TS" 2>/dev/null)
	case "$last" in
		''|*[!0-9]*) last=0 ;;
	esac

	if [ "$last" -gt 0 ] && [ $((now - last)) -lt "$MAC_COOLDOWN" ]; then
		log "MAC 轮换冷却中（还剩 $((MAC_COOLDOWN - (now - last))) 秒），本次不更换"
		return 1
	fi

	[ "$MAC_COUNT" -gt 1 ] || {
		log "MAC 池不足 2 个，无法轮换"
		return 1
	}

	MAC_INDEX=$(( (MAC_INDEX + 1) % MAC_COUNT ))
	uci -q set likepc.main.mac_index="$MAC_INDEX"
	uci -q commit likepc

	mac_apply "$(mac_wanted)" || return 1

	echo "$now" >"$MAC_TS"
	mac_write_state

	return 0
}

mac_restore() {
	local dev sec iface val

	dev=$(wan_device)
	iface=$(wan_iface)

	sec=$(network_device_section "$dev")
	if [ -n "$sec" ]; then
		val=$(uci -q get "network.$sec.macaddr" 2>/dev/null)
		if [ -n "$val" ]; then
			case " $MAC_POOL " in
				*" $val "*) uci -q delete "network.$sec.macaddr" ;;
			esac
		fi
	fi

	val=$(uci -q get "network.$iface.macaddr" 2>/dev/null)
	if [ -n "$val" ]; then
		case " $MAC_POOL " in
			*" $val "*) uci -q delete "network.$iface.macaddr" ;;
		esac
	fi

	# 换 MAC 时同步过的 client-id，一起还原回去
	val=$(uci -q get likepc.main.mac_orig_clientid 2>/dev/null)
	if [ -n "$val" ]; then
		uci -q set "network.$iface.clientid=$val"
		uci -q delete likepc.main.mac_orig_clientid
		uci -q commit likepc
		log "已还原 WAN client-id: $val"
	fi

	uci -q commit network
	/etc/init.d/network reload >/dev/null 2>&1
	sleep 2
	ifup "$iface" >/dev/null 2>&1
	sleep "${MAC_SETTLE:-5}"

	log "已恢复 WAN 原始 MAC: $(current_wan_mac)"
	mac_write_state

	return 0
}

# 启动时：池为空则自动生成；启用开关时应用池中当前 MAC
mac_init() {
	mac_pool_load

	if [ "$MAC_AUTO" = "1" ] && [ "$MAC_COUNT" -eq 0 ]; then
		log "MAC 池为空，自动生成 5 个 MAC"
		mac_gen_pool
		mac_pool_load
	fi

	if [ "$MAC_AUTO" = "1" ] && [ "$MAC_COUNT" -gt 0 ]; then
		local want cur
		want=$(mac_wanted)
		cur=$(current_wan_mac)
		if [ -n "$want" ] && [ "$want" != "$cur" ]; then
			log "应用 MAC 池中第 $((MAC_INDEX + 1))/$MAC_COUNT 个 MAC"
			mac_apply "$want"
		fi
	fi

	mac_write_state
	return 0
}