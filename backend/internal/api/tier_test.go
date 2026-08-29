package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"

	"github.com/stevenmora840/ghost/backend/internal/store"
	"github.com/stevenmora840/ghost/backend/internal/wg"
)

// sendJSON issues an arbitrary-method JSON request.
func sendJSON(t *testing.T, method, url string, body any, token string) (*http.Response, map[string]any) {
	t.Helper()
	var reader *bytes.Reader
	if body != nil {
		buf, _ := json.Marshal(body)
		reader = bytes.NewReader(buf)
	} else {
		reader = bytes.NewReader(nil)
	}
	req, _ := http.NewRequest(method, url, reader)
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

// seedServers puts one standard and one priority server in the catalog,
// each with a two-address dedicated pool.
func seedServers(t *testing.T, srv *Server) {
	t.Helper()
	for _, s := range []struct {
		id       string
		priority bool
	}{{"us-nyc-1", false}, {"de-fra-1", false}, {"us-nyc-p1", true}} {
		_, pub, err := wg.GenerateKeypair()
		if err != nil {
			t.Fatal(err)
		}
		if err := srv.Store.UpsertServer(t.Context(), store.Server{
			ID: s.id, City: "City", Country: "Country", CountryCode: "US",
			Endpoint: s.id + ".example:51820", PublicKey: pub,
			LoadPct: 10, Audited: true, Priority: s.priority,
		}); err != nil {
			t.Fatal(err)
		}
		for _, ip := range []string{"198.51.100." + s.id[:1], "198.51.101." + s.id[:1]} {
			if err := srv.Store.AddDedicatedIPToPool(t.Context(), ip+s.id, s.id); err != nil {
				t.Fatal(err)
			}
		}
	}
}

// signUp registers a fresh account and returns its access token.
func signUp(t *testing.T, ts string, email string) string {
	t.Helper()
	_, body := postJSON(t, ts+"/v1/auth/register",
		map[string]string{"email": email, "password": "correct-horse-battery"}, "")
	token, _ := body["access_token"].(string)
	if token == "" {
		t.Fatalf("register %s: no access token in %v", email, body)
	}
	return token
}

// upgrade flips an account to the paid tier via the development override.
func upgrade(t *testing.T, ts, token string) {
	t.Helper()
	resp, body := postJSON(t, ts+"/v1/account/tier", map[string]string{"tier": "paid"}, token)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("upgrade: got %d, body %v", resp.StatusCode, body)
	}
}

func TestDNSFilterPreferences(t *testing.T) {
	srv, ts := newTestServer(t)
	seedServers(t, srv)
	token := signUp(t, ts.URL, "dns@example.com")

	// Defaults to no filtering.
	resp, body := getJSON(t, ts.URL+"/v1/dns-filter", token)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("get dns filter: got %d", resp.StatusCode)
	}
	if body["block_ads"] != false || body["block_malware"] != false {
		t.Fatalf("expected filtering off by default, got %v", body)
	}
	if r := body["resolvers"].([]any); r[0] != wg.ResolverPlain {
		t.Fatalf("default resolver: got %v, want %s", r[0], wg.ResolverPlain)
	}

	// Enabling ads + trackers selects the everything resolver.
	resp, body = sendJSON(t, http.MethodPut, ts.URL+"/v1/dns-filter", map[string]bool{
		"block_ads": true, "block_malware": true, "block_trackers": true,
	}, token)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("set dns filter: got %d, body %v", resp.StatusCode, body)
	}
	if r := body["resolvers"].([]any); r[0] != wg.ResolverEverything {
		t.Fatalf("resolver: got %v, want %s", r[0], wg.ResolverEverything)
	}

	// The preference persists and reaches new device configs.
	_, devPub, _ := wg.GenerateKeypair()
	_, body = postJSON(t, ts.URL+"/v1/devices",
		map[string]string{"name": "phone", "public_key": devPub}, token)
	if dns := body["dns"].([]any); dns[0] != wg.ResolverEverything {
		t.Fatalf("device DNS: got %v, want filtered resolver %s", dns[0], wg.ResolverEverything)
	}

	// Free tier gets DNS filtering: no upgrade was needed to reach here.
	_, body = getJSON(t, ts.URL+"/v1/account", token)
	if body["tier"] != string(store.TierFree) {
		t.Fatalf("expected account to still be free tier, got %v", body["tier"])
	}
}

func TestDNSResolverMapping(t *testing.T) {
	cases := []struct {
		ads, malware, trackers bool
		want                   string
	}{
		{false, false, false, wg.ResolverPlain},
		{false, true, false, wg.ResolverMalware},
		{true, true, false, wg.ResolverAds},
		{false, true, true, wg.ResolverTrackers},
		{true, true, true, wg.ResolverEverything},
	}
	for _, c := range cases {
		got := wg.ResolverFor(c.ads, c.malware, c.trackers)
		if len(got) != 1 || got[0] != c.want {
			t.Errorf("ResolverFor(%v,%v,%v) = %v, want [%s]", c.ads, c.malware, c.trackers, got, c.want)
		}
	}
}

func TestDedicatedIPLifecycle(t *testing.T) {
	srv, ts := newTestServer(t)
	seedServers(t, srv)
	token := signUp(t, ts.URL, "dedicated@example.com")

	// None allocated initially.
	resp, body := getJSON(t, ts.URL+"/v1/dedicated-ip", token)
	if resp.StatusCode != http.StatusOK || body["dedicated_ip"] != nil {
		t.Fatalf("expected no dedicated IP, got %d %v", resp.StatusCode, body)
	}

	// Free tier can allocate on a standard server.
	resp, body = postJSON(t, ts.URL+"/v1/dedicated-ip", map[string]string{"server_id": "us-nyc-1"}, token)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("allocate: got %d, body %v", resp.StatusCode, body)
	}
	alloc := body["dedicated_ip"].(map[string]any)
	ip := alloc["ip"].(string)
	if ip == "" || alloc["server_id"] != "us-nyc-1" {
		t.Fatalf("bad allocation: %v", alloc)
	}

	// Allocation is stable and appears on the account.
	_, body = getJSON(t, ts.URL+"/v1/dedicated-ip", token)
	if body["dedicated_ip"].(map[string]any)["ip"] != ip {
		t.Fatalf("allocation not stable: %v", body)
	}
	_, body = getJSON(t, ts.URL+"/v1/account", token)
	if body["dedicated_ip"].(map[string]any)["ip"] != ip {
		t.Fatalf("account missing dedicated IP: %v", body)
	}

	// A second account gets a different address.
	other := signUp(t, ts.URL, "dedicated2@example.com")
	_, body = postJSON(t, ts.URL+"/v1/dedicated-ip", map[string]string{"server_id": "us-nyc-1"}, other)
	if got := body["dedicated_ip"].(map[string]any)["ip"].(string); got == ip {
		t.Fatalf("two accounts share address %s", got)
	}

	// Pool exhaustion is reported, not silently reused (2 addresses seeded).
	third := signUp(t, ts.URL, "dedicated3@example.com")
	resp, _ = postJSON(t, ts.URL+"/v1/dedicated-ip", map[string]string{"server_id": "us-nyc-1"}, third)
	if resp.StatusCode != http.StatusConflict {
		t.Fatalf("pool exhaustion: got %d, want 409", resp.StatusCode)
	}

	// Releasing returns the address to the pool for the next caller.
	resp, _ = sendJSON(t, http.MethodDelete, ts.URL+"/v1/dedicated-ip", nil, token)
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("release: got %d, want 204", resp.StatusCode)
	}
	resp, body = postJSON(t, ts.URL+"/v1/dedicated-ip", map[string]string{"server_id": "us-nyc-1"}, third)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("realloc after release: got %d, body %v", resp.StatusCode, body)
	}

	// Priority locations stay paid-only even though dedicated IPs are free.
	fourth := signUp(t, ts.URL, "dedicated4@example.com")
	resp, _ = postJSON(t, ts.URL+"/v1/dedicated-ip", map[string]string{"server_id": "us-nyc-p1"}, fourth)
	if resp.StatusCode != http.StatusPaymentRequired {
		t.Fatalf("priority location for free user: got %d, want 402", resp.StatusCode)
	}
	upgrade(t, ts.URL, fourth)
	resp, _ = postJSON(t, ts.URL+"/v1/dedicated-ip", map[string]string{"server_id": "us-nyc-p1"}, fourth)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("priority location for paid user: got %d, want 200", resp.StatusCode)
	}
}

func TestPriorityServerPoolGating(t *testing.T) {
	srv, ts := newTestServer(t)
	seedServers(t, srv)
	token := signUp(t, ts.URL, "priority@example.com")

	// Free tier sees priority servers but cannot build a tunnel config from
	// them: endpoint and key are withheld.
	_, body := getJSON(t, ts.URL+"/v1/servers", token)
	servers := body["servers"].([]any)
	var sawLocked bool
	for _, raw := range servers {
		sv := raw.(map[string]any)
		if sv["id"] != "us-nyc-p1" {
			if sv["locked"] == true {
				t.Fatalf("standard server marked locked: %v", sv)
			}
			if sv["endpoint"] == "" {
				t.Fatalf("standard server withheld endpoint: %v", sv)
			}
			continue
		}
		sawLocked = true
		if sv["priority"] != true || sv["locked"] != true {
			t.Fatalf("priority server not locked for free user: %v", sv)
		}
		if sv["endpoint"] != "" || sv["public_key"] != "" {
			t.Fatalf("locked server leaked tunnel credentials: %v", sv)
		}
	}
	if !sawLocked {
		t.Fatal("priority server missing from listing")
	}

	// Upgrading unlocks it, credentials included.
	upgrade(t, ts.URL, token)
	_, body = getJSON(t, ts.URL+"/v1/servers", token)
	for _, raw := range body["servers"].([]any) {
		sv := raw.(map[string]any)
		if sv["id"] != "us-nyc-p1" {
			continue
		}
		if sv["locked"] != false {
			t.Fatalf("priority server still locked after upgrade: %v", sv)
		}
		if sv["endpoint"] == "" || sv["public_key"] == "" {
			t.Fatalf("unlocked server missing tunnel credentials: %v", sv)
		}
	}
}

func TestMultiHopChainIsPaidAndValidated(t *testing.T) {
	srv, ts := newTestServer(t)
	seedServers(t, srv)
	token := signUp(t, ts.URL, "multihop@example.com")

	// Free tier is refused with a payment-required signal the client can act on.
	resp, body := getJSON(t, ts.URL+"/v1/multihop", token)
	if resp.StatusCode != http.StatusPaymentRequired {
		t.Fatalf("free multihop read: got %d, want 402", resp.StatusCode)
	}
	if body["required_tier"] != string(store.TierPaid) {
		t.Fatalf("missing required_tier hint: %v", body)
	}
	resp, _ = sendJSON(t, http.MethodPut, ts.URL+"/v1/multihop",
		map[string]any{"chain": []string{"us-nyc-1", "de-fra-1"}}, token)
	if resp.StatusCode != http.StatusPaymentRequired {
		t.Fatalf("free multihop write: got %d, want 402", resp.StatusCode)
	}

	upgrade(t, ts.URL, token)

	// Empty until set.
	resp, body = getJSON(t, ts.URL+"/v1/multihop", token)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("paid multihop read: got %d", resp.StatusCode)
	}
	if body["chain"] != nil {
		t.Fatalf("expected no chain initially, got %v", body["chain"])
	}

	// A valid two-hop chain round-trips in order.
	resp, body = sendJSON(t, http.MethodPut, ts.URL+"/v1/multihop",
		map[string]any{"chain": []string{"de-fra-1", "us-nyc-1"}}, token)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("set chain: got %d, body %v", resp.StatusCode, body)
	}
	_, body = getJSON(t, ts.URL+"/v1/multihop", token)
	chain := body["chain"].([]any)
	if len(chain) != 2 || chain[0] != "de-fra-1" || chain[1] != "us-nyc-1" {
		t.Fatalf("chain order not preserved: %v", chain)
	}

	// Rejections: too short, duplicated hop, unknown server, too long.
	for name, bad := range map[string][]string{
		"one hop":   {"us-nyc-1"},
		"duplicate": {"us-nyc-1", "us-nyc-1"},
		"unknown":   {"us-nyc-1", "nowhere-9"},
		"four hops": {"us-nyc-1", "de-fra-1", "us-nyc-p1", "us-nyc-1"},
	} {
		resp, _ = sendJSON(t, http.MethodPut, ts.URL+"/v1/multihop", map[string]any{"chain": bad}, token)
		if resp.StatusCode != http.StatusBadRequest {
			t.Errorf("%s chain: got %d, want 400", name, resp.StatusCode)
		}
	}

	// The valid chain survived the rejected writes.
	_, body = getJSON(t, ts.URL+"/v1/multihop", token)
	if len(body["chain"].([]any)) != 2 {
		t.Fatalf("chain clobbered by invalid write: %v", body["chain"])
	}

	// Clearing works.
	resp, _ = sendJSON(t, http.MethodDelete, ts.URL+"/v1/multihop", nil, token)
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("clear chain: got %d, want 204", resp.StatusCode)
	}
	_, body = getJSON(t, ts.URL+"/v1/multihop", token)
	if body["chain"] != nil {
		t.Fatalf("chain not cleared: %v", body["chain"])
	}
}

func TestPanicWipe(t *testing.T) {
	srv, ts := newTestServer(t)
	seedServers(t, srv)

	// Free tier can't panic wipe.
	free := signUp(t, ts.URL, "panicfree@example.com")
	resp, _ := postJSON(t, ts.URL+"/v1/account/panic-wipe", map[string]string{}, free)
	if resp.StatusCode != http.StatusPaymentRequired {
		t.Fatalf("free panic wipe: got %d, want 402", resp.StatusCode)
	}

	// Build a full identity on a paid account.
	_, tokens := postJSON(t, ts.URL+"/v1/auth/register",
		map[string]string{"email": "panic@example.com", "password": "correct-horse-battery"}, "")
	token := tokens["access_token"].(string)
	refresh := tokens["refresh_token"].(string)
	upgrade(t, ts.URL, token)

	_, devPub, _ := wg.GenerateKeypair()
	_, body := postJSON(t, ts.URL+"/v1/devices",
		map[string]string{"name": "phone", "public_key": devPub}, token)
	oldIP := body["device"].(map[string]any)["assigned_ip"].(string)

	postJSON(t, ts.URL+"/v1/dedicated-ip", map[string]string{"server_id": "us-nyc-1"}, token)
	sendJSON(t, http.MethodPut, ts.URL+"/v1/multihop",
		map[string]any{"chain": []string{"us-nyc-1", "de-fra-1"}}, token)

	// Wipe.
	resp, body = postJSON(t, ts.URL+"/v1/account/panic-wipe", map[string]string{}, token)
	if resp.StatusCode != http.StatusOK || body["wiped"] != true {
		t.Fatalf("panic wipe: got %d, body %v", resp.StatusCode, body)
	}

	// Devices, dedicated IP and chain are all gone.
	_, body = getJSON(t, ts.URL+"/v1/devices", token)
	if devices := body["devices"].([]any); len(devices) != 0 {
		t.Fatalf("devices survived wipe: %v", devices)
	}
	_, body = getJSON(t, ts.URL+"/v1/dedicated-ip", token)
	if body["dedicated_ip"] != nil {
		t.Fatalf("dedicated IP survived wipe: %v", body)
	}
	_, body = getJSON(t, ts.URL+"/v1/multihop", token)
	if body["chain"] != nil {
		t.Fatalf("chain survived wipe: %v", body["chain"])
	}

	// Other sessions are dead: the old refresh token no longer works.
	resp, _ = postJSON(t, ts.URL+"/v1/auth/refresh", map[string]string{"refresh_token": refresh}, "")
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("refresh token survived wipe: got %d, want 401", resp.StatusCode)
	}

	// The account survives and re-provisions to a *different* tunnel address —
	// that is what makes this a new identity rather than a sign-out.
	_, newPub, _ := wg.GenerateKeypair()
	resp, body = postJSON(t, ts.URL+"/v1/devices",
		map[string]string{"name": "phone", "public_key": newPub}, token)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("re-register after wipe: got %d, body %v", resp.StatusCode, body)
	}
	if newIP := body["device"].(map[string]any)["assigned_ip"].(string); newIP == oldIP {
		t.Fatalf("re-provisioned the same tunnel address %s — identity not rotated", newIP)
	}
}

func TestTierOverrideDisabledByDefault(t *testing.T) {
	// newTestServer enables the override; a production-shaped server must not
	// expose it.
	srv, ts := newTestServer(t)
	srv.AllowTierOverride = false
	seedServers(t, srv)
	token := signUp(t, ts.URL, "notier@example.com")

	resp, _ := postJSON(t, ts.URL+"/v1/account/tier", map[string]string{"tier": "paid"}, token)
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("tier override without opt-in: got %d, want 404", resp.StatusCode)
	}
	_, body := getJSON(t, ts.URL+"/v1/account", token)
	if body["tier"] != string(store.TierFree) {
		t.Fatalf("tier changed despite override being off: %v", body["tier"])
	}
}
