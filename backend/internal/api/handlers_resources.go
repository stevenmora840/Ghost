package api

import (
	"errors"
	"net/http"

	"github.com/stevenmora840/ghost/backend/internal/store"
	"github.com/stevenmora840/ghost/backend/internal/wg"
)

// --- servers ---

type serverJSON struct {
	ID          string `json:"id"`
	City        string `json:"city"`
	Country     string `json:"country"`
	CountryCode string `json:"country_code"`
	Endpoint    string `json:"endpoint"`
	PublicKey   string `json:"public_key"`
	LoadPct     int    `json:"load_pct"`
	Audited     bool   `json:"audited"`
}

func (s *Server) handleListServers(w http.ResponseWriter, r *http.Request) {
	servers, err := s.Store.Servers(r.Context())
	if err != nil {
		s.Log.Error("list servers", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error")
		return
	}
	out := make([]serverJSON, 0, len(servers))
	for _, sv := range servers {
		out = append(out, serverJSON{
			ID: sv.ID, City: sv.City, Country: sv.Country,
			CountryCode: sv.CountryCode, Endpoint: sv.Endpoint, PublicKey: sv.PublicKey,
			LoadPct: sv.LoadPct, Audited: sv.Audited,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"servers": out})
}

// --- account ---

func (s *Server) handleAccount(w http.ResponseWriter, r *http.Request) {
	u, err := s.Store.UserByID(r.Context(), userID(r))
	if err != nil {
		writeErr(w, http.StatusUnauthorized, "account not found")
		return
	}
	devices, err := s.Store.DevicesForUser(r.Context(), u.ID)
	if err != nil {
		s.Log.Error("list devices", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"id":           u.ID,
		"email":        u.Email.String,
		"device_count": len(devices),
		"device_limit": store.MaxDevicesPerUser,
	})
}

// --- devices ---

type deviceJSON struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	PublicKey  string `json:"public_key"`
	AssignedIP string `json:"assigned_ip"`
}

func (s *Server) handleListDevices(w http.ResponseWriter, r *http.Request) {
	devices, err := s.Store.DevicesForUser(r.Context(), userID(r))
	if err != nil {
		s.Log.Error("list devices", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error")
		return
	}
	out := make([]deviceJSON, 0, len(devices))
	for _, d := range devices {
		out = append(out, deviceJSON{ID: d.ID, Name: d.Name, PublicKey: d.PublicKey, AssignedIP: d.AssignedIP})
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": out})
}

// handleCreateDevice registers a device's WireGuard public key and returns
// per-server peer configuration. The private key never leaves the device.
func (s *Server) handleCreateDevice(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name      string `json:"name"`
		PublicKey string `json:"public_key"`
	}
	if err := decode(r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if req.Name == "" {
		req.Name = "iOS device"
	}
	if err := wg.ValidatePublicKey(req.PublicKey); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	d, err := s.Store.CreateDevice(r.Context(), userID(r), req.Name, req.PublicKey)
	switch {
	case errors.Is(err, store.ErrDeviceLimit):
		writeErr(w, http.StatusForbidden, "device limit reached — remove a device first")
		return
	case errors.Is(err, store.ErrConflict):
		writeErr(w, http.StatusConflict, "that public key is already registered")
		return
	case err != nil:
		s.Log.Error("create device", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"device":      deviceJSON{ID: d.ID, Name: d.Name, PublicKey: d.PublicKey, AssignedIP: d.AssignedIP},
		"dns":         wg.DefaultDNS,
		"allowed_ips": wg.DefaultAllowedIPs,
	})
}

func (s *Server) handleDeleteDevice(w http.ResponseWriter, r *http.Request) {
	err := s.Store.DeleteDevice(r.Context(), userID(r), r.PathValue("id"))
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "device not found")
		return
	}
	if err != nil {
		s.Log.Error("delete device", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
