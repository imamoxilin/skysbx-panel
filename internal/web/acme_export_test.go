package web

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// stageCert writes a certificate pair into the layout certmagic uses, under an
// issuer directory whose name is deliberately not the real one: the export has
// to find the pair by listing, not by knowing where the CA puts things.
func stageCert(t *testing.T, dataDir, domain, cert, key string) {
	t.Helper()
	dir := filepath.Join(dataDir, "certs", "certificates",
		"some-ca-that-moved-v9.example-directory", domain)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, domain+".crt"), []byte(cert), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, domain+".key"), []byte(key), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestExportWritesThePairWhereTheNodeLooks(t *testing.T) {
	dir := t.TempDir()
	stageCert(t, dir, "panel.example.com", "CERT-ONE", "KEY-ONE")

	a, err := NewAutoTLS("panel.example.com", "", dir)
	if err != nil {
		t.Fatal(err)
	}
	certPath := filepath.Join(dir, "cert.pem")
	keyPath := filepath.Join(dir, "key.pem")
	if err := a.ExportTo(context.Background(), certPath, keyPath); err != nil {
		t.Fatalf("export: %v", err)
	}

	if got, _ := os.ReadFile(certPath); string(got) != "CERT-ONE" {
		t.Errorf("certificate = %q, want CERT-ONE", got)
	}
	if got, _ := os.ReadFile(keyPath); string(got) != "KEY-ONE" {
		t.Errorf("key = %q, want KEY-ONE", got)
	}
	// The key is a private key on a host the node also reads from, so it must
	// not end up more readable than certmagic stored it. Asserted only where
	// the mode means something: Windows does not map these bits, and a failure
	// there would be the filesystem's, not this code's.
	if runtime.GOOS != "windows" {
		info, err := os.Stat(keyPath)
		if err != nil {
			t.Fatal(err)
		}
		if perm := info.Mode().Perm(); perm != 0o600 {
			t.Errorf("key mode = %v, want 0600", perm)
		}
	}
}

// The export runs on a timer between renewals that are ninety days apart, and
// sing-box reloads its certificate whenever these files are touched. Rewriting
// identical bytes would make it reload hourly for nothing.
func TestExportDoesNotRewriteUnchangedFiles(t *testing.T) {
	dir := t.TempDir()
	stageCert(t, dir, "panel.example.com", "CERT-ONE", "KEY-ONE")

	a, err := NewAutoTLS("panel.example.com", "", dir)
	if err != nil {
		t.Fatal(err)
	}
	certPath := filepath.Join(dir, "cert.pem")
	keyPath := filepath.Join(dir, "key.pem")
	ctx := context.Background()
	if err := a.ExportTo(ctx, certPath, keyPath); err != nil {
		t.Fatal(err)
	}

	certInfo, err := os.Stat(certPath)
	if err != nil {
		t.Fatal(err)
	}
	keyInfo, err := os.Stat(keyPath)
	if err != nil {
		t.Fatal(err)
	}

	if err := a.ExportTo(ctx, certPath, keyPath); err != nil {
		t.Fatal(err)
	}

	after, err := os.Stat(certPath)
	if err != nil {
		t.Fatal(err)
	}
	if !after.ModTime().Equal(certInfo.ModTime()) {
		t.Error("certificate was rewritten though its content had not changed")
	}
	afterKey, err := os.Stat(keyPath)
	if err != nil {
		t.Fatal(err)
	}
	if !afterKey.ModTime().Equal(keyInfo.ModTime()) {
		t.Error("key was rewritten though its content had not changed")
	}
}

// A renewal is the whole reason the export runs on a timer.
func TestExportPicksUpARenewal(t *testing.T) {
	dir := t.TempDir()
	stageCert(t, dir, "panel.example.com", "CERT-ONE", "KEY-ONE")

	a, err := NewAutoTLS("panel.example.com", "", dir)
	if err != nil {
		t.Fatal(err)
	}
	certPath := filepath.Join(dir, "cert.pem")
	keyPath := filepath.Join(dir, "key.pem")
	ctx := context.Background()
	if err := a.ExportTo(ctx, certPath, keyPath); err != nil {
		t.Fatal(err)
	}

	stageCert(t, dir, "panel.example.com", "CERT-TWO", "KEY-TWO")
	if err := a.ExportTo(ctx, certPath, keyPath); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(certPath); string(got) != "CERT-TWO" {
		t.Errorf("certificate = %q, want CERT-TWO after renewal", got)
	}
	if got, _ := os.ReadFile(keyPath); string(got) != "KEY-TWO" {
		t.Errorf("key = %q, want KEY-TWO after renewal", got)
	}
}

// Exporting before the first certificate exists must not leave a truncated or
// empty cert.pem behind: sing-box would fail to build the inbound on it, and
// the error would point at the node rather than at the panel that has not
// finished its ACME order.
func TestExportBeforeThereIsACertificate(t *testing.T) {
	dir := t.TempDir()
	a, err := NewAutoTLS("panel.example.com", "", dir)
	if err != nil {
		t.Fatal(err)
	}
	certPath := filepath.Join(dir, "cert.pem")
	keyPath := filepath.Join(dir, "key.pem")
	if err := a.ExportTo(context.Background(), certPath, keyPath); err == nil {
		t.Fatal("expected an error when no certificate is stored yet")
	}
	for _, p := range []string{certPath, keyPath} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Errorf("%s was created despite there being nothing to export", p)
		}
	}
}
