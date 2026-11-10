package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

// The app passes its resolved language so native UI and helper diagnostics agree.
func localized(english string) string {
	if strings.HasPrefix(strings.ToLower(os.Getenv("VAULTSSH_LANGUAGE")), "zh") {
		if value, ok := chineseMessages[english]; ok {
			return value
		}
	}
	return english
}

func approvalMessage(reason string) string {
	if strings.HasPrefix(reason, "allowed:") {
		if seconds, err := strconv.Atoi(strings.TrimPrefix(reason, "allowed:")); err == nil {
			return allowedMessage(seconds)
		}
	}
	if strings.HasPrefix(reason, "cached:") {
		if seconds, err := strconv.Atoi(strings.TrimPrefix(reason, "cached:")); err == nil {
			return cachedMessage(seconds)
		}
	}
	switch reason {
	case "unavailable":
		return localized("Approval channel unavailable")
	case "closed":
		return localized("Approval channel closed")
	case "cached":
		return localized("Cached approval is valid")
	case "busy":
		return localized("Too many pending requests. Try again later.")
	case "create_failed":
		return localized("Could not create approval request")
	case "send_failed":
		return localized("Could not send approval request")
	case "timeout":
		return localized("Approval timed out")
	case "revoked":
		return localized("Approval revoked")
	case "expired":
		return localized("Approval request expired")
	case "denied":
		return localized("Denied by user")
	case "allowed_once":
		return localized("Allowed once")
	case "allowed":
		// Older logs used this reason for a cached grant.
		return localized("Allowed by user")
	default:
		return localized("Approval channel unavailable")
	}
}

func allowedMessage(seconds int) string {
	if seconds <= 0 {
		return localized("Allowed once")
	}
	return durationMessage("Allowed", seconds)
}

func cachedMessage(seconds int) string {
	return durationMessage("Cached approval is valid", seconds)
}

// durationMessage uses a singular unit for exactly one minute or second so
// English activity details do not say "1 minutes" or "1 seconds".
func durationMessage(prefix string, seconds int) string {
	if seconds%60 == 0 {
		minutes := seconds / 60
		unit := "minutes"
		if minutes == 1 {
			unit = "minute"
		}
		return fmt.Sprintf(localized(prefix+" for %d "+unit), minutes)
	}
	unit := "seconds"
	if seconds == 1 {
		unit = "second"
	}
	return fmt.Sprintf(localized(prefix+" for %d "+unit), seconds)
}

var chineseMessages = map[string]string{
	"Secure CLI transport is unavailable. Install the supported npm CLI.":  "安全 CLI 通道不可用，请安装受支持的 npm CLI。",
	"Invalid CLI credential input.":                                        "CLI 凭据输入无效。",
	"Secure CLI command failed. Check your login, server and network.":     "安全 CLI 命令失败，请检查登录状态、服务器和网络。",
	"The SSH socket stopped unexpectedly.":                                 "SSH 套接字意外停止。",
	"%s: missing private key":                                              "%s: 没有私钥字段",
	"Allowed by user":                                                      "用户允许",
	"Allowed once":                                                         "已允许一次",
	"Allowed for %d minute":                                                "已允许 %d 分钟",
	"Allowed for %d minutes":                                               "已允许 %d 分钟",
	"Allowed for %d second":                                                "已允许 %d 秒",
	"Allowed for %d seconds":                                               "已允许 %d 秒",
	"Cached approval is valid":                                             "临时授权有效（缓存）",
	"Cached approval is valid for %d minute":                               "临时授权有效（缓存，%d 分钟）",
	"Cached approval is valid for %d minutes":                              "临时授权有效（缓存，%d 分钟）",
	"Cached approval is valid for %d second":                               "临时授权有效（缓存，%d 秒）",
	"Cached approval is valid for %d seconds":                              "临时授权有效（缓存，%d 秒）",
	"An unknown key was requested.":                                        "请求了未知密钥",
	"Another agent is already running.":                                    "另一个 agent 已在运行",
	"Another agent is running. Quit the previous VaultSSH instance first.": "另一个 agent 已在运行，请先退出旧版 VaultSSH",
	"Approval channel closed":                                              "授权通道已关闭",
	"Approval channel unavailable":                                         "授权通道不可用",
	"Approval request expired":                                             "确认请求已过期",
	"Approval revoked":                                                     "授权已撤销",
	"Approval timed out":                                                   "等待确认超时",
	"Could not create approval request":                                    "无法生成确认请求",
	"Could not create signer: %w":                                          "无法创建签名器: %w",
	"Could not parse bw output: %w":                                        "解析 bw 输出失败: %w",
	"Could not parse private key: %w":                                      "无法解析私钥: %w",
	"Could not parse signing request: ":                                    "解析签名请求失败: ",
	"Could not read request: ":                                             "读取请求失败: ",
	"Could not send approval request":                                      "无法发送确认请求",
	"Denied by user":                                                       "用户拒绝",
	"Keys: %d":                                                             "%d 个密钥",
	"No Bitwarden session. Unlock in the app.":                             "没有 Bitwarden 会话，请在 App 中解锁",
	"No SSH key items found in the vault.":                                 "保险库中没有 SSH key 项目",
	"No usable SSH keys: %s":                                               "没有可用的 SSH key: %s",
	"Passphrase-protected private keys are not supported.":                 "带 passphrase 的私钥暂不支持",
	"Sync failed; using the local cache: ":                                 "同步未完成，当前使用本地缓存：",
	"Temporary approval is valid":                                          "临时授权有效",
	"Too many pending requests. Try again later.":                          "待确认请求过多，请稍后重试",
	"bw %s failed: %s":                                                     "bw %s 失败: %s",
	"bw list did not return a JSON array.":                                 "bw list 输出不是 JSON 数组",
	"bw list did not return a JSON array: %w":                              "bw list 输出不是 JSON 数组: %w",
	"bw list failed: %s":                                                   "bw list 失败: %s",
}
