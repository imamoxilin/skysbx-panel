package web

import (
	"bytes"
	"context"
	"crypto/tls"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/caddyserver/certmagic"
)

// AutoTLS obtains and renews the panel's certificate over ACME.
//
// Doing this in-process is what lets the panel be one binary. A reverse proxy
// in front would mean a second package to install, a second config file to keep
// in step, and a second place for a redirect or a header to go wrong — for a
// single hostname that terminates its own TLS anyway.
//
// The three parts have to share one certmagic Config: the HTTP-01 challenge
// state is written to the Config's storage when the challenge starts and read
// back out when the ACME server comes knocking on port 80. A handler built from
// a second, unrelated issuer answers 404 to every challenge it is given.
type AutoTLS struct {
	domain string
	cfg    *certmagic.Config
	issuer *certmagic.ACMEIssuer
}

// NewAutoTLS prepares ACME for domain but does not talk to the CA yet — call
// Obtain for that, after the challenge handler is already listening.
func NewAutoTLS(domain, email, dataDir string) (*AutoTLS, error) {
	if domain == "" {
		return nil, fmt.Errorf("a domain is required for automatic TLS")
	}

	var cfg *certmagic.Config
	cache := certmagic.NewCache(certmagic.CacheOptions{
		GetConfigForCert: func(certmagic.Certificate) (*certmagic.Config, error) {
			return cfg, nil
		},
	})
	cfg = certmagic.New(cache, certmagic.Config{
		// Certificates live beside the database so one directory is the whole
		// of the panel's state, and backing it up means copying one path.
		Storage: &certmagic.FileStorage{Path: filepath.Join(dataDir, "certs")},
	})

	issuer := certmagic.NewACMEIssuer(cfg, certmagic.ACMEIssuer{
		CA:     certmagic.LetsEncryptProductionCA,
		Email:  email,
		Agreed: email != "",
		// DNS-01 would avoid needing port 80, but it needs provider credentials
		// the panel has no reason to hold. HTTP-01 keeps the deployment to one
		// binary and one open port pair.
		DisableHTTPChallenge: false,
	})
	cfg.Issuers = []certmagic.Issuer{issuer}

	return &AutoTLS{domain: domain, cfg: cfg, issuer: issuer}, nil
}

// ChallengeAndRedirect is the port 80 handler: it answers the ACME HTTP-01
// challenge and sends everything else to HTTPS.
//
// The challenge has to come first. Answering it with a redirect is the classic
// way to make renewal fail three months after anyone last looked.
//
// It must be serving before Obtain is called. certmagic's own solver would
// otherwise try to bind port 80 itself, and whichever of the two loses the race
// is the one that fails.
func (a *AutoTLS) ChallengeAndRedirect() http.Handler {
	return a.issuer.HTTPChallengeHandler(http.HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) {
			target := "https://" + a.domain + r.URL.RequestURI()
			http.Redirect(w, r, target, http.StatusMovedPermanently)
		}))
}

// Obtain gets the certificate, blocking until it has one or ctx expires.
//
// A returned error is not fatal: renewal has been handed to certmagic's
// background maintenance, which retries with its own backoff. Exiting instead
// would put the process in a restart loop against a CA that rate-limits
// failures, and burning the hour's budget is a worse state to be in than being
// down while someone reads the log.
func (a *AutoTLS) Obtain(ctx context.Context) error {
	if err := a.cfg.ManageSync(ctx, []string{a.domain}); err != nil {
		if aerr := a.cfg.ManageAsync(context.WithoutCancel(ctx), []string{a.domain}); aerr != nil {
			return fmt.Errorf("obtain certificate for %s: %w", a.domain, err)
		}
		return fmt.Errorf("obtain certificate for %s (retrying in the background): %w",
			a.domain, err)
	}
	return nil
}

// TLSConfig is what to serve HTTPS with. Valid before Obtain succeeds, but
// handshakes fail until a certificate is in the cache.
func (a *AutoTLS) TLSConfig() *tls.Config {
	cfg := a.cfg.TLSConfig()
	cfg.NextProtos = append([]string{"h2", "http/1.1"}, cfg.NextProtos...)
	return cfg
}

// ExportTo copies the managed certificate and its key to two fixed paths.
//
// This exists for the one-host case: AnyTLS is the only protocol that needs a
// certificate, and on a machine where the panel already holds port 80 there is
// no way for the node to run certbot's standalone challenge and get its own.
// The panel's certificate is for the same name the node is reached on, so it is
// the right certificate — it is only in the wrong place.
//
// The wrong place is not a stable one either: certmagic's layout puts the
// issuer's directory in the path, and that changes if the CA does (a fallback
// to a staging endpoint is enough). So rather than teach the node that layout,
// the panel writes the pair where the node already looks by default.
//
// sing-box watches both files and reloads them, so renewal is handled by
// rewriting them here — no restart, no config push. Writing the key first and
// the certificate second is deliberate: the watcher fires per file and pairs
// whatever it has, so the last write should be the one that completes a
// matching pair. Either order logs one "reload key pair" error in between; this
// order makes that the only cost.
func (a *AutoTLS) ExportTo(ctx context.Context, certPath, keyPath string) error {
	certPEM, keyPEM, err := a.currentPEM(ctx)
	if err != nil {
		return err
	}
	if err := writeIfChanged(keyPath, keyPEM, 0o600); err != nil {
		return err
	}
	return writeIfChanged(certPath, certPEM, 0o644)
}

// currentPEM digs the PEM pair out of certmagic's storage.
//
// It lists rather than building the key from a known issuer, because the issuer
// segment is exactly the part that is not ours to predict.
func (a *AutoTLS) currentPEM(ctx context.Context) (cert, key []byte, err error) {
	keys, err := a.cfg.Storage.List(ctx, "certificates", true)
	if err != nil {
		return nil, nil, fmt.Errorf("list certificate storage: %w", err)
	}
	certKey, keyKey := "", ""
	for _, k := range keys {
		// FileStorage hands back whatever separator the host filesystem uses,
		// so matching on "/" alone finds nothing on Windows. The key is still
		// passed to Load unchanged — only the comparison is normalised.
		norm := strings.ReplaceAll(k, `\`, "/")
		switch {
		case strings.HasSuffix(norm, "/"+a.domain+".crt"):
			certKey = k
		case strings.HasSuffix(norm, "/"+a.domain+".key"):
			keyKey = k
		}
	}
	if certKey == "" || keyKey == "" {
		return nil, nil, fmt.Errorf("no stored certificate for %s yet", a.domain)
	}
	if cert, err = a.cfg.Storage.Load(ctx, certKey); err != nil {
		return nil, nil, fmt.Errorf("read %s: %w", certKey, err)
	}
	if key, err = a.cfg.Storage.Load(ctx, keyKey); err != nil {
		return nil, nil, fmt.Errorf("read %s: %w", keyKey, err)
	}
	return cert, key, nil
}

// writeIfChanged avoids touching a file whose content already matches, so the
// watcher on the other side is not woken for nothing — an export that ran on a
// timer would otherwise make sing-box reload its certificate every hour for the
// ninety days between renewals.
//
// The write goes through a temporary file and a rename so a reader never sees a
// half-written certificate: rename is atomic, and the watcher fires once.
func writeIfChanged(path string, want []byte, mode os.FileMode) error {
	if have, err := os.ReadFile(path); err == nil && bytes.Equal(have, want) {
		return nil
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, want, mode); err != nil {
		return fmt.Errorf("write %s: %w", tmp, err)
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("rename onto %s: %w", path, err)
	}
	return nil
}
