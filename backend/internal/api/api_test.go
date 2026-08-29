package api

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/stevenmora840/ghost/backend/internal/auth"
	"github.com/stevenmora840/ghost/backend/internal/store"
	"github.com/stevenmora840/ghost/backend/internal/wg"
)

func newTestServer(t *testing.T) (*Server, *httptest.Server) {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })

	srv := &Server{
		Store:             st,
		Tokens:            auth.NewTokens([]byte("test-secret")),
		Apple:             auth.NewAppleVerifier("com.ghostvpn.ios"),
		Log:               slog.New(slog.DiscardHandler),
		AllowTierOverride: true, // tests exercise paid features without billing
	}
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return srv, ts
}

func postJSON(t *testing.T, url string, body any, token string) (*http.Response, map[string]any) {
	t.Helper()
	buf, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, url, bytes.NewReader(buf))
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	resp.Body.Close()
	return resp, out
}

func getJSON(t *testing.T, url, token string) (*http.Response, map[string]any) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, url, nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	resp.Body.Close()
	return resp, out
}

func TestRegisterLoginRefreshFlow(t *testing.T) {
	_, ts := newTestServer(t)

	// Register.
	resp, body := postJSON(t, ts.URL+"/v1/auth/register",
		map[string]string{"email": "user@example.com", "password": "correct-horse-battery"}, "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("register: got %d, body %v", resp.StatusCode, body)
	}
	if body["access_token"] == "" || body["refresh_token"] == "" {
		t.Fatalf("register: missing tokens in %v", body)
	}

	// Duplicate email is a conflict.
	resp, _ = postJSON(t, ts.URL+"/v1/auth/register",
		map[string]string{"email": "user@example.com", "password": "correct-horse-battery"}, "")
	if resp.StatusCode != http.StatusConflict {
		t.Fatalf("duplicate register: got %d, want 409", resp.StatusCode)
	}

	// Weak password rejected.
	resp, _ = postJSON(t, ts.URL+"/v1/auth/register",
		map[string]string{"email": "user2@example.com", "password": "short"}, "")
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("weak password: got %d, want 400", resp.StatusCode)
	}

	// Login with wrong password fails.
	resp, _ = postJSON(t, ts.URL+"/v1/auth/login",
		map[string]string{"email": "user@example.com", "password": "wrong-password-here"}, "")
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("bad login: got %d, want 401", resp.StatusCode)
	}

	// Login succeeds.
	resp, body = postJSON(t, ts.URL+"/v1/auth/login",
		map[string]string{"email": "user@example.com", "password": "correct-horse-battery"}, "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("login: got %d", resp.StatusCode)
	}
	refresh := body["refresh_token"].(string)

	// Refresh rotates: first use OK, reuse rejected.
	resp, body = postJSON(t, ts.URL+"/v1/auth/refresh", map[string]string{"refresh_token": refresh}, "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("refresh: got %d, body %v", resp.StatusCode, body)
	}
	resp, _ = postJSON(t, ts.URL+"/v1/auth/refresh", map[string]string{"refresh_token": refresh}, "")
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("refresh reuse: got %d, want 401", resp.StatusCode)
	}
}

func TestDevicesAndServers(t *testing.T) {
	srv, ts := newTestServer(t)

	// Seed one server.
	_, pub, err := wg.GenerateKeypair()
	if err != nil {
		t.Fatal(err)
	}
	if err := srv.Store.UpsertServer(t.Context(), store.Server{
		ID: "us-nyc-1", City: "New York", Country: "United States", CountryCode: "US",
		Endpoint: "nyc1.example:51820", PublicKey: pub, LoadPct: 23, Audited: true,
	}); err != nil {
		t.Fatal(err)
	}

	_, body := postJSON(t, ts.URL+"/v1/auth/register",
		map[string]string{"email": "dev@example.com", "password": "correct-horse-battery"}, "")
	token := body["access_token"].(string)

	// Unauthenticated request rejected.
	resp, _ := getJSON(t, ts.URL+"/v1/servers", "")
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauthed servers: got %d, want 401", resp.StatusCode)
	}

	// Server list includes what the client needs to build a tunnel config.
	resp, body = getJSON(t, ts.URL+"/v1/servers", token)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("servers: got %d", resp.StatusCode)
	}
	servers := body["servers"].([]any)
	if len(servers) != 1 {
		t.Fatalf("servers: got %d, want 1", len(servers))
	}
	sv := servers[0].(map[string]any)
	if sv["endpoint"] != "nyc1.example:51820" || sv["public_key"] != pub {
		t.Fatalf("server payload missing tunnel fields: %v", sv)
	}

	// Register a device with a valid WireGuard pubkey.
	_, devPub, _ := wg.GenerateKeypair()
	resp, body = postJSON(t, ts.URL+"/v1/devices",
		map[string]string{"name": "iPhone", "public_key": devPub}, token)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("create device: got %d, body %v", resp.StatusCode, body)
	}
	device := body["device"].(map[string]any)
	assignedIP := device["assigned_ip"].(string)
	if assignedIP == "" {
		t.Fatal("no assigned IP")
	}
	if dns := body["dns"].([]any); len(dns) == 0 {
		t.Fatal("no DNS in device response")
	}

	// Bad pubkey rejected.
	resp, _ = postJSON(t, ts.URL+"/v1/devices",
		map[string]string{"name": "bad", "public_key": "not-a-key"}, token)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("bad pubkey: got %d, want 400", resp.StatusCode)
	}

	// Device limit enforced at 10 total.
	for i := 0; i < store.MaxDevicesPerUser-1; i++ {
		_, p, _ := wg.GenerateKeypair()
		resp, _ = postJSON(t, ts.URL+"/v1/devices",
			map[string]string{"name": fmt.Sprintf("d%d", i), "public_key": p}, token)
		if resp.StatusCode != http.StatusCreated {
			t.Fatalf("device %d: got %d", i, resp.StatusCode)
		}
	}
	_, p, _ := wg.GenerateKeypair()
	resp, _ = postJSON(t, ts.URL+"/v1/devices", map[string]string{"name": "over", "public_key": p}, token)
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("over limit: got %d, want 403", resp.StatusCode)
	}

	// Delete one, then account reflects the count.
	req, _ := http.NewRequest(http.MethodDelete, ts.URL+"/v1/devices/"+device["id"].(string), nil)
	req.Header.Set("Authorization", "Bearer "+token)
	dresp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	dresp.Body.Close()
	if dresp.StatusCode != http.StatusNoContent {
		t.Fatalf("delete device: got %d", dresp.StatusCode)
	}
	_, body = getJSON(t, ts.URL+"/v1/account", token)
	if got := int(body["device_count"].(float64)); got != store.MaxDevicesPerUser-1 {
		t.Fatalf("device_count: got %d, want %d", got, store.MaxDevicesPerUser-1)
	}
}

// TestAppleSignIn signs an identity token with a local RSA key and injects a
// matching keyfunc, exercising the full claims-validation path without
// talking to Apple.
func TestAppleSignIn(t *testing.T) {
	srv, ts := newTestServer(t)

	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	srv.Apple.Keyfunc = func(tk *jwt.Token) (any, error) { return &key.PublicKey, nil }

	makeToken := func(claims jwt.MapClaims) string {
		tk := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
		tk.Header["kid"] = "test-kid"
		signed, err := tk.SignedString(key)
		if err != nil {
			t.Fatal(err)
		}
		return signed
	}

	valid := makeToken(jwt.MapClaims{
		"iss":   "https://appleid.apple.com",
		"aud":   "com.ghostvpn.ios",
		"sub":   "001234.abcdef",
		"exp":   time.Now().Add(time.Hour).Unix(),
		"iat":   time.Now().Unix(),
		"email": "relay@privaterelay.appleid.com",
	})
	resp, body := postJSON(t, ts.URL+"/v1/auth/apple", map[string]string{"identity_token": valid}, "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("apple sign-in: got %d, body %v", resp.StatusCode, body)
	}
	if body["access_token"] == "" {
		t.Fatal("apple sign-in: no access token")
	}

	// Second sign-in with the same subject reuses the account (no error).
	resp, _ = postJSON(t, ts.URL+"/v1/auth/apple", map[string]string{"identity_token": valid}, "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("apple re-sign-in: got %d", resp.StatusCode)
	}

	// Wrong audience rejected.
	badAud := makeToken(jwt.MapClaims{
		"iss": "https://appleid.apple.com",
		"aud": "com.other.app",
		"sub": "001234.abcdef",
		"exp": time.Now().Add(time.Hour).Unix(),
	})
	resp, _ = postJSON(t, ts.URL+"/v1/auth/apple", map[string]string{"identity_token": badAud}, "")
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("wrong aud: got %d, want 401", resp.StatusCode)
	}

	// Expired token rejected.
	expired := makeToken(jwt.MapClaims{
		"iss": "https://appleid.apple.com",
		"aud": "com.ghostvpn.ios",
		"sub": "001234.abcdef",
		"exp": time.Now().Add(-time.Hour).Unix(),
	})
	resp, _ = postJSON(t, ts.URL+"/v1/auth/apple", map[string]string{"identity_token": expired}, "")
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expired: got %d, want 401", resp.StatusCode)
	}
}

func TestWireGuardKeyValidation(t *testing.T) {
	priv, pub, err := wg.GenerateKeypair()
	if err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{priv, pub} {
		if err := wg.ValidatePublicKey(k); err != nil {
			t.Errorf("ValidatePublicKey(%q): %v", k, err)
		}
	}
	short := base64.StdEncoding.EncodeToString([]byte("too short"))
	if err := wg.ValidatePublicKey(short); err == nil {
		t.Error("short key accepted")
	}
	if err := wg.ValidatePublicKey("!!!"); err == nil {
		t.Error("non-base64 key accepted")
	}
}
