package main

import (
	"errors"
	"fmt"
	"testing"
	"time"
)

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
