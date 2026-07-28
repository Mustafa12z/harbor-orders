package main

import (
	"os"
	"testing"
)

func TestGetEnv(t *testing.T) {
	os.Unsetenv("TEST_ORDER_ENV")
	if got := getEnv("TEST_ORDER_ENV", "fallback"); got != "fallback" {
		t.Fatalf("got %q", got)
	}
	t.Setenv("TEST_ORDER_ENV", "set")
	if got := getEnv("TEST_ORDER_ENV", "fallback"); got != "set" {
		t.Fatalf("got %q", got)
	}
}
