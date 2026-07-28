package main

import (
	"os"
	"testing"
)

func TestGetEnv(t *testing.T) {
	os.Unsetenv("TEST_SVC_ENV")
	if got := getEnv("TEST_SVC_ENV", "fallback"); got != "fallback" {
		t.Fatalf("got %q", got)
	}
	t.Setenv("TEST_SVC_ENV", "set")
	if got := getEnv("TEST_SVC_ENV", "fallback"); got != "set" {
		t.Fatalf("got %q", got)
	}
}
