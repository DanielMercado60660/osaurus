// osaurus-ts serves HTTP only inside its userspace tailnet. While enabled,
// tsnet also opens a host UDP WireGuard socket; automatic port mapping is disabled.
package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/netip"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"tailscale.com/envknob"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tsnet"
)

const ownerHeader = "X-Osaurus-Phone-Secret"
const originHeader = "X-Osaurus-Phone-Origin"

type identity struct {
	Login    string
	StableID string
	Name     string
}
type identityLookup func(context.Context, string) (identity, error)
type deviceStatus struct {
	StableID string `json:"stableID"`
	Name     string `json:"name"`
	Login    string `json:"login"`
	Allowed  bool   `json:"allowed"`
}
type accessPolicy struct {
	hosts           map[string]bool
	restrictDevices bool
	devices         map[string]bool
	report          func(deviceStatus)
}

// Host is untrusted even when Origin matches it (DNS rebinding).
func normalizedHost(host string) string {
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	host = strings.TrimSuffix(strings.TrimPrefix(host, "["), "]")
	if ip, err := netip.ParseAddr(host); err == nil {
		return ip.String()
	}
	return strings.ToLower(host)
}

func acceptableHosts(st *ipnstate.Status) map[string]bool {
	hosts := map[string]bool{}
	add := func(host string) {
		if host != "" {
			hosts[normalizedHost(strings.TrimSuffix(host, "."))] = true
		}
	}
	for _, domain := range st.CertDomains {
		add(domain)
	}
	if st.Self != nil {
		name := strings.TrimSuffix(st.Self.DNSName, ".")
		add(name)
		add(strings.Split(name, ".")[0])
		for _, ip := range st.Self.TailscaleIPs {
			add(ip.String())
		}
	}
	for _, ip := range st.TailscaleIPs {
		add(ip.String())
	}
	return hosts
}

// Every request is identified from its actual tailnet socket, never forwarded headers.
// A same-origin check also prevents a malicious web page from using the owner's
// tailnet connection as ambient authority (including on the HTTP fallback).
func authorize(next http.Handler, lookup identityLookup, logins []string, secret string, policy accessPolicy) http.Handler {
	allowed := map[string]bool{}
	for _, login := range logins {
		if s := strings.ToLower(strings.TrimSpace(login)); s != "" {
			allowed[s] = true
		}
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		peer, err := lookup(r.Context(), r.RemoteAddr)
		granted := false
		report := func(allowed bool) {
			if err == nil && peer.StableID != "" && policy.report != nil {
				policy.report(deviceStatus{peer.StableID, peer.Name, peer.Login, allowed})
			}
		}
		defer func() {
			if !granted {
				report(false)
			}
		}()
		if !policy.hosts[normalizedHost(r.Host)] {
			http.Error(w, "Misdirected request", http.StatusMisdirectedRequest)
			return
		}
		if err != nil || !allowed[strings.ToLower(peer.Login)] || len(secret) < 32 ||
			(policy.restrictDevices && (peer.StableID == "" || !policy.devices[peer.StableID])) {
			http.Error(w, "Forbidden", 403)
			return
		}
		if origin := r.Header.Get("Origin"); origin != "" {
			u, err := url.Parse(origin)
			scheme := "http"
			if r.TLS != nil {
				scheme = "https"
			}
			if err != nil || u.Scheme != scheme || !strings.EqualFold(u.Host, r.Host) || u.Path != "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
				http.Error(w, "Forbidden origin", 403)
				return
			}
		}
		sites := r.Header.Values("Sec-Fetch-Site")
		if len(sites) > 1 || (len(sites) == 1 && sites[0] != "same-origin" && sites[0] != "none") {
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
		granted = true
		report(true) // Report admission immediately, even for a long streaming response.
		next.ServeHTTP(w, r)
	})
}

type status struct {
	Type   string        `json:"type"`
	Value  string        `json:"value,omitempty"`
	Device *deviceStatus `json:"device,omitempty"`
}

var outputMu sync.Mutex

func emit(kind, value string) {
	outputMu.Lock()
	defer outputMu.Unlock()
	_ = json.NewEncoder(os.Stdout).Encode(status{Type: kind, Value: value})
}

func emitDevice(device deviceStatus) {
	outputMu.Lock()
	defer outputMu.Unlock()
	_ = json.NewEncoder(os.Stdout).Encode(status{Type: "device", Device: &device})
}

// Require a bounded, complete first line; the remaining stream is the parent
// lifetime pipe. Never log the capability or accept it from the environment.
func readLaunchSecret(reader *bufio.Reader) (string, error) {
	line, err := reader.ReadSlice('\n')
	if err != nil || len(line) < 33 || len(line) > 257 {
		return "", errors.New("invalid launch secret line")
	}
	secret := string(line[:len(line)-1])
	for _, c := range secret {
		if c < 33 || c > 126 {
			return "", errors.New("invalid launch secret line")
		}
	}
	return secret, nil
}

func lockStateDirectory(dir string) (*os.File, error) {
	file, err := os.Open(dir)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		file.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, errors.New("another Osaurus instance is using phone access")
		}
		return nil, err
	}
	return file, nil // Closing releases the lock; never unlink the locked inode.
}

func nodeName(dir string) (string, error) {
	path := filepath.Join(dir, "node-name")
	if data, err := os.ReadFile(path); err == nil {
		name := strings.TrimSpace(string(data))
		if len(name) == 14 && strings.HasPrefix(name, "osaurus-") {
			if _, err := hex.DecodeString(name[8:]); err == nil {
				return name, nil
			}
		}
		return "", errors.New("invalid persisted phone node name")
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	var random [3]byte
	if _, err := rand.Read(random[:]); err != nil {
		return "", err
	}
	name := "osaurus-" + hex.EncodeToString(random[:])
	// Called under the state-directory lock, before tsnet starts.
	if err := os.WriteFile(path, []byte(name+"\n"), 0600); err != nil {
		return "", err
	}
	return name, nil
}

func run() error {
	input := bufio.NewReaderSize(os.Stdin, 512)
	secret, err := readLaunchSecret(input)
	if err != nil {
		return err
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
	lock, err := lockStateDirectory(dir)
	if err != nil {
		return err
	}
	defer lock.Close()
	hostname, err := nodeName(dir)
	if err != nil {
		return err
	}
	// envknob.Setenv refreshes the cached RegisterBool in v1.94.2's portmapper.
	envknob.Setenv("TS_DISABLE_PORTMAPPER", "true")
	s := &tsnet.Server{Dir: dir, Hostname: hostname, Ephemeral: false, Logf: func(string, ...any) {}, UserLogf: func(string, ...any) {}}
	defer s.Close()
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	// Parent owns stdin. EOF ensures an app crash cannot leave a proxy behind.
	go func() { _, _ = io.Copy(io.Discard, input); cancel() }()
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
	lookup := func(ctx context.Context, addr string) (identity, error) {
		who, err := lc.WhoIs(ctx, addr)
		if err != nil {
			return identity{}, err
		}
		if who.Node == nil {
			return identity{}, errors.New("no node")
		}
		peer := identity{StableID: string(who.Node.StableID), Name: strings.TrimSuffix(who.Node.Name, ".")}
		if who.UserProfile != nil {
			peer.Login = who.UserProfile.LoginName
		}
		// A node without a login can still be displayed as denied, but cannot
		// match the login allowlist (including when explicitly device-selected).
		return peer, nil
	}
	devices := map[string]bool{}
	for _, id := range strings.Split(os.Getenv("OSAURUS_PHONE_DEVICES"), ",") {
		if id != "" {
			devices[id] = true
		}
	}
	policy := accessPolicy{hosts: acceptableHosts(st), restrictDevices: os.Getenv("OSAURUS_PHONE_RESTRICT_DEVICES") == "1", devices: devices, report: emitDevice}
	server := &http.Server{Handler: authorize(proxy, lookup, logins, secret, policy), ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 32 * 1024}
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
