package api

import (
	"errors"
	"net/http"

	"github.com/stevenmora840/ghost/backend/internal/store"
	"github.com/stevenmora840/ghost/backend/internal/wg"
)

// requirePaid wraps a handler so only paid accounts reach it, passing the
// loaded user through to save a second lookup.
func (s *Server) requirePaid(next func(http.ResponseWriter, *http.Request, *store.User)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		u, err := s.Store.UserByID(r.Context(), userID(r))
		if err != nil {
			writeErr(w, http.StatusUnauthorized, "account not found")
			return
		}
		if !u.Tier.IsPaid() {
			writeJSON(w, http.StatusPaymentRequired, map[string]string{
				"error":         "This feature is part of Ghost Plus.",
				"required_tier": string(store.TierPaid),
			})
			return
		}
		next(w, r, u)
	}
}

// --- DNS threat & ad blocking (free tier) ---

type dnsFilterJSON struct {
	BlockAds      bool     `json:"block_ads"`
	BlockMalware  bool     `json:"block_malware"`
	BlockTrackers bool     `json:"block_trackers"`
	Resolvers     []string `json:"resolvers"`
}

func dnsFilterResponse(f store.DNSFilter) dnsFilterJSON {
	return dnsFilterJSON{
		BlockAds:      f.BlockAds,
		BlockMalware:  f.BlockMalware,
		BlockTrackers: f.BlockTrackers,
		Resolvers:     wg.ResolverFor(f.BlockAds, f.BlockMalware, f.BlockTrackers),
	}
}

func (s *Server) handleGetDNSFilter(w http.ResponseWriter, r *http.Request) {
	u, err := s.Store.UserByID(r.Context(), userID(r))
	if err != nil {
		writeErr(w, http.StatusUnauthorized, "account not found")
		return
	}
	writeJSON(w, http.StatusOK, dnsFilterResponse(u.DNSFilter))
}

func (s *Server) handleSetDNSFilter(w http.ResponseWriter, r *http.Request) {
	var req struct {
		BlockAds      bool `json:"block_ads"`
		BlockMalware  bool `json:"block_malware"`
		BlockTrackers bool `json:"block_trackers"`
	}
	if err := decode(r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid request body")
		return
	}
	f := store.DNSFilter{
		BlockAds:      req.BlockAds,
		BlockMalware:  req.BlockMalware,
		BlockTrackers: req.BlockTrackers,
	}
	if err := s.Store.SetDNSFilter(r.Context(), userID(r), f); err != nil {
		s.Log.Error("set dns filter", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error")
		return
	}
	// Resolvers change on the next tunnel bring-up; the client re-reads its
	// device config to pick them up.
	writeJSON(w, http.StatusOK, dnsFilterResponse(f))
}

// --- dedicated static IP (free tier) ---

type dedicatedIPJSON struct {
	IP       string `json:"ip"`
	ServerID string `json:"server_id"`
}

func (s *Server) handleGetDedicatedIP(w http.ResponseWriter, r *http.Request) {
	d, err := s.Store.DedicatedIPForUser(r.Context(), userID(r))
	if errors.Is(err, store.ErrNotFound) {
		writeJSON(w, http.StatusOK, map[string]any{"dedicated_ip": nil})
		return
	}
	if err != nil {
		s.Log.Error("get dedicated ip", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"dedicated_ip": dedicatedIPJSON{IP: d.IP, ServerID: d.ServerID},
	})
}

func (s *Server) handleAllocateDedicatedIP(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ServerID string `json:"server_id"`
	}
	if err := decode(r, &req); err != nil || req.ServerID == "" {
		writeErr(w, http.StatusBadRequest, "server_id is required")
		return
	}

	server, err := s.Store.ServerByID(r.Context(), req.ServerID)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "unknown server")
		return
	}
	if err != nil {
		s.Log.Error("lookup server", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error")
		return
	}

	u, err := s.Store.UserByID(r.Context(), userID(r))
	if err != nil {
		writeErr(w, http.StatusUnauthorized, "account not found")
		return
	}
	// The dedicated IP itself is free, but priority locations stay paid-only.
	if server.Priority && !u.Tier.IsPaid() {
		writeJSON(w, http.StatusPaymentRequired, map[string]string{
			"error":         "Priority locations are part of Ghost Plus. Pick another location for your dedicated IP.",
			"required_tier": string(store.TierPaid),
		})
		return
	}

	d, err := s.Store.AllocateDedicatedIP(r.Context(), u.ID, req.ServerID)
	if errors.Is(err, store.ErrIPPoolDrained) {
		writeErr(w, http.StatusConflict, "no dedicated addresses left in that location — try another")
		return
	}
	if err != nil {
		s.Log.Error("allocate dedicated ip", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"dedicated_ip": dedicatedIPJSON{IP: d.IP, ServerID: d.ServerID},
	})
}

func (s *Server) handleReleaseDedicatedIP(w http.ResponseWriter, r *http.Request) {
	err := s.Store.ReleaseDedicatedIP(r.Context(), userID(r))
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "no dedicated IP to release")
		return
	}
	if err != nil {
		s.Log.Error("release dedicated ip", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// --- custom multi-hop chain (paid tier) ---

func (s *Server) handleGetMultiHop(w http.ResponseWriter, r *http.Request, u *store.User) {
	chain, err := s.Store.MultiHopChain(r.Context(), u.ID)
	if err != nil {
		s.Log.Error("get multihop chain", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"chain":    chain,
		"min_hops": store.MinChainHops,
		"max_hops": store.MaxChainHops,
	})
}

func (s *Server) handleSetMultiHop(w http.ResponseWriter, r *http.Request, u *store.User) {
	var req struct {
		Chain []string `json:"chain"`
	}
	if err := decode(r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid request body")
		return
	}
	err := s.Store.SetMultiHopChain(r.Context(), u.ID, req.Chain)
	if errors.Is(err, store.ErrInvalidChain) {
		writeErr(w, http.StatusBadRequest,
			"a chain needs 2–3 distinct, existing servers")
		return
	}
	if err != nil {
		s.Log.Error("set multihop chain", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"chain": req.Chain})
}

func (s *Server) handleClearMultiHop(w http.ResponseWriter, r *http.Request, u *store.User) {
	if err := s.Store.ClearMultiHopChain(r.Context(), u.ID); err != nil {
		s.Log.Error("clear multihop chain", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// --- panic wipe (paid tier) ---

// handlePanicWipe revokes the account's entire current identity in one call:
// every device and tunnel address, every refresh token (so other sessions
// die), the dedicated IP, and the multi-hop chain. The caller's access token
// stays valid for its remaining minutes so the app can immediately
// re-register a freshly generated key — that is what makes it a new identity
// rather than a sign-out.
func (s *Server) handlePanicWipe(w http.ResponseWriter, r *http.Request, u *store.User) {
	if err := s.Store.PanicWipe(r.Context(), u.ID); err != nil {
		s.Log.Error("panic wipe", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"wiped": true})
}

// --- tier (development seam for billing) ---

// handleSetTier flips an account's tier. Billing is not built yet, so this
// exists only when GHOST_ALLOW_TIER_OVERRIDE=1; in production a payment
// webhook calls store.SetTier instead.
func (s *Server) handleSetTier(w http.ResponseWriter, r *http.Request) {
	if !s.AllowTierOverride {
		writeErr(w, http.StatusNotFound, "not found")
		return
	}
	var req struct {
		Tier string `json:"tier"`
	}
	if err := decode(r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid request body")
		return
	}
	tier := store.Tier(req.Tier)
	if tier != store.TierFree && tier != store.TierPaid {
		writeErr(w, http.StatusBadRequest, `tier must be "free" or "paid"`)
		return
	}
	if err := s.Store.SetTier(r.Context(), userID(r), tier); err != nil {
		s.Log.Error("set tier", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"tier": string(tier)})
}
