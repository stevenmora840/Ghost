// Package api is Ghost's HTTP control plane.
//
// Logging note: handlers never log client IPs, tokens, or request bodies —
// only route-level errors. This is part of the no-logs data-flow constraint,
// not an optimization.
package api

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"

	"github.com/stevenmora840/ghost/backend/internal/auth"
	"github.com/stevenmora840/ghost/backend/internal/store"
)

type Server struct {
	Store  *store.Store
	Tokens *auth.Tokens
	Apple  *auth.AppleVerifier
	Log    *slog.Logger
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/health", s.handleHealth)

	mux.HandleFunc("POST /v1/auth/register", s.handleRegister)
	mux.HandleFunc("POST /v1/auth/login", s.handleLogin)
	mux.HandleFunc("POST /v1/auth/apple", s.handleAppleSignIn)
	mux.HandleFunc("POST /v1/auth/refresh", s.handleRefresh)

	mux.HandleFunc("GET /v1/servers", s.requireAuth(s.handleListServers))
	mux.HandleFunc("GET /v1/account", s.requireAuth(s.handleAccount))
	mux.HandleFunc("GET /v1/devices", s.requireAuth(s.handleListDevices))
	mux.HandleFunc("POST /v1/devices", s.requireAuth(s.handleCreateDevice))
	mux.HandleFunc("DELETE /v1/devices/{id}", s.requireAuth(s.handleDeleteDevice))
	return mux
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// --- auth middleware ---

type ctxKey int

const userIDKey ctxKey = 0

func (s *Server) requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		header := r.Header.Get("Authorization")
		token, ok := strings.CutPrefix(header, "Bearer ")
		if !ok || token == "" {
			writeErr(w, http.StatusUnauthorized, "missing bearer token")
			return
		}
		userID, err := s.Tokens.VerifyAccess(token)
		if err != nil {
			writeErr(w, http.StatusUnauthorized, "invalid or expired token")
			return
		}
		next(w, r.WithContext(context.WithValue(r.Context(), userIDKey, userID)))
	}
}

func userID(r *http.Request) string {
	id, _ := r.Context().Value(userIDKey).(string)
	return id
}

// --- helpers ---

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func decode[T any](r *http.Request, into *T) error {
	dec := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 1<<20))
	dec.DisallowUnknownFields()
	return dec.Decode(into)
}
