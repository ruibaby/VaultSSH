package main

import (
	"errors"
	"fmt"
	"testing"
	"time"
)

func TestApprovalMessagesRecordWindowAndSource(t *testing.T) {
	t.Setenv("VAULTSSH_LANGUAGE", "en")
	for reason, want := range map[string]string{
		"allowed:1800": "Allowed for 30 minutes",
		"allowed:300":  "Allowed for 5 minutes",
		"allowed:60":   "Allowed for 1 minute",
		"allowed:6":    "Allowed for 6 seconds",
		"allowed:1":    "Allowed for 1 second",
		"allowed_once": "Allowed once",
		"cached:300":   "Cached approval is valid for 5 minutes",
		"cached:1799":  "Cached approval is valid for 1799 seconds",
		"cached:3600":  "Cached approval is valid for 60 minutes",
		"cached:60":    "Cached approval is valid for 1 minute",
		"cached:6":     "Cached approval is valid for 6 seconds",
		"cached:1":     "Cached approval is valid for 1 second",
	} {
		if got := approvalMessage(reason); got != want {
			t.Fatalf("%s = %q, want %q", reason, got, want)
		}
	}
	for reason, want := range map[string]struct {
		reason string
		grace  int
	}{
		"allowed:1800": {"allowed", 1800},
		"cached:300":   {"cached", 300},
		"allowed_once": {"allowed_once", 0},
	} {
		event := approvalEvent(testPeer(), testApprovalKey(), "ok", reason)
		if event.Reason != want.reason || event.GraceSeconds != want.grace {
			t.Fatalf("%s logged as %+v", reason, event)
		}
	}
}

func TestApprovalDurationSingularChinese(t *testing.T) {
	t.Setenv("VAULTSSH_LANGUAGE", "zh-Hans")
	for reason, want := range map[string]string{
		"allowed:60": "已允许 1 分钟",
		"allowed:1":  "已允许 1 秒",
		"allowed:6":  "已允许 6 秒",
		"cached:60":  "临时授权有效（缓存，1 分钟）",
		"cached:1":   "临时授权有效（缓存，1 秒）",
		"cached:6":   "临时授权有效（缓存，6 秒）",
	} {
		if got := approvalMessage(reason); got != want {
			t.Fatalf("%s = %q, want %q", reason, got, want)
		}
	}
}

func TestLocalizedDiagnostics(t *testing.T) {
	for _, language := range []string{"en", "zh-Hans", "fr"} {
		t.Run(language, func(t *testing.T) {
			t.Setenv("VAULTSSH_LANGUAGE", language)
			want := "Approval timed out"
			if language == "zh-Hans" {
				want = "等待确认超时"
			}
			if got := approvalMessage("timeout"); got != want {
				t.Fatalf("got %q, want %q", got, want)
			}
			a, _ := testApprover(time.Millisecond)
			allowed, reason := a.Approve(testPeer(), testApprovalKey())
			if allowed || reason != "timeout" {
				t.Fatalf("language affected approval result: %v %q", allowed, reason)
			}
			event := approvalEvent(testPeer(), testApprovalKey(), "denied", reason)
			if event.Reason != "timeout" || event.Detail != want {
				t.Fatalf("event = %+v", event)
			}
			cause := errors.New("underlying error")
			err := fmt.Errorf(localized("Could not parse private key: %w"), cause)
			if !errors.Is(err, cause) {
				t.Fatal("translation lost wrapped error")
			}
		})
	}
}
