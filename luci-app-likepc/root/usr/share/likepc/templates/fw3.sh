#!/bin/sh
# luci-app-likepc —— firewall3 (iptables) 规则
#
# 本文件由模板渲染而来，模板在源码里（随插件一起编译进固件）：
#     /usr/share/likepc/templates/fw3.sh
# 设备上这份是插件生成的：
#     /etc/likepc/firewall.sh
# 再由 /etc/config/firewall 的 include 段（type script）在防火墙每次启动时执行，
# 等价于手工把规则写进 /etc/firewall.user。想改规则就改这个模板。
#
# 渲染时会替换的占位符（写法：名字两边各加一个 @ 号）：
#     LAN_CIDR     内网网段，例如 192.168.8.0/24
#     ROUTER_IP    路由器后台地址，例如 192.168.8.1
#
# 用法：默认执行 add_rules；带 del / remove / stop 参数时执行 del_rules。

LAN_CIDR="@LAN_CIDR@"
ROUTER_IP="@ROUTER_IP@"

_del_all() {
	while "$@" 2>/dev/null; do :; done
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
	iptables -t nat -A ntp_force_local -d $LAN_CIDR -j RETURN
	iptables -t nat -A ntp_force_local -s $LAN_CIDR -j DNAT --to-destination $ROUTER_IP

	# DNS 强制走路由器 dnsmasq
	iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 53
	iptables -t nat -A PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 53

	return 0
}

case "$1" in
	del|remove|stop) del_rules ;;
	*) add_rules ;;
esac
