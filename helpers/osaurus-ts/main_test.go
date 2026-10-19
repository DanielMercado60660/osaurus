package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestAuthorize(t *testing.T) {
	tests := []struct {
		name, login, origin, site string
		lookupErr                 bool
		want                      int
	}{
		{name: "owner", login: "Owner@Example.com", want: 200},
		{name: "other user", login: "other@example.com", want: 403},
		{name: "unknown peer", lookupErr: true, want: 403},
		{name: "no profile", want: 403},
		{name: "same origin", login: "owner@example.com", origin: "http://phone.test", want: 200},
		{name: "cross origin", login: "owner@example.com", origin: "http://evil.test", want: 403},
		{name: "null origin", login: "owner@example.com", origin: "null", want: 403},
		{name: "wrong scheme", login: "owner@example.com", origin: "https://phone.test", want: 403},
		{name: "cross site", login: "owner@example.com", site: "cross-site", want: 403},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			secret := strings.Repeat("s", 64)
			called := false
			next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				called = true
				if r.Header.Get(ownerHeader) != secret || r.Header.Get(originHeader) != "1" {
					t.Error("launch capability not injected")
				}
				if r.Header.Get("Authorization") != "" || r.Header.Get("X-Forwarded-For") != "" || r.Header.Get("Connection") != "" {
					t.Error("untrusted credentials forwarded")
				}
				w.WriteHeader(200)
			})
			lookup := func(ctx context.Context, addr string) (string, error) {
				if addr != "100.64.1.2:1234" {
					t.Error("WhoIs did not receive socket address")
				}
				if tt.lookupErr {
					return "", errors.New("no peer")
				}
				return tt.login, nil
			}
			handler := authorize(next, lookup, []string{" owner@example.com "}, secret)
			req := httptest.NewRequest("POST", "http://phone.test/agents/id/run", nil)
			req.RemoteAddr = "100.64.1.2:1234"
			req.Header.Set("Connection", ownerHeader+", "+originHeader)
			req.Header.Set(ownerHeader, "forged")
			req.Header.Set(originHeader, "forged")
			req.Header.Set("Authorization", "Bearer forged")
			req.Header.Set("X-Forwarded-For", "100.1.2.3")
			req.Header.Set("Origin", tt.origin)
			req.Header.Set("Sec-Fetch-Site", tt.site)
			result := httptest.NewRecorder()
			handler.ServeHTTP(result, req)
			if result.Code != tt.want {
				t.Fatalf("got %d want %d", result.Code, tt.want)
			}
			if called != (tt.want == 200) {
				t.Fatal("unexpected upstream access")
			}
		})
	}
}
func TestFailClosed(t *testing.T) {
	lookup := func(context.Context, string) (string, error) { return "owner@example.com", nil }
	for _, tc := range []struct {
		logins []string
		secret string
	}{{nil, strings.Repeat("s", 64)}, {[]string{"owner@example.com"}, ""}} {
		handler := authorize(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { t.Fatal("must not reach upstream") }), lookup, tc.logins, tc.secret)
		result := httptest.NewRecorder()
		handler.ServeHTTP(result, httptest.NewRequest("GET", "http://phone.test/phone", nil))
		if result.Code != 403 {
			t.Fatalf("got %d", result.Code)
		}
	}
}
