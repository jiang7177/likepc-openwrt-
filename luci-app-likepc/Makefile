#
# Copyright (C) 2026 topjy
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-likepc
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=topjy

LUCI_TITLE:=LuCI app: likepc (模拟pc) - ping check, WAN MAC rotation, firewall rules, PC masquerade
LUCI_DESCRIPTION:=Web UI for likepc (shown in LuCI as "模拟pc", the portal \
	authentication part is intentionally left out): external ping check target, \
	run at boot, anti-offline monitoring, consecutive-failure alerts, WAN MAC \
	rotation (5 pre-generated MACs) against blacklists, one-click firewall rules \
	(firewall3 iptables / firewall4 nftables include) and Windows PC masquerading.
# 注意：这里只声明 luci-base（不认证，用不到 curl），
# 刻意不把 iptables-mod-filter / kmod-ipt-filter / iptables-mod-ipopt 之类的
# 防火墙扩展写进依赖：它们在各个固件里包名和可用性都不一样，写成编译依赖会让
# 整个包编译失败。插件改为在运行时检测缺什么，并在 LuCI 上弹提示，
# 需要的话由使用者自己在固件里编入。
LUCI_DEPENDS:=+luci-base
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/conffiles
/etc/config/likepc
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0

# 从 Windows/压缩包复制过来的文件可能没有执行权限，这里兜底修一下
chmod 0755 /etc/init.d/likepc 2>/dev/null
chmod 0755 /usr/share/likepc/likepc.sh 2>/dev/null

# 从「校园网认证」插件迁移过来时，清掉它早期版本留下的独立 nft 表 / init 脚本
if [ -f /etc/init.d/campus-auth-fw ]; then
	/etc/init.d/campus-auth-fw stop >/dev/null 2>&1
	/etc/init.d/campus-auth-fw disable >/dev/null 2>&1
	rm -f /etc/init.d/campus-auth-fw
fi
nft delete table ip campus_auth 2>/dev/null

# 从上一个名字（luci-app-campus-tools）迁移过来时，清掉它的服务与配置
if [ -f /etc/init.d/campus_tools ]; then
	/etc/init.d/campus_tools stop >/dev/null 2>&1
	/etc/init.d/campus_tools disable >/dev/null 2>&1
	rm -f /etc/init.d/campus_tools
fi
rm -f /etc/config/campus_tools
rm -rf /etc/campus-tools

# 注册开机启动（具体是否真的检测由 /etc/config/likepc 的 enabled 决定）
/etc/init.d/likepc enable >/dev/null 2>&1

# 清掉 LuCI 菜单/JS 缓存，装完刷新页面即可看到菜单
rm -rf /tmp/luci-* 2>/dev/null

exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0

/etc/init.d/likepc stop >/dev/null 2>&1
/etc/init.d/likepc disable >/dev/null 2>&1

# 把本插件加过的防火墙规则和 include 段撤掉，不给系统留垃圾
/usr/share/likepc/likepc.sh fwdel >/dev/null 2>&1
rm -f /etc/likepc/fw4.nft /etc/likepc/firewall.sh 2>/dev/null

exit 0
endef

# call BuildPackage - OpenWrt buildroot signature