#!/bin/sh
# 一键防火墙规则
#   firewall3 (iptables) -> 生成脚本 + firewall.include(script)
#   firewall4 (nftables) -> 生成 .nft + firewall.include(nftables)
# 由 likepc.sh source，不单独运行

FW_DIR=/etc/likepc
FW3_SCRIPT=$FW_DIR/firewall.sh
FW4_NFT=$FW_DIR/fw4.nft
# v1.1.0 用的独立 init 脚本，现在只用于清理旧版本残留
FW4_INIT=/etc/init.d/likepc-fw

# 规则模板：随插件一起编译进固件，渲染后才是真正被防火墙加载的规则文件。
# 想调整规则直接改模板重新编译即可；模板缺失时下面的函数会用内置规则兜底。
FW_TPL_DIR=/usr/share/likepc/templates

# 模板渲染：
#   @LAN_CIDR@ / @ROUTER_IP@          换成实际值
#   @PROBE_BLOCK_RULES@               整行换成 $3 指向文件的内容（$3 为空则整行删掉）
tpl_render() {
	local tpl="$1" out="$2" ins="$3"

	[ -f "$tpl" ] || return 1

	if [ -n "$ins" ] && [ -f "$ins" ]; then
		sed -e "s|@LAN_CIDR@|$FW_LAN_CIDR|g" \
			-e "s|@ROUTER_IP@|$FW_ROUTER_IP|g" \
			-e "/@PROBE_BLOCK_RULES@/r $ins" \
			-e "/@PROBE_BLOCK_RULES@/d" \
			"$tpl" >"$out" || return 1
	else
		sed -e "s|@LAN_CIDR@|$FW_LAN_CIDR|g" \
			-e "s|@ROUTER_IP@|$FW_ROUTER_IP|g" \
			-e "/@PROBE_BLOCK_RULES@/d" \
			"$tpl" >"$out" || return 1
	fi

	[ -s "$out" ] || return 1
	return 0
}

# ------------------------------------------------------------ 环境检测
# 判断用的是 fw3 还是 fw4。最可靠的依据是防火墙服务本身调用的是哪个命令，
# 因为有的系统 fw3/fw4 两个二进制都在（/sbin/fw3 可能只是指向 fw4 的软链）。
fw_version() {
	if [ -f /etc/init.d/firewall ]; then
		if grep -qE '(^|[^a-zA-Z0-9])fw4([^a-zA-Z0-9]|$)' /etc/init.d/firewall 2>/dev/null; then
			echo 4
			return 0
		fi
		if grep -qE '(^|[^a-zA-Z0-9])fw3([^a-zA-Z0-9]|$)' /etc/init.d/firewall 2>/dev/null; then
			echo 3
			return 0
		fi
	fi

	# 拿不到 init 脚本时退回到二进制判断
	if command -v fw4 >/dev/null 2>&1 || [ -x /usr/sbin/fw4 ] || [ -x /sbin/fw4 ]; then
		echo 4
	elif command -v iptables >/dev/null 2>&1 || [ -x /sbin/fw3 ]; then
		echo 3
	else
		echo 0
	fi
}

# 防火墙名字（给界面判断用）
fw_name() {
	case "$(fw_version)" in
		4) echo "firewall4" ;;
		3) echo "firewall3" ;;
		*) echo "unknown" ;;
	esac
}

# 人类可读的版本描述：界面「当前环境」显示的就是这个
fw_desc() {
	local v ver

	v=$(fw_version)

	case "$v" in
		4)
			ver=$(nft --version 2>/dev/null | awk '{print $2}')
			echo "firewall4 (nftables${ver:+ $ver})"
			;;
		3)
			ver=$(iptables --version 2>/dev/null | awk '{print $2}')
			echo "firewall3 (iptables${ver:+ $ver})"
			;;
		*)
			echo "未检测到 iptables / nft"
			;;
	esac
}

# 本插件的规则当前是否已经装上了
fw_rules_present() {
	case "$(fw_version)" in
		3) [ -n "$(fw_include_section 2>/dev/null)" ] && return 0 ;;
		4) [ -n "$(fw4_include_section 2>/dev/null)" ] && return 0 ;;
	esac

	return 1
}

# ------------------------------------------------------- 门户探测地址屏蔽
# firewall3 用的是 iptables -m string（按响应正文内容丢包），
# nftables 完全没有字符串匹配能力，所以 firewall4 下改成按目标地址拦请求：
# 浏览器拿不到那个探测脚本，校园网就看不到局域网设备发起的这个连接，效果一样，
# 而且不会误伤正文里恰好出现那串字符的正常网页。
FW_PROBE_BLOCK=1
FW_PROBE_CIDR="1.1.1.0/24"

fw_probe_info() {
	local v c

	v=$(uci -q get likepc.main.fw_probe_block 2>/dev/null)
	if [ "$v" = "0" ]; then
		FW_PROBE_BLOCK=0
	else
		FW_PROBE_BLOCK=1
	fi

	c=$(uci -q get likepc.main.fw_probe_cidr 2>/dev/null)
	[ -n "$c" ] && FW_PROBE_CIDR=$(echo "$c" | tr ',' ' ')
	[ -z "$FW_PROBE_CIDR" ] && FW_PROBE_CIDR="1.1.1.0/24"

	return 0
}

# ------------------------------------------------------------ 依赖体检
# 刻意不写进 Makefile 的 LUCI_DEPENDS：这些扩展在不同固件里包名 / 可用性都不一样，
# 声明成编译依赖会让整个包编译失败。这里只在运行时检测，缺什么就在界面上点名，
# 由使用者自己在固件里编入。
DEPS_FILE=/tmp/likepc.deps
DEPS_MISSING=""
DEPS_NOTE=""

deps_scan() {
	local ver

	DEPS_MISSING=""
	DEPS_NOTE=""
	ver=$(fw_version)


	if [ "$ver" = "3" ]; then
		if ! fw_string_ok; then
			DEPS_MISSING="$DEPS_MISSING iptables-mod-filter kmod-ipt-filter"
			DEPS_NOTE="$DEPS_NOTE 缺 string 匹配 xt_string，「屏蔽门户探测包」那条不会生效；"
		fi

		if ! fw_ttl_ok; then
			DEPS_MISSING="$DEPS_MISSING iptables-mod-ipopt kmod-ipt-ipopt"
			DEPS_NOTE="$DEPS_NOTE 缺 TTL target xt_TTL，「统一 TTL 128」那条不会生效；"
		fi
	elif [ "$ver" = "4" ]; then
		if command -v nft >/dev/null 2>&1; then
			DEPS_NOTE="$DEPS_NOTE firewall4 用原生 nft 规则，不需要额外内核扩展；"
		else
			DEPS_MISSING="$DEPS_MISSING nftables"
			DEPS_NOTE="$DEPS_NOTE 找不到 nft 命令，firewall4 规则无法加载；"
		fi
	else
		# 不是「缺某个包」，而是整个防火墙都没认出来，别误导成缺 iptables
		DEPS_NOTE="$DEPS_NOTE 没检测到 iptables / nft，防火墙规则加不了；"
	fi

	DEPS_MISSING=$(echo $DEPS_MISSING)
	DEPS_NOTE=$(echo $DEPS_NOTE)
	return 0
}

deps_write() {
	deps_scan

	{
		printf 'missing=%s\n' "$DEPS_MISSING"
		printf 'command=%s\n' "$([ -n "$DEPS_MISSING" ] && echo "opkg update && opkg install $DEPS_MISSING")"
		printf 'note=%s\n' "$DEPS_NOTE"
		printf 'time=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
	} >"$DEPS_FILE"

	return 0
}

fw_string_ok() {
	command -v iptables >/dev/null 2>&1 && iptables -m string -h >/dev/null 2>&1
}

fw_ttl_ok() {
	command -v iptables >/dev/null 2>&1 && iptables -j TTL -h >/dev/null 2>&1
}

mask2cidr() {
	case "$1" in
		255.0.0.0) echo 8 ;;
		255.255.0.0) echo 16 ;;
		255.255.128.0) echo 17 ;;
		255.255.192.0) echo 18 ;;
		255.255.224.0) echo 19 ;;
		255.255.240.0) echo 20 ;;
		255.255.248.0) echo 21 ;;
		255.255.252.0) echo 22 ;;
		255.255.254.0) echo 23 ;;
		255.255.255.128) echo 25 ;;
		255.255.255.192) echo 26 ;;
		255.255.255.224) echo 27 ;;
		255.255.255.240) echo 28 ;;
		255.255.255.248) echo 29 ;;
		255.255.255.252) echo 30 ;;
		*) echo 24 ;;
	esac
}

net_addr() {
	local ip="$1" cidr="$2"

	case "$cidr" in
		8) echo "$ip" | cut -d. -f1 | sed 's/$/.0.0.0/' ;;
		16) echo "$ip" | cut -d. -f1-2 | sed 's/$/.0.0/' ;;
		*) echo "$ip" | cut -d. -f1-3 | sed 's/$/.0/' ;;
	esac
}

# 取 LAN 网段与路由器后台地址（界面可手动覆盖）
fw_lan_info() {
	local ip mask cidr

	FW_ROUTER_IP=$(uci -q get likepc.main.fw_router_ip 2>/dev/null)
	FW_LAN_CIDR=$(uci -q get likepc.main.fw_lan_cidr 2>/dev/null)

	ip=$(uci -q get network.lan.ipaddr 2>/dev/null)
	mask=$(uci -q get network.lan.netmask 2>/dev/null)

	if [ -z "$FW_ROUTER_IP" ]; then
		FW_ROUTER_IP="$ip"
	fi
	if [ -z "$FW_ROUTER_IP" ]; then
		FW_ROUTER_IP=$(ip -4 addr show dev br-lan 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)
	fi

	if [ -z "$FW_LAN_CIDR" ]; then
		cidr=$(mask2cidr "$mask")
		[ -z "$ip" ] && ip="$FW_ROUTER_IP"
		if [ -n "$ip" ]; then
			FW_LAN_CIDR="$(net_addr "$ip" "$cidr")/$cidr"
		fi
	fi

	[ -z "$FW_LAN_CIDR" ] && FW_LAN_CIDR="192.168.1.0/24"
	[ -z "$FW_ROUTER_IP" ] && FW_ROUTER_IP="192.168.1.1"

	return 0
}

# ------------------------------------------------------------ firewall3
fw_gen_script() {
	fw_lan_info
	mkdir -p "$FW_DIR"

	# 优先用随插件编译进固件的模板渲染
	if [ -f "$FW_TPL_DIR/fw3.sh" ] && tpl_render "$FW_TPL_DIR/fw3.sh" "$FW3_SCRIPT"; then
		chmod 0755 "$FW3_SCRIPT" 2>/dev/null
		return 0
	fi

	# 模板缺失 / 渲染失败时的内置兜底
	cat >"$FW3_SCRIPT" <<EOF
#!/bin/sh
# 由 luci-app-likepc 自动生成，请勿手工修改（改界面里的选项即可）
# 适用 firewall3 (iptables)：
#   1) 客户端 DNS / NTP 强制走本机
#   2) 统一 TTL 为 128，避免被识别成路由器共享
#   3) 屏蔽校园网下发页面里的 src="http://1.1.1. 探测包

LAN_CIDR="${FW_LAN_CIDR}"
ROUTER_IP="${FW_ROUTER_IP}"

_del_all() {
	while "\$@" 2>/dev/null; do :; done
}

del_rules() {
	_del_all iptables -t nat -D PREROUTING -p udp --dport 123 -j REDIRECT --to-ports 123
	_del_all iptables -t nat -D PREROUTING -p udp --dport 123 -j ntp_force_local
	_del_all iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 53
	_del_all iptables -t nat -D PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 53
	_del_all iptables -D FORWARD -p tcp --sport 80 --tcp-flags ACK ACK -m string --algo bm --string 'src="http://1.1.1.' -j DROP
	_del_all iptables -t mangle -D POSTROUTING -j TTL --ttl-set 128
	iptables -t nat -F ntp_force_local 2>/dev/null
	iptables -t nat -X ntp_force_local 2>/dev/null
	return 0
}

add_rules() {
	del_rules

	# NTP 重定向到本机
	iptables -t nat -A PREROUTING -p udp --dport 123 -j REDIRECT --to-ports 123

	# 屏蔽校园网下发页面里的 src="http://1.1.1. 探测（多设备检测）
	iptables -A FORWARD -p tcp --sport 80 --tcp-flags ACK ACK -m string --algo bm --string 'src="http://1.1.1.' -j DROP

	# 统一 TTL
	iptables -t mangle -A POSTROUTING -j TTL --ttl-set 128

	# 强制客户端 NTP 走本机
	iptables -t nat -N ntp_force_local
	iptables -t nat -I PREROUTING -p udp --dport 123 -j ntp_force_local
	iptables -t nat -A ntp_force_local -d 0.0.0.0/8 -j RETURN
	iptables -t nat -A ntp_force_local -d 127.0.0.0/8 -j RETURN
	iptables -t nat -A ntp_force_local -d \$LAN_CIDR -j RETURN
	iptables -t nat -A ntp_force_local -s \$LAN_CIDR -j DNAT --to-destination \$ROUTER_IP

	# DNS 强制走路由器 dnsmasq
	iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 53
	iptables -t nat -A PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 53

	return 0
}

case "\$1" in
	del|remove|stop) del_rules ;;
	*) add_rules ;;
esac
EOF

	chmod 0755 "$FW3_SCRIPT" 2>/dev/null
	return 0
}

fw_include_section() {
	local sec

	for sec in $(uci -q show firewall 2>/dev/null | grep '=include$' | cut -d. -f2 | cut -d= -f1); do
		if [ "$(uci -q get "firewall.$sec.path" 2>/dev/null)" = "$FW3_SCRIPT" ]; then
			echo "$sec"
			return 0
		fi
	done

	return 1
}

fw_add_include() {
	fw_include_section >/dev/null && return 0

	uci -q add firewall include
	uci -q set firewall.@include[-1].type='script'
	uci -q set firewall.@include[-1].path="$FW3_SCRIPT"
	uci -q set firewall.@include[-1].enabled='1'
	uci -q commit firewall

	return 0
}

fw_del_include() {
	local sec

	while sec=$(fw_include_section); do
		uci -q delete "firewall.$sec"
		uci -q commit firewall
	done

	return 0
}

fw_ntp_server_on() {
	uci -q set system.ntp.enable_server='1'
	uci -q commit system
	/etc/init.d/sysntpd restart >/dev/null 2>&1 || /etc/init.d/sysntpd start >/dev/null 2>&1
	log "已开启路由器 NTP 服务（客户端时间同步改由本机提供）"
	return 0
}

# ------------------------------------------------------------ firewall3 (iptables)
fw3_add() {
	if [ "$(fw_version)" != "3" ]; then
		log "当前系统不是 firewall3（iptables），跳过 iptables 规则"
		return 1
	fi

	fw_gen_script
	fw_add_include
	/etc/init.d/firewall restart >/dev/null 2>&1
	sleep 1

	log "已添加 firewall3 规则：DNS/NTP 强制走本机 + TTL 统一 128 + 屏蔽门户探测包"
	log "LAN 网段 ${FW_LAN_CIDR}，路由器地址 ${FW_ROUTER_IP}，规则文件 ${FW3_SCRIPT}"

	[ "$(uci -q get likepc.main.fw_ntp_server 2>/dev/null)" = "1" ] && fw_ntp_server_on

	deps_write
	[ -n "$DEPS_MISSING" ] && log "缺少依赖：${DEPS_MISSING}（界面会弹提示，请在固件里自行编入）"

	mac_write_info
	return 0
}

# 统一入口：按检测到的防火墙版本自动选 iptables 还是 nftables
fw_add() {
	case "$(fw_version)" in
		3) fw3_add ;;
		4) fw4_add ;;
		*)
			log "没有检测到 iptables / nft，无法添加防火墙规则"
			mac_write_info
			return 1
			;;
	esac
}

fw_del() {
	# firewall3 的 iptables 规则先删掉
	if [ -f "$FW3_SCRIPT" ]; then
		sh "$FW3_SCRIPT" del >/dev/null 2>&1
	fi

	fw_del_include
	fw4_del_include
	fw4_cleanup_legacy
	/etc/init.d/firewall reload >/dev/null 2>&1 || /etc/init.d/firewall restart >/dev/null 2>&1

	log "已移除校园网自定义防火墙规则（DNS/NTP/TTL/探测包屏蔽）"
	mac_write_info
	return 0
}

fw_show() {
	local out

	log "---- 当前校园网相关防火墙规则（$(fw_desc)） ----"

	if [ "$(fw_version)" = "4" ]; then
		out=$(nft list chain inet fw4 likepc_redirect 2>/dev/null)
		if [ -n "$out" ]; then
			echo "$out" | while read -r line; do log "  $line"; done
		else
			log "  未加载（可在上面点「一键添加防火墙规则」）"
		fi

		out=$(nft list chain inet fw4 likepc_ttl 2>/dev/null)
		[ -n "$out" ] && echo "$out" | while read -r line; do log "  $line"; done

		fw_probe_info
		if [ "$FW_PROBE_BLOCK" = "1" ]; then
			out=$(nft list chain inet fw4 likepc_probe 2>/dev/null)
			if [ -n "$out" ]; then
				echo "$out" | while read -r line; do log "  $line"; done
			else
				log "  （门户探测地址屏蔽规则还没加载，可点上面的「一键添加防火墙规则」）"
			fi
			log "  说明：nftables 没有字符串匹配，这条改成拦「局域网设备访问 ${FW_PROBE_CIDR} 的 80 端口」，效果等价"
		else
			log "  说明：界面里关掉了「屏蔽门户探测地址」，本系统没有生成对应规则"
		fi

		return 0
	fi

	out=$(iptables -t nat -S PREROUTING 2>/dev/null | grep -E 'dport (123|53)')
	[ -n "$out" ] && echo "$out" | while read -r line; do log "  $line"; done

	out=$(iptables -t nat -S ntp_force_local 2>/dev/null)
	[ -n "$out" ] && echo "$out" | while read -r line; do log "  $line"; done

	out=$(iptables -S FORWARD 2>/dev/null | grep 'string')
	[ -n "$out" ] && echo "$out" | while read -r line; do log "  $line"; done

	out=$(iptables -t mangle -S POSTROUTING 2>/dev/null | grep -i 'ttl')
	[ -n "$out" ] && echo "$out" | while read -r line; do log "  $line"; done

	return 0
}

# ------------------------------------------------------------ firewall4 (nft)
# fw4 没有 /etc/firewall.user，LuCI 的「自定义规则」页面在 fw4 下也不显示
# （那个菜单项的 depends 是 /usr/share/fw3/helpers.conf）。
# fw4 官方给的自定义入口是 uci 的 include 段：
#
#   config include
#       option type 'nftables'
#       option path '/etc/likepc/fw4.nft'
#       option position 'table-prepend'
#
# fw4 渲染规则集时会把这个文件 include 进 table inet fw4 里面
# （见 /usr/share/firewall4/templates/ruleset.uc 里的 include "/etc/nftables.d/*.nft"），
# 所以文件里只能写 chain，不能再写 table，否则 nft -f 会报错。
# 用模板渲染 fw4 规则；成功返回 0。模板缺失 / 渲染失败返回 1，由调用方用内置规则兜底
_fw4_render_tpl() {
	local ins=/tmp/.likepc-probe.nft

	[ -f "$FW_TPL_DIR/fw4.nft" ] || return 1

	# 空行由模板里的那行留白提供，这里原样写入即可
	printf '%s' "$1" >"$ins" || { rm -f "$ins"; return 1; }

	if tpl_render "$FW_TPL_DIR/fw4.nft" "$FW4_NFT" "$ins"; then
		rm -f "$ins"
		return 0
	fi

	rm -f "$ins"
	log "模板 $FW_TPL_DIR/fw4.nft 渲染失败，改用内置规则"
	return 1
}

fw4_gen() {
	local probe_rules probe_list

	fw_lan_info
	fw_probe_info
	mkdir -p "$FW_DIR"

	if [ "$FW_PROBE_BLOCK" = "1" ]; then
		# 逐个拼，避免用户写「a, b」这种带空格的写法拼出连续逗号
		probe_list=""
		for _cidr in $FW_PROBE_CIDR; do
			probe_list="${probe_list:+$probe_list, }$_cidr"
		done
		probe_rules="# 局域网设备不许访问门户探测地址
# firewall3 用的是 iptables -m string（按响应正文丢包），nftables 没有字符串匹配，
# 改成按目标地址拦请求：浏览器拿不到那个探测脚本，校园网也就看不到
# 局域网设备发起的这个连接。效果一样，而且不会误伤正文里恰好含那串字符的正常网页。
chain likepc_probe {
	type filter hook forward priority filter; policy accept;
	ip saddr ${FW_LAN_CIDR} ip daddr { ${probe_list} } tcp dport 80 ct state new drop
}
"
	else
		probe_rules="# （界面里关掉了「屏蔽门户探测地址」，这里不生成对应规则）
"
	fi

	# 优先用随插件编译进固件的模板渲染（想改规则就改模板）
	if _fw4_render_tpl "$probe_rules"; then
		return 0
	fi

	cat >"$FW4_NFT" <<EOF
# 由 luci-app-likepc 自动生成，请勿手工修改（改界面里的选项即可）
# 本文件由 /etc/config/firewall 的 include 段加载，
# 渲染时位于 table inet fw4 内部 —— 所以这里只定义 chain，不写 table。

# DNS / NTP 强制走路由器本机
chain likepc_redirect {
	type nat hook prerouting priority dstnat; policy accept;

	# 内网设备的 NTP 请求改送到路由器（等价于 firewall3 版的 ntp_force_local 链）
	udp dport 123 ip saddr ${FW_LAN_CIDR} ip daddr != { 0.0.0.0/8, 127.0.0.0/8, ${FW_LAN_CIDR} } dnat to ${FW_ROUTER_IP}

	# 其余来源的 NTP 重定向到本机 123
	udp dport 123 redirect to :123

	# DNS 强制走本机 dnsmasq
	udp dport 53 redirect to :53
	tcp dport 53 redirect to :53
}

# 统一 TTL，避免被识别成路由器共享
chain likepc_ttl {
	type filter hook postrouting priority mangle; policy accept;
	ip ttl set 128
}

EOF

	# 探测规则单独追加，保证和模板渲染出来的文件逐字节一致
	printf '%s' "$probe_rules" >>"$FW4_NFT"

	return 0
}

fw4_include_section() {
	local sec

	for sec in $(uci -q show firewall 2>/dev/null | grep '=include$' | cut -d. -f2 | cut -d= -f1); do
		if [ "$(uci -q get "firewall.$sec.path" 2>/dev/null)" = "$FW4_NFT" ]; then
			echo "$sec"
			return 0
		fi
	done

	return 1
}

fw4_add_include() {
	local sec

	if sec=$(fw4_include_section); then
		uci -q set "firewall.$sec.type='nftables'"
		uci -q set "firewall.$sec.path='$FW4_NFT'"
		uci -q set "firewall.$sec.position='table-prepend'"
		uci -q set "firewall.$sec.enabled='1'"
	else
		uci -q add firewall include
		uci -q set firewall.@include[-1].type='nftables'
		uci -q set firewall.@include[-1].path="$FW4_NFT"
		uci -q set firewall.@include[-1].position='table-prepend'
		uci -q set firewall.@include[-1].enabled='1'
	fi

	uci -q commit firewall
	return 0
}

fw4_del_include() {
	local sec

	while sec=$(fw4_include_section); do
		uci -q delete "firewall.$sec"
		uci -q commit firewall
	done

	return 0
}

# v1.1.0 用的是「独立 nft 表 + 独立 init 脚本」，这里把残留清掉
fw4_cleanup_legacy() {
	if [ -f "$FW4_INIT" ]; then
		"$FW4_INIT" stop >/dev/null 2>&1
		"$FW4_INIT" disable >/dev/null 2>&1
		rm -f "$FW4_INIT"
	fi

	nft delete table ip likepc 2>/dev/null
	return 0
}

# 让 fw4 自己渲染一遍规则集做语法自检，避免把整机防火墙搞挂
fw4_check() {
	if command -v fw4 >/dev/null 2>&1; then
		fw4 -q check >/dev/null 2>&1
		return $?
	fi

	nft -c -f "$FW4_NFT" >/dev/null 2>&1
}

fw4_add() {
	if [ "$(fw_version)" != "4" ]; then
		log "当前系统不是 firewall4（nftables），跳过 nft 规则"
		return 1
	fi

	if ! command -v nft >/dev/null 2>&1; then
		log "找不到 nft 命令，无法添加 firewall4 规则"
		return 1
	fi

	fw4_cleanup_legacy
	fw4_gen
	fw4_add_include

	if ! fw4_check; then
		log "nft 规则语法自检没通过，已撤销本次添加（防火墙保持原样）"
		fw4_del_include
		rm -f "$FW4_NFT"
		mac_write_info
		return 1
	fi

	/etc/init.d/firewall reload >/dev/null 2>&1 || /etc/init.d/firewall restart >/dev/null 2>&1
	sleep 1

	log "已写入 firewall4 规则（firewall.include + type nftables）：${FW4_NFT}"
	log "LAN 网段 ${FW_LAN_CIDR}，路由器地址 ${FW_ROUTER_IP}"

	if [ "$FW_PROBE_BLOCK" = "1" ]; then
		log "已屏蔽局域网设备访问门户探测地址 ${FW_PROBE_CIDR}（代替 firewall3 的 -m string 规则）"
	else
		log "「屏蔽门户探测地址」已在界面关闭，本次没有生成对应规则"
	fi

	[ "$(uci -q get likepc.main.fw_ntp_server 2>/dev/null)" = "1" ] && fw_ntp_server_on

	deps_write
	[ -n "$DEPS_MISSING" ] && log "缺少依赖：${DEPS_MISSING}（界面会弹提示，请在固件里自行编入）"

	mac_write_info
	return 0
}

fw4_del() {
	fw4_del_include
	fw4_cleanup_legacy
	/etc/init.d/firewall reload >/dev/null 2>&1 || /etc/init.d/firewall restart >/dev/null 2>&1

	log "已移除 firewall4(nft) 规则"
	mac_write_info
	return 0
}

# ------------------------------------------------------------ 依赖检测 / 安装
deps_check() {
	local ver

	ver=$(fw_version)
	log "---- 环境检测 ----"
	log "防火墙版本：$(fw_desc)"
	log "iptables：$(command -v iptables >/dev/null 2>&1 && echo 有 || echo 无)"
	log "nft：$(command -v nft >/dev/null 2>&1 && echo 有 || echo 无)"
	log "校园网规则：$(fw_rules_present && echo 已加载 || echo 未加载)"
	log "WAN 设备：$(wan_device)"

	if [ "$ver" = "3" ]; then
		log "string 匹配（xt_string）：$(fw_string_ok && echo 有 || echo 缺)"
		log "TTL target（xt_TTL）：$(fw_ttl_ok && echo 有 || echo 缺)"
	else
		log "门户探测屏蔽：按目标地址拦截（nftables 没有字符串匹配，不用 xt_string）"
	fi

	deps_scan

	if [ -n "$DEPS_MISSING" ]; then
		log "缺少依赖：${DEPS_MISSING}"
		log "说明：${DEPS_NOTE}"
		log "本插件刻意不把这些写进编译依赖（写了会让整包编译失败），请在固件里自行编入"
	else
		log "依赖齐全：${DEPS_NOTE}"
	fi

	deps_write
	return 0
}

deps_install() {
	local pkgs=""

	if [ "$(fw_version)" = "3" ]; then
		fw_string_ok || pkgs="$pkgs iptables-mod-filter kmod-ipt-filter"
		fw_ttl_ok || pkgs="$pkgs iptables-mod-ipopt kmod-ipt-ipopt"
	fi

	if [ -z "$pkgs" ]; then
		log "没有检测到缺失的模块"
		return 0
	fi

	log "准备安装：$pkgs"
	opkg update >/dev/null 2>&1

	local p
	for p in $pkgs; do
		if opkg install "$p" >/dev/null 2>&1; then
			log "已安装 $p"
		else
			log "安装 $p 失败（包名可能因固件不同而不同，可在 menuconfig 里搜索）"
		fi
	done

	log "安装结束，如有规则仍不生效请重新执行「一键添加防火墙规则」"
	return 0
}