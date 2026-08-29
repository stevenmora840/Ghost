// ghostd is Ghost's control-plane server: auth, device registration with
// WireGuard config issuance, and the server catalog. It is not in the VPN
// data path — tunnel traffic goes straight to the PoPs.
//
// Configuration (environment):
//
//	GHOST_ADDR             listen address (default :8080)
//	GHOST_DB               SQLite path (default ghost.db)
//	GHOST_JWT_SECRET       HMAC secret for access tokens (required in prod;
//	                       a random ephemeral one is generated if unset)
//	GHOST_APPLE_BUNDLE_ID  iOS bundle ID for Sign in with Apple verification
//	GHOST_SEED_DEV         "1" seeds a demo server catalog for local dev
package main

import (
	"context"
	"crypto/rand"
	"log/slog"
	"net/http"
	"os"
	"time"

	"github.com/stevenmora840/ghost/backend/internal/api"
	"github.com/stevenmora840/ghost/backend/internal/auth"
	"github.com/stevenmora840/ghost/backend/internal/store"
	"github.com/stevenmora840/ghost/backend/internal/wg"
)

func main() {
	log := slog.New(slog.NewTextHandler(os.Stderr, nil))

	addr := envOr("GHOST_ADDR", ":8080")
	dbPath := envOr("GHOST_DB", "ghost.db")
	bundleID := envOr("GHOST_APPLE_BUNDLE_ID", "com.ghostvpn.ios")

	secret := []byte(os.Getenv("GHOST_JWT_SECRET"))
	if len(secret) == 0 {
		secret = make([]byte, 32)
		if _, err := rand.Read(secret); err != nil {
			log.Error("generate jwt secret", "err", err)
			os.Exit(1)
		}
		log.Warn("GHOST_JWT_SECRET not set — using an ephemeral secret; tokens will not survive restarts")
	}

	st, err := store.Open(dbPath)
	if err != nil {
		log.Error("open store", "err", err)
		os.Exit(1)
	}
	defer st.Close()

	if os.Getenv("GHOST_SEED_DEV") == "1" {
		if err := seedDevServers(st); err != nil {
			log.Error("seed dev servers", "err", err)
			os.Exit(1)
		}
		log.Info("seeded development server catalog")
	}

	srv := &api.Server{
		Store:  st,
		Tokens: auth.NewTokens(secret),
		Apple:  auth.NewAppleVerifier(bundleID),
		Log:    log,
	}

	httpSrv := &http.Server{
		Addr:              addr,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Info("ghostd listening", "addr", addr)
	if err := httpSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Error("serve", "err", err)
		os.Exit(1)
	}
}

// seedDevServers fills the catalog with the launch-target locations from
// docs/vpn-infrastructure.md, generating throwaway keys. Idempotent per ID.
func seedDevServers(st *store.Store) error {
	seeds := []struct {
		id, city, country, code, endpoint string
		load                              int
	}{
		{"us-nyc-1", "New York", "United States", "US", "nyc1.dev.ghostvpn.example:51820", 23},
		{"uk-lon-1", "London", "United Kingdom", "GB", "lon1.dev.ghostvpn.example:51820", 31},
		{"de-fra-1", "Frankfurt", "Germany", "DE", "fra1.dev.ghostvpn.example:51820", 23},
		{"nl-ams-1", "Amsterdam", "Netherlands", "NL", "ams1.dev.ghostvpn.example:51820", 54},
		{"jp-tyo-1", "Tokyo", "Japan", "JP", "tyo1.dev.ghostvpn.example:51820", 40},
	}
	ctx := context.Background()
	existing, err := st.Servers(ctx)
	if err != nil {
		return err
	}
	have := map[string]bool{}
	for _, sv := range existing {
		have[sv.ID] = true
	}
	for _, s := range seeds {
		if have[s.id] {
			continue
		}
		_, pub, err := wg.GenerateKeypair()
		if err != nil {
			return err
		}
		if err := st.UpsertServer(ctx, store.Server{
			ID: s.id, City: s.city, Country: s.country, CountryCode: s.code,
			Endpoint: s.endpoint, PublicKey: pub, LoadPct: s.load, Audited: true,
		}); err != nil {
			return err
		}
	}
	return nil
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
