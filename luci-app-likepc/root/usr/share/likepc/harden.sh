#!/bin/sh
# 出网特征加固 + 体检（likepc 的一部分）
# 由 likepc.sh source，不单独运行
#
# 这一层只做一件事：把「从校园网看过去，这台机器不像一台电脑」的地方逐条消掉。
# 每一项都是独立开关，可以单独应用、单独撤销：
#   hd_ipv6     关掉 IPv6（含前缀请求）
#   hd_offload  关掉流量卸载与限速，让 TTL 这类规则真正生效
#   hd_sig      统一出网特征：TTL 128 + MSS
#   hd_dhcp     伪装 DHCP 指纹
#   hd_quiet    掐掉所有会定时往外发东西的服务
#   hd_routing  关掉 OSPF / RIP / BGP / PIM / IGMP 代理与网桥 IGMP 嗅探
#
# 体检报告写在 /tmp/likepc.harden，每行格式：等级|名称|说明
#   等级 ok / warn / bad / info / sw（sw 行是各开关的状态）
#
# 提醒：一次只开一项，改完观察几天再动下一项。你的断线本来就不规律，
# 一次全开的话，永远不知道是哪条起的作用。

# 这几个根目录允许用环境变量覆盖，方便离线测试；设备上不设就是默认路径
HD_DIR=${HD_DIR:-/etc/likepc}
HD_CONF_DIR=${HD_CONF_DIR:-/etc/config}
HD_HOTPLUG=${HD_HOTPLUG:-/etc/hotplug.d/iface/99-likepc-ipv6}
HD_INITD=${HD_INITD:-/etc/init.d}
HD_BAK="$HD_DIR/bak"
HD_NFT="$HD_DIR/harden.nft"
HD_REPORT=/tmp/likepc.harden
HD_MSS=1460

# 会定时主动往外发东西的服务：装了并且开着就停掉，撤销时按名单恢复
HD_QUIET_SVC="umdns mwan3 watchcat banip adblock attendedsysupgrade ddns collectd"

# 隧道 / 代理 / 加密 DNS：只报告不动手，这些要你自己判断
HD_WATCH_SVC="openclash clash passwall passwall2 ssr-plus shadowsocks-libev
	v2raya xray sing-box mihomo nikki dae byedpi homeproxy
	zerotier tailscale nebula frpc sshtunnel
	smartdns mosdns https-dns-proxy stubby dnscrypt-proxy
	upnpd miniupnpd"

# 路由 / 组播协议：家用 / 电脑直连的环境里一个都不该跑，跑了就是最明确的路由器特征。
# 前者是进程名（pidof 用），后者是 init 脚本名（要停还得能按名单恢复）。
HD_ROUTE_PROC="bird bird4 bird6 babeld ospfd ospf6d ripd ripngd bgpd pimd pim6d
	smcroute igmpproxy mcproxy zebra olsrd olsrd6"
HD_ROUTE_SVC="olsrd olsrd6 babeld bird bird4 bird6 quagga frr ospfd ospf6d
	ripd ripngd bgpd pimd pim6d smcroute igmpproxy mcproxy"

# 网桥 IGMP 嗅探的原值记在这里，撤销时照着还原
HD_IGMP_FILE="$HD_DIR/hd-routing-igmp"

# ------------------------------------------------------------------ 通用工具
hd_svc_exists() {
	[ -x "$HD_INITD/$1" ]
}

hd_svc_enabled() {
	hd_svc_exists "$1" || return 1
	"$HD_INITD/$1" enabled >/dev/null 2>&1
}

hd_stop_svc() {
	hd_svc_exists "$1" || return 0
	"$HD_INITD/$1" stop >/dev/null 2>&1
	"$HD_INITD/$1" disable >/dev/null 2>&1
	return 0
}

hd_start_svc() {
	hd_svc_exists "$1" || return 0
	"$HD_INITD/$1" enable >/dev/null 2>&1
	"$HD_INITD/$1" start >/dev/null 2>&1
	return 0
}

hd_svc_list_file() {
	echo "$HD_DIR/hd-svc-$1.list"
}

# 停掉一个服务，并把名字记进分组名单（撤销时照名单恢复）
hd_svc_record_stop() {
	local grp="$1" svc="$2" f

	hd_svc_enabled "$svc" || return 0

	f=$(hd_svc_list_file "$grp")
	mkdir -p "$HD_DIR"
	grep -qx "$svc" "$f" 2>/dev/null || echo "$svc" >>"$f"

	hd_stop_svc "$svc"
	log "已停用会主动联网的服务：$svc"
	return 0
}

hd_svc_restore() {
	local grp="$1" f svc

	f=$(hd_svc_list_file "$grp")
	[ -f "$f" ] || return 0

	while read -r svc; do
		[ -n "$svc" ] || continue
		hd_start_svc "$svc"
		log "已恢复服务：$svc"
	done <"$f"

	rm -f "$f"
	return 0
}

# 改 uci 之前把整份配置留个底；撤销时整体还原
# （不是逐项还原，因为 IPv6 那一项散在 network 和 dhcp 两个文件里，
#   逐项还原容易漏。界面上会说明这一点。）
hd_backup_file() {
	mkdir -p "$HD_BAK"
	[ -f "$HD_CONF_DIR/$1" ] || return 0
	cp "$HD_CONF_DIR/$1" "$HD_BAK/$1" 2>/dev/null
	return 0
}

hd_restore_file() {
	[ -f "$HD_BAK/$1" ] || return 1
	mkdir -p "$HD_CONF_DIR"
	cp "$HD_BAK/$1" "$HD_CONF_DIR/$1" 2>/dev/null
	return 0
}

# 各开关的状态标记
hd_flag() {
	local name="$1" val="$2"

	if [ -n "$val" ]; then
		mkdir -p "$HD_DIR"
		echo "$val" >"$HD_DIR/hd-$name" 2>/dev/null
		return 0
	fi

	local v
	v=$(cat "$HD_DIR/hd-$name" 2>/dev/null)
	[ -n "$v" ] || v=0
	echo "$v"
	return 0
}

hd_on() {
	hd_flag "$1" 1
}

hd_off() {
	hd_flag "$1" 0
}

# ------------------------------------------------------------------ 探测函数
hd_ifaces() {
	uci -q show network 2>/dev/null | grep '=interface$' | cut -d. -f2 | cut -d= -f1
}

# 哪个接口正在向校园网请求 IPv6（地址或前缀）
hd_ipv6_requesting() {
	local s p v

	for s in $(hd_ifaces); do
		p=$(uci -q get "network.$s.proto" 2>/dev/null)
		case "$p" in
			dhcpv6)
				v=$(uci -q get "network.$s.reqprefix" 2>/dev/null)
				case "$v" in
					none|disabled) ;;
					*) echo "$s"; return 0 ;;
				esac
				;;
			dhcp)
				v=$(uci -q get "network.$s.ipv6" 2>/dev/null)
				case "$v" in
					1|auto|try) echo "$s"; return 0 ;;
				esac
				;;
		esac
	done

	return 1
}

# 本机有没有全球 IPv6 地址（2xxx / 3xxx 开头）
hd_ipv6_lan_global() {
	ip -6 addr show 2>/dev/null | grep -qE 'inet6 (2[0-9a-fA-F]{3}|3[0-9a-fA-F]{3}):'
}

# WAN 口是不是被桥进了某个网桥
hd_wan_in_bridge() {
	local dev d

	dev=$(wan_device)
	[ -n "$dev" ] || return 1

	for d in /sys/class/net/*; do
		[ -e "$d/brif/$dev" ] || continue
		echo "${d##*/}"
		return 0
	done

	return 1
}

hd_ttl_present() {
	if [ "$(fw_version)" = "4" ]; then
		nft list ruleset 2>/dev/null | grep -q 'ttl set 128'
	else
		iptables -t mangle -S POSTROUTING 2>/dev/null | grep -q -- '--ttl-set 128'
	fi
}

hd_mss_present() {
	if [ "$(fw_version)" = "4" ]; then
		hd_nft_include_section >/dev/null
	else
		iptables -t mangle -S POSTROUTING 2>/dev/null | grep -q -- "--set-mss $HD_MSS"
	fi
}

hd_nft_include_section() {
	local sec

	for sec in $(uci -q show firewall 2>/dev/null | grep '=include$' | cut -d. -f2 | cut -d= -f1); do
		if [ "$(uci -q get "firewall.$sec.path" 2>/dev/null)" = "$HD_NFT" ]; then
			echo "$sec"
			return 0
		fi
	done

	return 1
}

hd_nft_include_add() {
	hd_nft_include_section >/dev/null && return 0

	uci -q add firewall include
	uci -q set firewall.@include[-1].type='nftables'
	uci -q set firewall.@include[-1].path="$HD_NFT"
	uci -q set firewall.@include[-1].enabled='1'
	uci -q commit firewall
	return 0
}

hd_nft_include_del() {
	local sec

	while sec=$(hd_nft_include_section); do
		uci -q delete "firewall.$sec"
		uci -q commit firewall
	done

	return 0
}

hd_route_procs() {
	local p found

	found=""
	for p in $HD_ROUTE_PROC; do
		pidof "$p" >/dev/null 2>&1 && found="$found $p"
	done

	echo $found
}

# 正在跑、或者开着自启的路由 / 组播守护进程（并集，去重）
hd_route_found() {
	local p found

	found=$(hd_route_procs)
	for p in $HD_ROUTE_SVC; do
		hd_svc_enabled "$p" || continue
		case " $found " in
			*" $p "*) continue ;;
		esac
		found="$found $p"
	done

	echo $found
}

# 哪些网桥开着 IGMP 嗅探（没写这个选项时以内核实际状态为准）
hd_igmp_snoop_devs() {
	local s n t v

	for s in $(uci -q show network 2>/dev/null | grep '=device$' | cut -d. -f2 | cut -d= -f1); do
		n=$(uci -q get "network.$s.name" 2>/dev/null)
		t=$(uci -q get "network.$s.type" 2>/dev/null)

		if [ -z "$t" ] && [ -n "$n" ] && [ -f "/sys/class/net/$n/bridge/multicast_snooping" ]; then
			t=bridge
		fi
		[ "$t" = "bridge" ] || continue

		v=$(uci -q get "network.$s.igmp_snooping" 2>/dev/null)
		case "$v" in
			1|true|yes) echo "$s"; continue ;;
			0|false|no) continue ;;
		esac

		# 没写这个选项：OpenWrt 的网桥默认是开着的，看内核怎么说
		if [ -n "$n" ] && [ "$(cat "/sys/class/net/$n/bridge/multicast_snooping" 2>/dev/null)" = "1" ]; then
			echo "$s"
		fi
	done

	return 0
}

# ------------------------------------------------------------------ 体检报告
hd_row() {
	printf '%s|%s|%s\n' "$1" "$2" "$3"
}

hd_report() {
	local req dev v br found grp s

	{
		hd_row info "防火墙版本" "$(fw_desc)"

		# ---------------------------------------------------- IPv6
		req=$(hd_ipv6_requesting)
		if [ -n "$req" ]; then
			hd_row bad "IPv6 请求" "接口 $req 正在向校园网要 IPv6 地址/前缀 —— 要前缀这个动作本身就等于声明「我是路由器」"
		else
			hd_row ok "IPv6 请求" "没有任何接口在请求 IPv6"
		fi

		if hd_ipv6_lan_global; then
			hd_row bad "内网 IPv6" "本机有全球 IPv6 地址；一旦拿到前缀，内网每台设备都会有一个，上游数地址就能数出你有几台设备"
		else
			hd_row ok "内网 IPv6" "没有全球 IPv6 地址"
		fi

		dev=$(wan_device)
		if [ -n "$dev" ]; then
			v=$(cat "/proc/sys/net/ipv6/conf/$dev/disable_ipv6" 2>/dev/null)
			if [ "$v" = "1" ]; then
				hd_row ok "WAN 口 IPv6" "$dev 的 IPv6 已在内核层关闭"
			elif [ -n "$v" ]; then
				hd_row warn "WAN 口 IPv6" "$dev 的 IPv6 还开着，内核会往外发路由请求"
			fi
		fi

		if hd_svc_enabled odhcpd; then
			hd_row warn "odhcpd" "IPv6 地址/前缀服务还在跑，内网仍可能在发 RA"
		else
			hd_row ok "odhcpd" "已停用"
		fi

		# ---------------------------------------------------- 流量卸载
		v=$(uci -q get firewall.@defaults[0].flow_offloading 2>/dev/null)
		if [ "$v" = "1" ]; then
			hd_row bad "软件流量卸载" "已开启：已建立的连接会绕过 mangle 链，TTL 规则时对时不对，最容易出「有时被抓有时没事」"
		else
			hd_row ok "软件流量卸载" "已关闭"
		fi

		v=$(uci -q get firewall.@defaults[0].flow_offloading_hw 2>/dev/null)
		if [ "$v" = "1" ]; then
			hd_row bad "硬件流量卸载" "已开启：数据包完全绕过 netfilter，防火墙规则对它无效"
		else
			hd_row ok "硬件流量卸载" "已关闭"
		fi

		if nft list ruleset 2>/dev/null | grep -q flowtable; then
			hd_row warn "卸载流表" "nft 规则集里还留着 flowtable"
		fi

		if hd_svc_enabled sqm; then
			hd_row warn "限速(SQM)" "SQM 会改写 TCP 参数，本身就是一个特征"
		fi

		# ---------------------------------------------------- TTL / MSS
		if hd_ttl_present; then
			hd_row ok "TTL 统一" "出网 TTL 已统一为 128（Windows 就是 128）"
		else
			hd_row warn "TTL 统一" "没找到 TTL 规则；转发出去的包 TTL 会是 63，上一跳一看就知道是 NAT"
		fi

		if hd_mss_present; then
			hd_row ok "MSS 统一" "TCP MSS 已钉死为 $HD_MSS"
		else
			hd_row info "MSS 统一" "未设置（可选，少一个差异）"
		fi

		# ---------------------------------------------------- DHCP 指纹
		dev=$(wan_iface)
		if [ -n "$dev" ]; then
			local host ven cid
			host=$(uci -q get "network.$dev.hostname" 2>/dev/null)
			ven=$(uci -q get "network.$dev.vendorid" 2>/dev/null)
			cid=$(uci -q get "network.$dev.clientid" 2>/dev/null)

			if [ "$ven" = "MSFT 5.0" ] && [ -n "$host" ] && [ -n "$cid" ]; then
				hd_row ok "DHCP 指纹" "主机名 $host / vendorid MSFT 5.0 / clientid 01+MAC —— 看起来像 Windows"
			else
				hd_row bad "DHCP 指纹" "主机名「${host:-空}」vendorid「${ven:-空}」clientid「${cid:-空}」—— 缺项会让上游一眼认出是路由器"
			fi

			if [ -n "$host" ]; then
				hd_row info "电脑身份" "当前叫 $host；只有被拉黑换 MAC 时才会跟着换，不换 MAC 就一直不变"
			fi
		fi

		# ---------------------------------------------------- 二层
		br=$(hd_wan_in_bridge)
		if [ -n "$br" ]; then
			hd_row bad "WAN 网桥" "WAN 口被桥进了 $br：二层直接暴露，DHCP Snooping / 端口 MAC 限制 / 组播泄漏都会变成真问题"
		else
			hd_row ok "WAN 网桥" "WAN 口不在任何网桥里"
		fi

		# ---------------------------------------------------- 定时联网
		found=""
		for s in $HD_QUIET_SVC; do
			hd_svc_enabled "$s" && found="$found $s"
		done
		if [ -n "$found" ]; then
			hd_row warn "定时联网服务" "还在跑：$(echo $found) —— 电脑不会定时往外发这些东西"
		else
			hd_row ok "定时联网服务" "没发现会定时往外发东西的服务"
		fi

		found=""
		for s in $HD_WATCH_SVC; do
			hd_svc_enabled "$s" && found="$found $s"
		done
		if [ -n "$found" ]; then
			hd_row info "隧道/代理类" "已装：$(echo $found) —— 这类工具大量外连，本身就很显眼，要单独排查"
		fi

		# ---------------------------------------------------- 路由协议 / 组播
		found=$(hd_route_found)
		if [ -n "$found" ]; then
			hd_row bad "路由协议" "在跑：$(echo $found) —— OSPF / RIP / BGP / PIM / IGMP 这类只有路由器会发，电脑一个都不发，是最响的警报"
		else
			hd_row ok "路由协议" "没有 OSPF / RIP / BGP / PIM / IGMP 这类守护进程在跑"
		fi

		found=$(hd_igmp_snoop_devs)
		if [ -n "$found" ]; then
			hd_row warn "IGMP 嗅探" "网桥 $(echo $found) 开着 IGMP 嗅探：路由器会自己往外发 IGMP 查询/报告，电脑不会"
		else
			hd_row ok "IGMP 嗅探" "网桥没有在往外发 IGMP"
		fi

		# ---------------------------------------------------- 各开关状态
		for grp in ipv6 offload sig routing quiet; do
			hd_row sw "$grp" "$(hd_flag "$grp")"
		done
		hd_row sw dhcp "$(uci -q get likepc.main.pc_fake 2>/dev/null | grep -q '^1$' && echo 1 || echo 0)"
	} >"$HD_REPORT" 2>/dev/null

	cat "$HD_REPORT"
	return 0
}

# ------------------------------------------------------------------ ① IPv6
hd_ipv6_kernel() {
	local d="$1"

	[ -n "$d" ] || return 0
	echo 0 >"/proc/sys/net/ipv6/conf/$d/router_solicitations" 2>/dev/null
	echo 0 >"/proc/sys/net/ipv6/conf/$d/accept_ra" 2>/dev/null
	echo 0 >"/proc/sys/net/ipv6/conf/$d/autoconf" 2>/dev/null
	echo 1 >"/proc/sys/net/ipv6/conf/$d/disable_ipv6" 2>/dev/null
	return 0
}

hd_hotplug_write() {
	mkdir -p "$(dirname "$HD_HOTPLUG")"

	cat >"$HD_HOTPLUG" <<'HDEOF'
#!/bin/sh
# 由 luci-app-likepc 写入：接口每次起来都禁掉 IPv6，避免内核往外发路由请求
[ "$ACTION" = "ifup" ] || exit 0
[ -n "$DEVICE" ] || exit 0
case "$DEVICE" in
	lo|br-lan|br-*) exit 0 ;;
esac
echo 0 > "/proc/sys/net/ipv6/conf/$DEVICE/router_solicitations" 2>/dev/null
echo 0 > "/proc/sys/net/ipv6/conf/$DEVICE/accept_ra" 2>/dev/null
echo 0 > "/proc/sys/net/ipv6/conf/$DEVICE/autoconf" 2>/dev/null
echo 1 > "/proc/sys/net/ipv6/conf/$DEVICE/disable_ipv6" 2>/dev/null
exit 0
HDEOF

	chmod 0755 "$HD_HOTPLUG" 2>/dev/null
	return 0
}

hd_ipv6() {
	local dev s p

	dev=$(wan_device)
	mkdir -p "$HD_DIR"

	hd_backup_file network
	hd_backup_file dhcp

	# 1) 所有接口都不再要 IPv6（地址和前缀都不要）
	for s in $(hd_ifaces); do
		p=$(uci -q get "network.$s.proto" 2>/dev/null)
		case "$p" in
			dhcpv6)
				log "接口 $s 是 IPv6 拨号，关掉它（不再请求前缀）"
				uci -q set "network.$s.proto=none"
				;;
			dhcp)
				uci -q delete "network.$s.ipv6"
				;;
		esac
	done

	# 2) 内网侧不再发 RA / DHCPv6 / NDP，也不下发前缀
	uci -q set dhcp.lan.ra=disabled
	uci -q set dhcp.lan.dhcpv6=disabled
	uci -q set dhcp.lan.ndp=disabled
	uci -q set dhcp.lan.master=0
	uci -q delete network.lan.ip6assign
	uci -q commit network
	uci -q commit dhcp

	# 3) 停掉 IPv6 服务
	hd_stop_svc odhcpd

	# 4) 内核层面：WAN 口不发路由请求、不收通告、整个关掉 IPv6
	hd_ipv6_kernel "$dev"

	# 5) 热插拔脚本，接口每次起来自动再来一遍
	hd_hotplug_write

	/etc/init.d/network reload >/dev/null 2>&1

	hd_on ipv6
	log "已关闭 IPv6：不再请求地址与前缀，内网不再发 RA，WAN(${dev:-未知}) 的 IPv6 已在内核层禁用"
	return 0
}

hd_ipv6_undo() {
	local dev

	dev=$(wan_device)

	if hd_restore_file network && hd_restore_file dhcp; then
		log "已还原 network / dhcp 配置（回到应用这项之前的样子）"
	else
		log "没找到 IPv6 的配置备份，只做最小恢复"
	fi

	hd_start_svc odhcpd
	rm -f "$HD_HOTPLUG"

	if [ -n "$dev" ]; then
		echo 0 >"/proc/sys/net/ipv6/conf/$dev/disable_ipv6" 2>/dev/null
	fi

	uci -q commit network 2>/dev/null
	uci -q commit dhcp 2>/dev/null
	/etc/init.d/network reload >/dev/null 2>&1

	hd_off ipv6
	log "已恢复 IPv6"
	return 0
}

# ------------------------------------------------------------------ ② 流量卸载
hd_offload() {
	mkdir -p "$HD_DIR"

	hd_backup_file firewall

	uci -q set firewall.@defaults[0].flow_offloading=0
	uci -q set firewall.@defaults[0].flow_offloading_hw=0
	uci -q commit firewall

	# 限速会改写 TCP 参数，一起停
	hd_svc_record_stop offload sqm

	/etc/init.d/firewall restart >/dev/null 2>&1

	hd_on offload
	log "已关闭流量卸载（软件 + 硬件）与限速：TTL、探针屏蔽这类规则从现在起才会真正生效"
	return 0
}

hd_offload_undo() {
	if hd_restore_file firewall; then
		log "已还原防火墙配置"
	fi

	hd_svc_restore offload
	/etc/init.d/firewall restart >/dev/null 2>&1

	hd_off offload
	log "已恢复流量卸载设置"
	return 0
}

# ------------------------------------------------------------------ ③ 出网特征统一
hd_nft_write() {
	local need_ttl="$1"

	mkdir -p "$HD_DIR"

	{
		echo "# 由 luci-app-likepc 自动生成（出网特征统一），请勿手工修改"
		echo "# 本文件由 /etc/config/firewall 的 include 段加载，"
		echo "# 渲染时位于 table inet fw4 内部 —— 所以这里只定义 chain，不写 table。"
		if [ "$need_ttl" = "1" ]; then
			echo
			echo "chain likepc_hd_ttl {"
			echo "	type filter hook postrouting priority mangle; policy accept;"
			echo "	ip ttl set 128"
			echo "}"
		fi
		echo
		echo "chain likepc_hd_mss {"
		echo "	type filter hook postrouting priority mangle; policy accept;"
		echo "	tcp flags & (syn | rst) == syn tcp option maxseg size set $HD_MSS"
		echo "}"
	} >"$HD_NFT"

	return 0
}

hd_sig() {
	local need_ttl=1

	mkdir -p "$HD_DIR"

	if hd_ttl_present; then
		need_ttl=0
		log "TTL 统一已经生效（防火墙规则里带了），这一项只补 MSS"
	fi

	if [ "$(fw_version)" = "4" ]; then
		hd_nft_write "$need_ttl"
		hd_nft_include_add
	else
		if [ "$need_ttl" = "1" ]; then
			iptables -t mangle -C POSTROUTING -j TTL --ttl-set 128 2>/dev/null ||
				iptables -t mangle -A POSTROUTING -j TTL --ttl-set 128 2>/dev/null
			log "已加上 TTL 统一规则（原防火墙规则里没有）"
		fi
		iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$HD_MSS" 2>/dev/null ||
			iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$HD_MSS" 2>/dev/null
	fi

	[ "$need_ttl" = "1" ] && hd_flag sig_ttl 1 || hd_flag sig_ttl 0

	/etc/init.d/firewall reload >/dev/null 2>&1 || /etc/init.d/firewall restart >/dev/null 2>&1

	hd_on sig
	log "已统一出网特征：TTL 128、TCP MSS $HD_MSS"
	return 0
}

hd_sig_undo() {
	local added

	added=$(hd_flag sig_ttl)

	if [ "$(fw_version)" = "4" ]; then
		hd_nft_include_del
		rm -f "$HD_NFT"
	else
		while iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$HD_MSS" 2>/dev/null; do :; done

		if [ "$added" = "1" ]; then
			while iptables -t mangle -D POSTROUTING -j TTL --ttl-set 128 2>/dev/null; do :; done
		fi
	fi

	/etc/init.d/firewall reload >/dev/null 2>&1 || /etc/init.d/firewall restart >/dev/null 2>&1

	hd_flag sig_ttl 0
	hd_off sig
	log "已撤销出网特征统一（主防火墙规则提供的那部分没动）"
	return 0
}

# ------------------------------------------------------------------ ④ DHCP 指纹
hd_dhcp() {
	load_config
	mac_pool_load

	pc_fake

	hd_on dhcp
	log "已伪装成 Windows 电脑（电脑名只在换 MAC 时才会跟着换）"
	return 0
}

hd_dhcp_undo() {
	load_config
	mac_pool_load

	pc_restore

	hd_flag dhcp 0
	log "已还原 WAN 原有 DHCP 参数"
	return 0
}

# ------------------------------------------------------------------ ⑤ 掐掉定时联网
hd_quiet() {
	local s

	mkdir -p "$HD_DIR"

	for s in $HD_QUIET_SVC; do
		hd_svc_record_stop quiet "$s"
	done

	hd_on quiet
	log "已停用所有会定时往外发东西的服务（撤销时会按名单恢复）"
	return 0
}

hd_quiet_undo() {
	hd_svc_restore quiet
	hd_off quiet
	log "已恢复被停用的服务"
	return 0
}

# ------------------------------------------------------------------ ⑥ 路由 / 组播协议
hd_routing() {
	local s v f

	mkdir -p "$HD_DIR"

	# 1) 在跑或开着自启的：停掉、取消自启，原来的启动状态记进名单
	for s in $(hd_route_found); do
		if hd_svc_enabled "$s"; then
			hd_svc_record_stop routing "$s"
		else
			killall "$s" >/dev/null 2>&1 && log "已结束路由/组播进程：$s"
		fi
	done

	# 2) 关掉网桥的 IGMP 嗅探（先记原值，撤销时照着还原）
	f="$HD_IGMP_FILE"
	for s in $(hd_igmp_snoop_devs); do
		v=$(uci -q get "network.$s.igmp_snooping" 2>/dev/null)
		grep -q "^$s|" "$f" 2>/dev/null || printf '%s|%s\n' "$s" "$v" >>"$f"
		uci -q set "network.$s.igmp_snooping=0"
		log "已关闭网桥 $s 的 IGMP 嗅探"
	done

	if [ -s "$f" ]; then
		uci -q commit network
		/etc/init.d/network reload >/dev/null 2>&1
	fi

	hd_on routing
	log "已关掉路由 / 组播协议（撤销时按名单恢复原来开着的那些）"
	return 0
}

hd_routing_undo() {
	local f s v

	hd_svc_restore routing

	f="$HD_IGMP_FILE"
	if [ -s "$f" ]; then
		while IFS='|' read -r s v; do
			[ -n "$s" ] || continue
			if [ -n "$v" ]; then
				uci -q set "network.$s.igmp_snooping=$v"
			else
				uci -q delete "network.$s.igmp_snooping"
			fi
		done <"$f"
		rm -f "$f"
		uci -q commit network
		/etc/init.d/network reload >/dev/null 2>&1
	fi

	hd_off routing
	log "已恢复路由 / 组播相关设置"
	return 0
}