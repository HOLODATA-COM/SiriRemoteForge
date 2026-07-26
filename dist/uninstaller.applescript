-- HyperVibe Uninstall — removes the app and every system component installed by Full Setup.
-- User config and Apple's PacketLogger are deliberately preserved.

use scripting additions

on run
	set myPath to POSIX path of (path to me)
	set scriptPath to myPath & "Contents/Resources/do_uninstall.sh"

	set answer to display dialog ("卸载 HyperVibe？" & return & return & ¬
		"将移除：" & return & ¬
		"• HyperVibe 菜单栏 App" & return & ¬
		"• Siri Remote Mic 虚拟麦克风" & return & ¬
		"• 后台采集服务" & return & return & ¬
		"你的 ~/.config/siriremote 配置和 Apple PacketLogger 会保留。") ¬
		buttons {"取消", "卸载"} default button "取消" cancel button "取消" with title "HyperVibe Uninstall" with icon caution

	if button returned of answer is not "卸载" then return

	try
		do shell script ("/bin/bash " & quoted form of scriptPath) with administrator privileges
	on error errMsg
		display dialog ("卸载失败：" & return & return & errMsg) buttons {"好"} default button "好" with icon stop
		return
	end try

	display dialog ("HyperVibe 已卸载。" & return & return & ¬
		"你的个人配置和 PacketLogger 未被删除。") ¬
		buttons {"好"} default button "好" with title "HyperVibe Uninstall"
end run
