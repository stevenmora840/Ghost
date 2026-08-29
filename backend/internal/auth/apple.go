package auth

import (
	"context"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const appleJWKSURL = "https://appleid.apple.com/auth/keys"
const appleIssuer = "https://appleid.apple.com"

// AppleVerifier validates Sign in with Apple identity tokens against Apple's
// published JWKS. Keyfunc is swappable so tests can sign with their own keys.
type AppleVerifier struct {
	BundleID string
	Keyfunc  jwt.Keyfunc // defaults to JWKS-backed lookup

	mu      sync.Mutex
	keys    map[string]*rsa.PublicKey
	fetched time.Time
	client  *http.Client
}

type AppleIdentity struct {
	Subject string // stable per-user-per-team identifier
	Email   string // may be empty or a private relay address
}

func NewAppleVerifier(bundleID string) *AppleVerifier {
	v := &AppleVerifier{
		BundleID: bundleID,
		client:   &http.Client{Timeout: 10 * time.Second},
	}
	v.Keyfunc = v.jwksKeyfunc
	return v
}

func (v *AppleVerifier) Verify(ctx context.Context, identityToken string) (*AppleIdentity, error) {
	claims := jwt.MapClaims{}
	_, err := jwt.ParseWithClaims(identityToken, claims, v.Keyfunc,
		jwt.WithIssuer(appleIssuer),
		jwt.WithAudience(v.BundleID),
		jwt.WithExpirationRequired(),
		jwt.WithValidMethods([]string{"RS256"}))
	if err != nil {
		return nil, fmt.Errorf("apple identity token: %w", err)
	}
	sub, _ := claims["sub"].(string)
	if sub == "" {
		return nil, errors.New("apple identity token: missing sub")
	}
	email, _ := claims["email"].(string)
	return &AppleIdentity{Subject: sub, Email: email}, nil
}

func (v *AppleVerifier) jwksKeyfunc(token *jwt.Token) (any, error) {
	kid, _ := token.Header["kid"].(string)
	if kid == "" {
		return nil, errors.New("missing kid header")
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	if key, ok := v.keys[kid]; ok && time.Since(v.fetched) < 24*time.Hour {
		return key, nil
	}
	if err := v.refreshKeysLocked(); err != nil {
		return nil, err
	}
	key, ok := v.keys[kid]
	if !ok {
		return nil, fmt.Errorf("unknown apple key id %q", kid)
	}
	return key, nil
}

func (v *AppleVerifier) refreshKeysLocked() error {
	req, err := http.NewRequestWithContext(context.Background(), http.MethodGet, appleJWKSURL, nil)
	if err != nil {
		return err
	}
	resp, err := v.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("apple jwks: status %d", resp.StatusCode)
	}
	var body struct {
		Keys []struct {
			Kid string `json:"kid"`
			N   string `json:"n"`
			E   string `json:"e"`
		} `json:"keys"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return err
	}
	keys := make(map[string]*rsa.PublicKey, len(body.Keys))
	for _, k := range body.Keys {
		nBytes, err := base64.RawURLEncoding.DecodeString(k.N)
		if err != nil {
			continue
		}
		eBytes, err := base64.RawURLEncoding.DecodeString(k.E)
		if err != nil {
			continue
		}
		keys[k.Kid] = &rsa.PublicKey{
			N: new(big.Int).SetBytes(nBytes),
			E: int(new(big.Int).SetBytes(eBytes).Int64()),
		}
	}
	v.keys = keys
	v.fetched = time.Now()
	return nil
}
