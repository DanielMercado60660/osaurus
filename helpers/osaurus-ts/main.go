// osaurus-ts is a userspace tailnet proxy. It never binds a host LAN socket.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"tailscale.com/tsnet"
)

const ownerHeader = "X-Osaurus-Phone-Secret"
const originHeader = "X-Osaurus-Phone-Origin"

type identityLookup func(context.Context, string) (string, error)

// Every request is identified from its actual tailnet socket, never forwarded headers.
// A same-origin check also prevents a malicious web page from using the owner's
// tailnet connection as ambient authority (including on the HTTP fallback).
func authorize(next http.Handler, lookup identityLookup, logins []string, secret string) http.Handler {
	allowed := map[string]bool{}
	for _, login := range logins {
		if s := strings.ToLower(strings.TrimSpace(login)); s != "" {
			allowed[s] = true
		}
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		login, err := lookup(r.Context(), r.RemoteAddr)
		if err != nil || !allowed[strings.ToLower(login)] || len(secret) < 32 {
			http.Error(w, "Forbidden", 403)
			return
		}
		if origin := r.Header.Get("Origin"); origin != "" {
			u, err := url.Parse(origin)
			scheme := "http"
			if r.TLS != nil {
				scheme = "https"
			}
			if err != nil || u.Scheme != scheme || u.Host != r.Host || u.Path != "" {
				http.Error(w, "Forbidden origin", 403)
				return
			}
		}
		if site := r.Header.Get("Sec-Fetch-Site"); site == "cross-site" {
			http.Error(w, "Forbidden site", 403)
			return
		}
		// Do not let hop-by-hop nominations strip our capability after injection.
		r.Header.Del("Connection")
		r.Header.Del(ownerHeader)
		r.Header.Del(originHeader)
		r.Header.Del("Authorization")
		r.Header.Del("Forwarded")
		r.Header.Del("X-Forwarded-For")
		r.Header.Del("X-Forwarded-Host")
		r.Header.Del("X-Forwarded-Proto")
		r.Header.Set(ownerHeader, secret)
		r.Header.Set(originHeader, "1")
		next.ServeHTTP(w, r)
	})
}

type status struct {
	Type  string `json:"type"`
	Value string `json:"value,omitempty"`
}

var outputMu sync.Mutex

func emit(kind, value string) {
	outputMu.Lock()
	defer outputMu.Unlock()
	_ = json.NewEncoder(os.Stdout).Encode(status{kind, value})
}

func run() error {
	secret := os.Getenv("OSAURUS_PHONE_SECRET")
	if len(secret) < 32 {
		return errors.New("missing launch secret")
	}
	target, err := url.Parse(os.Getenv("OSAURUS_PHONE_UPSTREAM"))
	if err != nil || target.Scheme != "http" || target.Hostname() != "127.0.0.1" || target.Port() == "" {
		return errors.New("upstream must be loopback HTTP with a port")
	}
	dir := os.Getenv("OSAURUS_PHONE_STATE")
	if dir == "" {
		return errors.New("missing state directory")
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	if err := os.Chmod(dir, 0700); err != nil {
		return err
	}
	hostname, _ := os.Hostname()
	hostname = strings.Split(hostname, ".")[0]
	hostname = strings.Map(func(r rune) rune {
		if r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-' {
			return r
		}
		return '-'
	}, strings.ToLower(hostname))
	if len(hostname) > 45 {
		hostname = hostname[:45]
	}
	s := &tsnet.Server{Dir: dir, Hostname: "osaurus-" + hostname, Ephemeral: false, Logf: func(string, ...any) {}, UserLogf: func(string, ...any) {}}
	defer s.Close()
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	// Parent owns stdin. EOF ensures an app crash cannot leave a proxy behind.
	go func() { _, _ = io.Copy(io.Discard, os.Stdin); cancel() }()
	lc, err := s.LocalClient()
	if err != nil {
		return err
	}
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		last := ""
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				st, err := lc.Status(ctx)
				if err == nil && st.AuthURL != "" && st.AuthURL != last {
					last = st.AuthURL
					emit("login_url", last)
				}
			}
		}
	}()
	st, err := s.Up(ctx)
	if err != nil {
		return err
	}
	logins := strings.Split(os.Getenv("OSAURUS_PHONE_LOGINS"), ",")
	if strings.TrimSpace(os.Getenv("OSAURUS_PHONE_LOGINS")) == "" {
		if st.Self == nil {
			return errors.New("node has no owner; configure allowed logins")
		}
		owner := st.User[st.Self.UserID].LoginName
		if owner == "" {
			return errors.New("node has no login owner; configure allowed logins")
		}
		logins = []string{owner}
	}
	emit("owner_login", strings.Join(logins, ","))
	scheme := "https"
	var listener net.Listener
	if len(st.CertDomains) > 0 {
		// Provision/check the certificate before advertising HTTPS. A tailnet
		// with HTTPS disabled or certificate issuance unavailable can still chat.
		certCtx, cancelCert := context.WithTimeout(ctx, 30*time.Second)
		_, _, err = lc.CertPair(certCtx, st.CertDomains[0])
		cancelCert()
		if err == nil {
			listener, err = s.ListenTLS("tcp", ":443")
		}
	} else {
		err = errors.New("tailnet certificates unavailable")
	}
	if err != nil {
		scheme = "http"
		listener, err = s.Listen("tcp", ":80")
	}
	if err != nil {
		return err
	}
	defer listener.Close()
	host := ""
	if scheme == "https" && len(st.CertDomains) > 0 {
		host = st.CertDomains[0]
	} else if st.Self != nil && st.CurrentTailnet != nil && st.CurrentTailnet.MagicDNSEnabled {
		host = strings.TrimSuffix(st.Self.DNSName, ".")
	}
	if host == "" && len(st.TailscaleIPs) > 0 {
		host = st.TailscaleIPs[0].String()
		if strings.Contains(host, ":") {
			host = "[" + host + "]"
		}
	}
	if host == "" {
		return errors.New("no tailnet address")
	}
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.FlushInterval = -1
	proxy.ErrorLog = log.New(io.Discard, "", 0)
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) { http.Error(w, "Mac server unavailable", 502) }
	lookup := func(ctx context.Context, addr string) (string, error) {
		who, err := lc.WhoIs(ctx, addr)
		if err != nil {
			return "", err
		}
		if who.UserProfile == nil {
			return "", errors.New("no user profile")
		}
		return who.UserProfile.LoginName, nil
	}
	server := &http.Server{Handler: authorize(proxy, lookup, logins, secret), ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 32 * 1024}
	go func() { <-ctx.Done(); _ = server.Close() }()
	emit("dns_name", host)
	emit("running", scheme+"://"+host+"/phone")
	err = server.Serve(listener)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}
func main() {
	if err := run(); err != nil {
		emit("error", fmt.Sprint(err))
		os.Exit(1)
	}
}
