package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
)

func TestIsPublicPath(t *testing.T) {
	cases := []struct {
		path string
		want bool
	}{
		{"/healthz", true},
		{"/auth/login", true},
		{"/api/shipping/webhook", true},
		{"/api/orders/1/healthz", true},
		{"/api/orders", false},
		{"/admin", false},
	}
	for _, tc := range cases {
		if got := isPublicPath(tc.path); got != tc.want {
			t.Fatalf("isPublicPath(%q)=%v want %v", tc.path, got, tc.want)
		}
	}
}

func TestIsPublicRequestInventoryGET(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/api/inventory/products", nil)
	if !isPublicRequest(req) {
		t.Fatal("GET /api/inventory/products should be public")
	}
	req = httptest.NewRequest(http.MethodPost, "/api/inventory/products", nil)
	if isPublicRequest(req) {
		t.Fatal("POST /api/inventory/products should not be public")
	}
}

func TestGetEnv(t *testing.T) {
	os.Unsetenv("TEST_GATEWAY_ENV")
	if got := getEnv("TEST_GATEWAY_ENV", "fallback"); got != "fallback" {
		t.Fatalf("got %q", got)
	}
	t.Setenv("TEST_GATEWAY_ENV", "set")
	if got := getEnv("TEST_GATEWAY_ENV", "fallback"); got != "set" {
		t.Fatalf("got %q", got)
	}
}
