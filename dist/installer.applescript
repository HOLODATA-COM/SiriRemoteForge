-- HyperVibe Setup — double-click installer.
-- Installs the menu-bar app + virtual-mic components (one admin password), then walks the user
-- through the permissions macOS forbids an app from granting itself. AppleScript so it is a real
-- double-clickable .app with a native password prompt and no Terminal.

use scripting additions

on fileExists(p)
	try
		do shell script ("/bin/test -e " & quoted form of p)
		return true
	on error
		return false
	end try
end fileExists

on run
	set myPath to POSIX path of (path to me)
	set payload to myPath & "Contents/Resources/payload"

	display dialog ("HyperVibe 安装器" & return & return & ¬
		"将安装:" & return & ¬
		"• HyperVibe(菜单栏 App)" & return & ¬
		"• 虚拟麦克风插件 + 后台采集服务" & return & ¬
		"• HyperVibe Uninstall 卸载器" & return & return & ¬
		"需要一次管理员密码并短暂重启系统音频。安装器随后会进行约 25 秒安全监测；若 coreaudiod 异常，会自动恢复旧插件。") ¬
		buttons {"取消", "开始安装"} default button "开始安装" with title "HyperVibe Setup" with icon note

	-- Privileged install — one password prompt plus a watchdog-protected HAL load.
	try
		do shell script ("/bin/bash " & quoted form of (payload & "/do_install.sh") & " " & quoted form of payload) with administrator privileges
	on error errMsg
		display dialog ("安装失败:" & return & return & errMsg) buttons {"好"} default button "好" with icon stop
		return
	end try

	-- Default config for THIS user, without clobbering an existing one.
	set cfgDir to (POSIX path of (path to home folder)) & ".config/siriremote"
	if not fileExists(cfgDir & "/config.jsonc") then
		do shell script ("/bin/mkdir -p " & quoted form of cfgDir & ¬
			" && /bin/cp " & quoted form of (payload & "/config.jsonc") & " " & quoted form of (cfgDir & "/config.jsonc"))
	end if

	-- Open one live readiness surface instead of blindly jumping through three System Settings
	-- panes. HyperVibe explains each capability, requests only the row the user clicks, and updates
	-- every status in place when the user returns from Settings.
	do shell script "/usr/bin/open -a /Applications/HyperVibe.app --args --system-check"
	display dialog ("安装完成 🎉" & return & return & ¬
		"HyperVibe 已启动,并打开实时“系统检查”。" & return & ¬
		"请按页面提示完成需要的权限;App 会自动确认状态,无需逐次重启。" & return & ¬
		"卸载器位于“应用程序”文件夹。" & return & ¬
		"遥控器语音所需的 PacketLogger 等可选项目也会在同一页面检查。") ¬
		buttons {"好"} default button "好" with title "HyperVibe Setup"
end run
