// Package wg holds WireGuard key handling for config issuance. The client
// generates its own keypair on-device and sends only the public key — the
// control plane never sees or stores private keys.
package wg

import (
	"crypto/rand"
	"encoding/base64"
	"errors"

	"golang.org/x/crypto/curve25519"
)

// ValidatePublicKey checks that s is a well-formed WireGuard public key
// (32 bytes, base64 standard encoding).
func ValidatePublicKey(s string) error {
	raw, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		return errors.New("public key is not valid base64")
	}
	if len(raw) != 32 {
		return errors.New("public key must decode to 32 bytes")
	}
	return nil
}

// GenerateKeypair returns a new (privateKey, publicKey) pair, base64-encoded.
// Used for seeding development servers; production PoP keys are provisioned
// on the PoPs themselves.
func GenerateKeypair() (string, string, error) {
	priv := make([]byte, 32)
	if _, err := rand.Read(priv); err != nil {
		return "", "", err
	}
	// Clamp per curve25519 convention.
	priv[0] &= 248
	priv[31] &= 127
	priv[31] |= 64
	pub, err := curve25519.X25519(priv, curve25519.Basepoint)
	if err != nil {
		return "", "", err
	}
	return base64.StdEncoding.EncodeToString(priv), base64.StdEncoding.EncodeToString(pub), nil
}

// PeerConfig is everything a client needs to bring up a tunnel to one server,
// beyond its own private key.
type PeerConfig struct {
	ServerPublicKey string   `json:"server_public_key"`
	Endpoint        string   `json:"endpoint"`
	AssignedIP      string   `json:"assigned_ip"` // client tunnel address, /32
	DNS             []string `json:"dns"`
	AllowedIPs      []string `json:"allowed_ips"`
}

// DefaultDNS is Ghost's own resolver address inside the tunnel (per
// docs/vpn-infrastructure.md: VPN-operated DNS so queries never leak).
var DefaultDNS = []string{"10.64.0.1"}

// Filtering resolvers. Each address is a Ghost resolver running a different
// blocklist set; the client is handed the address matching its preferences,
// so filtering costs one config field rather than any query logging.
const (
	ResolverPlain      = "10.64.0.1" // no filtering
	ResolverMalware    = "10.64.0.2" // malware/phishing
	ResolverAds        = "10.64.0.3" // ads + malware
	ResolverTrackers   = "10.64.0.4" // trackers + malware
	ResolverEverything = "10.64.0.5" // ads + trackers + malware
)

// ResolverFor maps blocking preferences to the resolver that serves them.
// Malware blocking is implied by any other category — there is no resolver
// that blocks ads while resolving known-malicious domains.
func ResolverFor(blockAds, blockMalware, blockTrackers bool) []string {
	switch {
	case blockAds && blockTrackers:
		return []string{ResolverEverything}
	case blockAds:
		return []string{ResolverAds}
	case blockTrackers:
		return []string{ResolverTrackers}
	case blockMalware:
		return []string{ResolverMalware}
	default:
		return []string{ResolverPlain}
	}
}

// DefaultAllowedIPs routes all traffic through the tunnel; the client's kill
// switch and IPv6 blocking build on this.
var DefaultAllowedIPs = []string{"0.0.0.0/0", "::/0"}
