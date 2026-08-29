package api

import (
	"errors"
	"net/http"
	"net/mail"
	"time"

	"github.com/stevenmora840/ghost/backend/internal/auth"
	"github.com/stevenmora840/ghost/backend/internal/store"
)

type tokenPair struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresIn    int    `json:"expires_in"` // access token lifetime, seconds
}

func (s *Server) issueTokens(w http.ResponseWriter, r *http.Request, uid string) {
	access, err := s.Tokens.IssueAccess(uid)
	if err != nil {
		s.Log.Error("issue access token", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error")
		return
	}
	refresh, hash, err := auth.NewRefreshToken()
	if err != nil {
		s.Log.Error("issue refresh token", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error")
		return
	}
	if err := s.Store.SaveRefreshToken(r.Context(), hash, uid, time.Now().Add(auth.RefreshTokenTTL)); err != nil {
		s.Log.Error("save refresh token", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error")
		return
	}
	writeJSON(w, http.StatusOK, tokenPair{
		AccessToken:  access,
		RefreshToken: refresh,
		ExpiresIn:    int(auth.AccessTokenTTL.Seconds()),
	})
}

func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	if err := decode(r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if _, err := mail.ParseAddress(req.Email); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid email address")
		return
	}
	if len(req.Password) < 10 {
		writeErr(w, http.StatusBadRequest, "password must be at least 10 characters")
		return
	}
	hash, err := auth.HashPassword(req.Password)
	if err != nil {
		s.Log.Error("hash password", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error")
		return
	}
	u, err := s.Store.CreateEmailUser(r.Context(), req.Email, hash)
	if errors.Is(err, store.ErrConflict) {
		writeErr(w, http.StatusConflict, "an account with that email already exists")
		return
	}
	if err != nil {
		s.Log.Error("create user", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error")
		return
	}
	s.issueTokens(w, r, u.ID)
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	if err := decode(r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid request body")
		return
	}
	u, err := s.Store.UserByEmail(r.Context(), req.Email)
	if errors.Is(err, store.ErrNotFound) || (err == nil && !u.PasswordHash.Valid) {
		writeErr(w, http.StatusUnauthorized, "invalid email or password")
		return
	}
	if err != nil {
		s.Log.Error("lookup user", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error")
		return
	}
	ok, err := auth.VerifyPassword(req.Password, u.PasswordHash.String)
	if err != nil || !ok {
		writeErr(w, http.StatusUnauthorized, "invalid email or password")
		return
	}
	s.issueTokens(w, r, u.ID)
}

func (s *Server) handleAppleSignIn(w http.ResponseWriter, r *http.Request) {
	var req struct {
		IdentityToken string `json:"identity_token"`
	}
	if err := decode(r, &req); err != nil || req.IdentityToken == "" {
		writeErr(w, http.StatusBadRequest, "invalid request body")
		return
	}
	ident, err := s.Apple.Verify(r.Context(), req.IdentityToken)
	if err != nil {
		writeErr(w, http.StatusUnauthorized, "invalid Apple identity token")
		return
	}
	u, err := s.Store.UpsertAppleUser(r.Context(), ident.Subject, ident.Email)
	if err != nil {
		s.Log.Error("upsert apple user", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error")
		return
	}
	s.issueTokens(w, r, u.ID)
}

func (s *Server) handleRefresh(w http.ResponseWriter, r *http.Request) {
	var req struct {
		RefreshToken string `json:"refresh_token"`
	}
	if err := decode(r, &req); err != nil || req.RefreshToken == "" {
		writeErr(w, http.StatusBadRequest, "invalid request body")
		return
	}
	uid, err := s.Store.ConsumeRefreshToken(r.Context(), auth.HashRefreshToken(req.RefreshToken))
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusUnauthorized, "invalid or expired refresh token")
		return
	}
	if err != nil {
		s.Log.Error("consume refresh token", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error")
		return
	}
	s.issueTokens(w, r, uid)
}
