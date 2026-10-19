package main

import (
	"bufio"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"tailscale.com/ipn/ipnstate"
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
		{name: "same site", login: "owner@example.com", site: "same-site", want: 403},
		{name: "same origin site", login: "owner@example.com", site: "same-origin", want: 200},
		{name: "none site", login: "owner@example.com", site: "none", want: 200},
		{name: "unknown site", login: "owner@example.com", site: "unexpected", want: 403},
		{name: "cross site", login: "owner@example.com", site: "cross-site", want: 403},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			secret := strings.Repeat("s", 64)
			called := false
			next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				called = true
				if r.Header.Get(ownerHeader) != secret || r.Header.Get(originHeader) != "1" || r.Header.Get(deviceHeader) != "node1" {
					t.Error("launch capability not injected")
				}
				if r.Header.Get("Authorization") != "" || r.Header.Get("X-Forwarded-For") != "" || r.Header.Get("Connection") != "" {
					t.Error("untrusted credentials forwarded")
				}
				w.WriteHeader(200)
			})
			lookup := func(ctx context.Context, addr string) (identity, error) {
				if addr != "100.64.1.2:1234" {
					t.Error("WhoIs did not receive socket address")
				}
				if tt.lookupErr {
					return identity{}, errors.New("no peer")
				}
				return identity{Login: tt.login, StableID: "node1", Name: "phone"}, nil
			}
			handler := authorize(next, lookup, []string{" owner@example.com "}, secret, accessPolicy{hosts: map[string]bool{"phone.test": true}})
			req := httptest.NewRequest("POST", "http://phone.test/agents/id/run", nil)
			req.RemoteAddr = "100.64.1.2:1234"
			req.Header.Set("Connection", ownerHeader+", "+originHeader+", "+deviceHeader)
			req.Header.Set(ownerHeader, "forged")
			req.Header.Set(originHeader, "forged")
			req.Header.Add(deviceHeader, "forged-device")
			req.Header.Add(deviceHeader, "second-forgery")
			req.Header.Set("Authorization", "Bearer forged")
			req.Header.Set("X-Forwarded-For", "100.1.2.3")
			req.Header.Set("Origin", tt.origin)
			if tt.site != "" {
				req.Header.Set("Sec-Fetch-Site", tt.site)
			}
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
	lookup := func(context.Context, string) (identity, error) {
		return identity{Login: "owner@example.com", StableID: "node1"}, nil
	}
	for _, tc := range []struct {
		logins []string
		secret string
	}{{nil, strings.Repeat("s", 64)}, {[]string{"owner@example.com"}, ""}} {
		handler := authorize(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { t.Fatal("must not reach upstream") }), lookup, tc.logins, tc.secret, accessPolicy{hosts: map[string]bool{"phone.test": true}})
		result := httptest.NewRecorder()
		handler.ServeHTTP(result, httptest.NewRequest("GET", "http://phone.test/phone", nil))
		if result.Code != 403 {
			t.Fatalf("got %d", result.Code)
		}
	}
}

func TestHostAllowlist(t *testing.T) {
	st := &ipnstate.Status{CertDomains: []string{"phone.tail.ts.net", "other.tail.ts.net"}, Self: &ipnstate.PeerStatus{DNSName: "phone.tail.ts.net."}, TailscaleIPs: []netip.Addr{netip.MustParseAddr("100.64.1.1"), netip.MustParseAddr("fd7a:115c:a1e0::1")}}
	policy := accessPolicy{hosts: acceptableHosts(st)}
	lookup := func(context.Context, string) (identity, error) { return identity{Login: "owner"}, nil }
	handler := authorize(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) }), lookup, []string{"owner"}, strings.Repeat("s", 64), policy)
	for _, host := range []string{"phone.tail.ts.net", "PHONE.TAIL.TS.NET:80", "other.tail.ts.net:443", "phone", "phone:80", "100.64.1.1", "100.64.1.1:80", "[fd7a:115c:a1e0::1]", "[fd7a:115c:a1e0::1]:80", "[FD7A:115C:A1E0:0:0:0:0:1]:80", "evil.com", "phone.tail.ts.net.evil.com", "100.64.1.2", "[fd7a:115c:a1e0::2]"} {
		t.Run(host, func(t *testing.T) {
			req := httptest.NewRequest("GET", "http://"+host+"/phone", nil)
			req.Header.Set("Origin", "http://"+host) // Includes the actual rebinding exploit.
			out := httptest.NewRecorder()
			handler.ServeHTTP(out, req)
			want := 200
			if strings.Contains(host, "evil.com") || host == "100.64.1.2" || host == "[fd7a:115c:a1e0::2]" {
				want = 421
			}
			if out.Code != want {
				t.Fatalf("got %d want %d", out.Code, want)
			}
		})
	}
}

func TestDevicePolicyAndReporting(t *testing.T) {
	for _, tc := range []struct {
		name, login, id string
		restrict        bool
		devices         map[string]bool
		want            int
	}{
		{name: "default all login devices", login: "owner", id: "second", want: 200},
		{name: "selected device", login: "owner", id: "first", restrict: true, devices: map[string]bool{"first": true}, want: 200},
		{name: "other device same login", login: "owner", id: "second", restrict: true, devices: map[string]bool{"first": true}, want: 403},
		{name: "empty selected devices", login: "owner", id: "first", restrict: true, want: 403},
		{name: "no login profile", id: "tagged", want: 403},
		{name: "missing stable ID", login: "owner", restrict: true, want: 403},
		{name: "selected device wrong login", login: "other", id: "first", restrict: true, devices: map[string]bool{"first": true}, want: 403},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var reports []deviceStatus
			lookup := func(context.Context, string) (identity, error) { return identity{tc.login, tc.id, "My phone"}, nil }
			policy := accessPolicy{hosts: map[string]bool{"phone.test": true}, restrictDevices: tc.restrict, devices: tc.devices, report: func(s deviceStatus) { reports = append(reports, s) }}
			handler := authorize(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) }), lookup, []string{"owner"}, strings.Repeat("s", 64), policy)
			out := httptest.NewRecorder()
			handler.ServeHTTP(out, httptest.NewRequest("GET", "http://phone.test/phone", nil))
			if out.Code != tc.want {
				t.Fatalf("got %d want %d", out.Code, tc.want)
			}
			if tc.id != "" && (len(reports) != 1 || reports[0] != (deviceStatus{tc.id, "My phone", tc.login, tc.want == 200})) {
				t.Fatalf("bad reports: %+v", reports)
			}
		})
	}
}

func TestReadLaunchSecret(t *testing.T) {
	secret := strings.Repeat("s", 64)
	for _, tc := range []struct {
		name, input string
		valid       bool
	}{
		{"valid", secret + "\n", true}, {"short", "abc\n", false}, {"EOF", secret, false}, {"empty", "\n", false},
		{"too long", strings.Repeat("x", 258) + "\n", false}, {"control", secret + "\r\n", false}, {"space", secret + " \n", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := readLaunchSecret(bufio.NewReaderSize(strings.NewReader(tc.input), 512))
			if (err == nil) != tc.valid || (tc.valid && got != secret) {
				t.Fatalf("unexpected parse result, err=%v", err)
			}
		})
	}
	reader := bufio.NewReader(strings.NewReader(secret + "\nremaining"))
	if _, err := readLaunchSecret(reader); err != nil {
		t.Fatal(err)
	}
	rest, _ := reader.ReadString('\n')
	if rest != "remaining" {
		t.Fatal("lost buffered lifetime stream")
	}
}

func TestStateLock(t *testing.T) {
	dir := t.TempDir()
	first, err := lockStateDirectory(dir)
	if err != nil {
		t.Fatal(err)
	}
	second, err := lockStateDirectory(dir)
	if err == nil {
		second.Close()
		t.Fatal("second lock succeeded")
	}
	if err.Error() != "another Osaurus instance is using phone access" {
		t.Fatal(err)
	}
	first.Close()
	next, err := lockStateDirectory(dir)
	if err != nil {
		t.Fatal(err)
	}
	next.Close()
}

func TestPrivateNodeName(t *testing.T) {
	dir := t.TempDir()
	first, err := nodeName(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(first) != 14 || !strings.HasPrefix(first, "osaurus-") {
		t.Fatal(first)
	}
	second, err := nodeName(dir)
	if err != nil || first != second {
		t.Fatal("name did not persist")
	}
	info, err := os.Stat(filepath.Join(dir, "node-name"))
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("name file permissions")
	}
	if err := os.WriteFile(filepath.Join(dir, "node-name"), []byte("Mac-hostname"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := nodeName(dir); err == nil {
		t.Fatal("accepted invalid persisted name")
	}
}

func TestFetchMetadataFailsClosed(t *testing.T) {
	lookup := func(context.Context, string) (identity, error) { return identity{Login: "owner"}, nil }
	handler := authorize(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { t.Fatal("reached upstream") }), lookup, []string{"owner"}, strings.Repeat("s", 64), accessPolicy{hosts: map[string]bool{"phone.test": true}})
	for _, values := range [][]string{{""}, {"same-origin", "cross-site"}, {"none", "same-origin"}} {
		req := httptest.NewRequest("GET", "http://phone.test/phone", nil)
		req.Header["Sec-Fetch-Site"] = values
		out := httptest.NewRecorder()
		handler.ServeHTTP(out, req)
		if out.Code != 403 {
			t.Fatalf("got %d for %+v", out.Code, values)
		}
	}
}
