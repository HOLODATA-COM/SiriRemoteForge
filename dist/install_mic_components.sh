#!/bin/bash
# install_mic_components.sh — privileged component-only install launched by HyperVibe itself.
# $1 is HyperVibe.app/Contents/Resources/MicrophoneSetup.
set -euo pipefail

PAYLOAD="${1:?microphone setup payload required}"
[ -d "$PAYLOAD" ] || { echo "安装资源不存在：$PAYLOAD" >&2; exit 1; }
[ -x "/Applications/PacketLogger.app/Contents/Resources/packetlogger" ] || {
    echo "请先将 PacketLogger.app 放入“应用程序”文件夹。" >&2
    exit 1
}

SUPPORT="/Library/Application Support/SiriRemoteMic"
HAL="/Library/Audio/Plug-Ins/HAL"
DRIVER="SiriRemoteMic.driver"
PLIST_NAME="au.holodata.SiriRemoteMic.captured.plist"
PLIST_DST="/Library/LaunchDaemons/$PLIST_NAME"

for required in "$DRIVER" srm_router srm_captured "$PLIST_NAME"; do
    [ -e "$PAYLOAD/$required" ] || {
        echo "安装包不完整，缺少：$required" >&2
        exit 1
    }
done

/usr/bin/xattr -dr com.apple.quarantine "$PAYLOAD" 2>/dev/null || true

/bin/mkdir -p "$HAL" "$SUPPORT"
/bin/rm -rf "$HAL/$DRIVER"
/bin/cp -R "$PAYLOAD/$DRIVER" "$HAL/"
/usr/sbin/chown -R root:wheel "$HAL/$DRIVER"

/bin/cp "$PAYLOAD/srm_router" "$SUPPORT/srm_router"
/bin/cp "$PAYLOAD/srm_captured" "$SUPPORT/srm_captured"
/usr/sbin/chown root:wheel "$SUPPORT/srm_router" "$SUPPORT/srm_captured"
/bin/chmod 755 "$SUPPORT/srm_router" "$SUPPORT/srm_captured"

/bin/cp "$PAYLOAD/$PLIST_NAME" "$PLIST_DST"
/usr/sbin/chown root:wheel "$PLIST_DST"
/bin/chmod 644 "$PLIST_DST"

/bin/launchctl unload -w "$PLIST_DST" 2>/dev/null || true
/bin/launchctl load -w "$PLIST_DST"

# Loading a HAL plug-in requires one brief, machine-wide CoreAudio restart.
/usr/bin/killall coreaudiod 2>/dev/null || true

echo "Siri Remote Mic 组件安装完成。"
