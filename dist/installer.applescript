-- HyperVibe Setup — double-click installer.
-- Installs the menu-bar app + virtual-mic components (one admin password), then walks the user
-- through the permissions macOS forbids an app from granting itself. AppleScript so it is a real
-- double-clickable .app with a native password prompt and no Terminal.

on fileExists(p)
	try
		do shell script "/bin/test -e " & quoted form of p
		return true
	on error
		return false
	end try
end fileExists

on run
	set myPath to POSIX path of (path to me)
	set payload to myPath & "Contents/Resources/payload"

	display dialog "HyperVibe 安装器" & return & return & ¬
		"将安装:" & return & ¬
		"• HyperVibe(菜单栏 App)" & return & ¬
		"• 虚拟麦克风插件 + 后台采集服务" & return & return & ¬
		"需要一次管理员密码,并会短暂重启系统音频。" ¬
		buttons {"取消", "开始安装"} default button "开始安装" with title "HyperVibe Setup" with icon note

	-- Privileged install — one password prompt. (Installs the bundled PacketLogger too, if present.)
	try
		do shell script "/bin/bash " & quoted form of (payload & "/do_install.sh") & " " & quoted form of payload with administrator privileges
	on error errMsg
		display dialog "安装失败:" & return & return & errMsg buttons {"好"} default button "好" with icon stop
		return
	end try

	-- PacketLogger check AFTER install: if this build bundled it, it is now present and we say
	-- nothing. Only if it is still missing (a clean/redistributable build) do we point to the download.
	if not fileExists("/Applications/PacketLogger.app") then
		set r to display dialog "未检测到 PacketLogger.app。" & return & return & ¬
			"遥控器麦克风语音功能需要它 —— 这是 Apple 的免费工具,需登录 Apple ID 从开发者网站的 “Additional Tools for Xcode” 里下载,下完把 PacketLogger.app 拖到 应用程序 文件夹。" & return & return & ¬
			"其它功能不受影响。现在打开下载页吗?" ¬
			buttons {"跳过", "打开下载页"} default button "打开下载页" with title "HyperVibe Setup"
		if button returned of r is "打开下载页" then
			open location "https://developer.apple.com/download/all/?q=Additional+Tools+for+Xcode"
		end if
	end if

	-- Default config for THIS user, without clobbering an existing one.
	set cfgDir to (POSIX path of (path to home folder)) & ".config/siriremote"
	if not fileExists(cfgDir & "/config.jsonc") then
		do shell script "/bin/mkdir -p " & quoted form of cfgDir & ¬
			" && /bin/cp " & quoted form of (payload & "/config.jsonc") & " " & quoted form of (cfgDir & "/config.jsonc")
	end if

	-- The three permissions macOS will not let an app grant itself: open each pane, guide the toggle.
	display dialog "系统组件已安装 ✅" & return & return & ¬
		"接下来需要你手动开启 3 个权限(macOS 不允许 App 自己开)。" & return & ¬
		"我会依次打开对应设置页,请把 HyperVibe 的开关打开。" ¬
		buttons {"继续"} default button "继续" with title "HyperVibe Setup"

	open location "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
	display dialog "① 辅助功能(Accessibility)" & return & "打开列表里 HyperVibe 的开关(移动光标 / 发按键需要)。" buttons {"下一个"} default button "下一个" with title "权限 1/3"
	open location "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
	display dialog "② 输入监控(Input Monitoring)" & return & "打开 HyperVibe 的开关(读遥控器按键需要)。" buttons {"下一个"} default button "下一个" with title "权限 2/3"
	open location "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
	display dialog "③ 麦克风(Microphone)" & return & "打开 HyperVibe 的开关(内置麦回退 / 采集需要;首次运行也会自动弹窗)。" buttons {"完成"} default button "完成" with title "权限 3/3"

	do shell script "/usr/bin/open -a /Applications/HyperVibe.app"
	display dialog "安装完成 🎉" & return & return & ¬
		"HyperVibe 已启动(看菜单栏图标)。" & return & ¬
		"在 蓝牙 设置里配对你的 Siri Remote 即可使用。" & return & return & ¬
		"若遥控器麦克风没声音:确认已装 PacketLogger,并重启一次电脑。" ¬
		buttons {"好"} default button "好" with title "HyperVibe Setup"
end run
