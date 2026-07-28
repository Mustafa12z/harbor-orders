package main

import (
	"os"
	"testing"
)

func TestGetEnv(t *testing.T) {
	os.Unsetenv("TEST_WORKER_ENV")
	if got := getEnv("TEST_WORKER_ENV", "fallback"); got != "fallback" {
		t.Fatalf("got %q", got)
	}
	t.Setenv("TEST_WORKER_ENV", "set")
	if got := getEnv("TEST_WORKER_ENV", "fallback"); got != "set" {
		t.Fatalf("got %q", got)
	}
}
