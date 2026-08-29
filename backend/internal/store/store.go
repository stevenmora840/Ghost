// Package store is Ghost's persistence layer.
//
// Data-flow constraint (see docs/vpn-infrastructure.md): this schema holds
// account and device records only. There are deliberately no tables for
// connection events, traffic, timestamps of tunnel activity, or client IPs —
// the control plane must be structurally unable to correlate an account with
// browsing activity.
package store

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

var (
	ErrNotFound      = errors.New("not found")
	ErrConflict      = errors.New("conflict")
	ErrDeviceLimit   = errors.New("device limit reached")
	ErrIPPoolDrained = errors.New("ip pool exhausted")
	ErrTierRequired  = errors.New("paid tier required")
	ErrInvalidChain  = errors.New("invalid multi-hop chain")
)

// MaxDevicesPerUser matches the P0 device-limit decision in
// docs/vpn-features-priorities.md.
const MaxDevicesPerUser = 10

// Multi-hop chains are bounded: two hops is the common case, three is the
// practical ceiling before latency makes the tunnel unpleasant.
const (
	MinChainHops = 2
	MaxChainHops = 3
)

// Tier gates the premium features in docs/vpn-premium-features.md. Dedicated
// IPs and DNS filtering are free; priority servers, panic wipe and custom
// multi-hop chains require Paid.
type Tier string

const (
	TierFree Tier = "free"
	TierPaid Tier = "paid"
)

func (t Tier) IsPaid() bool { return t == TierPaid }

type User struct {
	ID           string
	Email        sql.NullString
	PasswordHash sql.NullString
	AppleSub     sql.NullString
	Tier         Tier
	DNSFilter    DNSFilter
	CreatedAt    time.Time
}

// DNSFilter is the per-account DNS-level blocking preference. Ghost runs its
// own resolvers (docs/vpn-infrastructure.md), so filtering is a blocklist on
// resolvers that exist anyway — no new user data is collected to provide it.
type DNSFilter struct {
	BlockAds      bool
	BlockMalware  bool
	BlockTrackers bool
}

func (f DNSFilter) Any() bool { return f.BlockAds || f.BlockMalware || f.BlockTrackers }

// DedicatedIP is a public exit address reserved to one account, rather than
// shared across everyone on a server.
type DedicatedIP struct {
	IP       string
	ServerID string
	UserID   string
}

type Device struct {
	ID         string
	UserID     string
	Name       string
	PublicKey  string
	AssignedIP string
	CreatedAt  time.Time
}

type Server struct {
	ID          string
	City        string
	Country     string
	CountryCode string
	Endpoint    string
	PublicKey   string
	LoadPct     int
	Audited     bool
	// Priority servers are a low-load pool reserved for paid accounts.
	Priority bool
}

type Store struct {
	db *sql.DB
}

func Open(path string) (*Store, error) {
	db, err := sql.Open("sqlite", path+"?_pragma=journal_mode(WAL)&_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)")
	if err != nil {
		return nil, err
	}
	// modernc sqlite is single-writer; serialize access.
	db.SetMaxOpenConns(1)
	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) migrate() error {
	_, err := s.db.Exec(`
CREATE TABLE IF NOT EXISTS users (
	id            TEXT PRIMARY KEY,
	email         TEXT UNIQUE,
	password_hash TEXT,
	apple_sub     TEXT UNIQUE,
	tier          TEXT NOT NULL DEFAULT 'free',
	dns_ads       INTEGER NOT NULL DEFAULT 0,
	dns_malware   INTEGER NOT NULL DEFAULT 0,
	dns_trackers  INTEGER NOT NULL DEFAULT 0,
	created_at    INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS devices (
	id          TEXT PRIMARY KEY,
	user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	name        TEXT NOT NULL,
	public_key  TEXT NOT NULL UNIQUE,
	assigned_ip TEXT NOT NULL UNIQUE,
	created_at  INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS refresh_tokens (
	token_hash TEXT PRIMARY KEY,
	user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	expires_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS ip_alloc (
	n          INTEGER PRIMARY KEY AUTOINCREMENT,
	device_id  TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS servers (
	id           TEXT PRIMARY KEY,
	city         TEXT NOT NULL,
	country      TEXT NOT NULL,
	country_code TEXT NOT NULL,
	endpoint     TEXT NOT NULL,
	public_key   TEXT NOT NULL,
	load_pct     INTEGER NOT NULL DEFAULT 0,
	audited      INTEGER NOT NULL DEFAULT 0,
	priority     INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS dedicated_ips (
	ip           TEXT PRIMARY KEY,
	server_id    TEXT NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
	user_id      TEXT REFERENCES users(id) ON DELETE SET NULL,
	allocated_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_dedicated_ips_user ON dedicated_ips(user_id);
CREATE TABLE IF NOT EXISTS multihop_chains (
	user_id   TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	position  INTEGER NOT NULL,
	server_id TEXT NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
	PRIMARY KEY (user_id, position)
);`)
	if err != nil {
		return err
	}
	// Bring older development databases forward. SQLite has no
	// ADD COLUMN IF NOT EXISTS, so a duplicate-column error means the
	// column is already there and is not a failure.
	for _, stmt := range []string{
		`ALTER TABLE users ADD COLUMN tier TEXT NOT NULL DEFAULT 'free'`,
		`ALTER TABLE users ADD COLUMN dns_ads INTEGER NOT NULL DEFAULT 0`,
		`ALTER TABLE users ADD COLUMN dns_malware INTEGER NOT NULL DEFAULT 0`,
		`ALTER TABLE users ADD COLUMN dns_trackers INTEGER NOT NULL DEFAULT 0`,
		`ALTER TABLE servers ADD COLUMN priority INTEGER NOT NULL DEFAULT 0`,
	} {
		if _, err := s.db.Exec(stmt); err != nil && !strings.Contains(err.Error(), "duplicate column") {
			return err
		}
	}
	return nil
}

func NewID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err) // crypto/rand failure is unrecoverable
	}
	return hex.EncodeToString(b)
}

// --- users ---

func (s *Store) CreateEmailUser(ctx context.Context, email, passwordHash string) (*User, error) {
	u := &User{ID: NewID(), Tier: TierFree, CreatedAt: time.Now().UTC()}
	u.Email = sql.NullString{String: email, Valid: true}
	u.PasswordHash = sql.NullString{String: passwordHash, Valid: true}
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO users (id, email, password_hash, created_at) VALUES (?, ?, ?, ?)`,
		u.ID, email, passwordHash, u.CreatedAt.Unix())
	if err != nil {
		if isUniqueErr(err) {
			return nil, ErrConflict
		}
		return nil, err
	}
	return u, nil
}

// UpsertAppleUser finds a user by Apple subject, creating one on first sign-in.
func (s *Store) UpsertAppleUser(ctx context.Context, appleSub, email string) (*User, error) {
	if u, err := s.userByWhere(ctx, "apple_sub = ?", appleSub); err == nil {
		return u, nil
	} else if !errors.Is(err, ErrNotFound) {
		return nil, err
	}
	u := &User{ID: NewID(), Tier: TierFree, CreatedAt: time.Now().UTC()}
	u.AppleSub = sql.NullString{String: appleSub, Valid: true}
	var emailVal any
	if email != "" {
		u.Email = sql.NullString{String: email, Valid: true}
		emailVal = email
	}
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO users (id, email, apple_sub, created_at) VALUES (?, ?, ?, ?)`,
		u.ID, emailVal, appleSub, u.CreatedAt.Unix())
	if err != nil {
		return nil, err
	}
	return u, nil
}

func (s *Store) UserByEmail(ctx context.Context, email string) (*User, error) {
	return s.userByWhere(ctx, "email = ?", email)
}

func (s *Store) UserByID(ctx context.Context, id string) (*User, error) {
	return s.userByWhere(ctx, "id = ?", id)
}

func (s *Store) userByWhere(ctx context.Context, where string, arg any) (*User, error) {
	u := &User{}
	var created int64
	var tier string
	var ads, malware, trackers int
	err := s.db.QueryRowContext(ctx,
		`SELECT id, email, password_hash, apple_sub, tier, dns_ads, dns_malware, dns_trackers, created_at
		 FROM users WHERE `+where, arg).
		Scan(&u.ID, &u.Email, &u.PasswordHash, &u.AppleSub, &tier, &ads, &malware, &trackers, &created)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	u.Tier = Tier(tier)
	u.DNSFilter = DNSFilter{BlockAds: ads != 0, BlockMalware: malware != 0, BlockTrackers: trackers != 0}
	u.CreatedAt = time.Unix(created, 0).UTC()
	return u, nil
}

// SetTier changes an account's tier. Billing is not built yet; this is the
// seam a payment webhook will call.
func (s *Store) SetTier(ctx context.Context, userID string, tier Tier) error {
	res, err := s.db.ExecContext(ctx, `UPDATE users SET tier = ? WHERE id = ?`, string(tier), userID)
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Store) SetDNSFilter(ctx context.Context, userID string, f DNSFilter) error {
	res, err := s.db.ExecContext(ctx,
		`UPDATE users SET dns_ads = ?, dns_malware = ?, dns_trackers = ? WHERE id = ?`,
		boolInt(f.BlockAds), boolInt(f.BlockMalware), boolInt(f.BlockTrackers), userID)
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// --- refresh tokens ---

func (s *Store) SaveRefreshToken(ctx context.Context, tokenHash, userID string, expires time.Time) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO refresh_tokens (token_hash, user_id, expires_at) VALUES (?, ?, ?)`,
		tokenHash, userID, expires.Unix())
	return err
}

// ConsumeRefreshToken deletes and returns the owning user ID (rotation: each
// refresh token is single-use).
func (s *Store) ConsumeRefreshToken(ctx context.Context, tokenHash string) (string, error) {
	var userID string
	var expires int64
	err := s.db.QueryRowContext(ctx,
		`SELECT user_id, expires_at FROM refresh_tokens WHERE token_hash = ?`, tokenHash).
		Scan(&userID, &expires)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", err
	}
	if _, err := s.db.ExecContext(ctx, `DELETE FROM refresh_tokens WHERE token_hash = ?`, tokenHash); err != nil {
		return "", err
	}
	if time.Now().Unix() > expires {
		return "", ErrNotFound
	}
	return userID, nil
}

// --- devices ---

func (s *Store) CreateDevice(ctx context.Context, userID, name, publicKey string) (*Device, error) {
	var count int
	if err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM devices WHERE user_id = ?`, userID).Scan(&count); err != nil {
		return nil, err
	}
	if count >= MaxDevicesPerUser {
		return nil, ErrDeviceLimit
	}

	d := &Device{ID: NewID(), UserID: userID, Name: name, PublicKey: publicKey, CreatedAt: time.Now().UTC()}

	res, err := s.db.ExecContext(ctx, `INSERT INTO ip_alloc (device_id) VALUES (?)`, d.ID)
	if err != nil {
		return nil, err
	}
	n, err := res.LastInsertId()
	if err != nil {
		return nil, err
	}
	// Tunnel addresses come from 10.64.0.0/16: .0.x is reserved, giving
	// 254*255 assignable /32s before the pool drains.
	hi, lo := n/254+1, n%254+1
	if hi > 255 {
		return nil, ErrIPPoolDrained
	}
	d.AssignedIP = fmt.Sprintf("10.64.%d.%d", hi, lo)

	_, err = s.db.ExecContext(ctx,
		`INSERT INTO devices (id, user_id, name, public_key, assigned_ip, created_at) VALUES (?, ?, ?, ?, ?, ?)`,
		d.ID, d.UserID, d.Name, d.PublicKey, d.AssignedIP, d.CreatedAt.Unix())
	if err != nil {
		if isUniqueErr(err) {
			return nil, ErrConflict
		}
		return nil, err
	}
	return d, nil
}

func (s *Store) DevicesForUser(ctx context.Context, userID string) ([]Device, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, user_id, name, public_key, assigned_ip, created_at FROM devices WHERE user_id = ? ORDER BY created_at`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Device
	for rows.Next() {
		var d Device
		var created int64
		if err := rows.Scan(&d.ID, &d.UserID, &d.Name, &d.PublicKey, &d.AssignedIP, &created); err != nil {
			return nil, err
		}
		d.CreatedAt = time.Unix(created, 0).UTC()
		out = append(out, d)
	}
	return out, rows.Err()
}

func (s *Store) DeleteDevice(ctx context.Context, userID, deviceID string) error {
	res, err := s.db.ExecContext(ctx,
		`DELETE FROM devices WHERE id = ? AND user_id = ?`, deviceID, userID)
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// --- servers ---

func (s *Store) UpsertServer(ctx context.Context, sv Server) error {
	_, err := s.db.ExecContext(ctx, `
INSERT INTO servers (id, city, country, country_code, endpoint, public_key, load_pct, audited, priority)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
	city = excluded.city, country = excluded.country, country_code = excluded.country_code,
	endpoint = excluded.endpoint, public_key = excluded.public_key,
	load_pct = excluded.load_pct, audited = excluded.audited, priority = excluded.priority`,
		sv.ID, sv.City, sv.Country, sv.CountryCode, sv.Endpoint, sv.PublicKey,
		sv.LoadPct, boolInt(sv.Audited), boolInt(sv.Priority))
	return err
}

const serverCols = `id, city, country, country_code, endpoint, public_key, load_pct, audited, priority`

func scanServer(sc interface{ Scan(...any) error }) (Server, error) {
	var sv Server
	var audited, priority int
	err := sc.Scan(&sv.ID, &sv.City, &sv.Country, &sv.CountryCode, &sv.Endpoint,
		&sv.PublicKey, &sv.LoadPct, &audited, &priority)
	sv.Audited = audited != 0
	sv.Priority = priority != 0
	return sv, err
}

func (s *Store) Servers(ctx context.Context) ([]Server, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT `+serverCols+` FROM servers ORDER BY load_pct`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Server
	for rows.Next() {
		sv, err := scanServer(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, sv)
	}
	return out, rows.Err()
}

func (s *Store) ServerByID(ctx context.Context, id string) (*Server, error) {
	sv, err := scanServer(s.db.QueryRowContext(ctx, `SELECT `+serverCols+` FROM servers WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &sv, nil
}

// --- dedicated exit IPs (free tier) ---

// AddDedicatedIPToPool registers an unallocated exit address for a server.
func (s *Store) AddDedicatedIPToPool(ctx context.Context, ip, serverID string) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO dedicated_ips (ip, server_id) VALUES (?, ?) ON CONFLICT(ip) DO NOTHING`, ip, serverID)
	return err
}

func (s *Store) DedicatedIPForUser(ctx context.Context, userID string) (*DedicatedIP, error) {
	var d DedicatedIP
	err := s.db.QueryRowContext(ctx,
		`SELECT ip, server_id, user_id FROM dedicated_ips WHERE user_id = ?`, userID).
		Scan(&d.IP, &d.ServerID, &d.UserID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &d, nil
}

// AllocateDedicatedIP reserves a free address on serverID for the user. One
// address per account: an existing allocation is returned unchanged, even on
// another server, so callers release first to move location.
func (s *Store) AllocateDedicatedIP(ctx context.Context, userID, serverID string) (*DedicatedIP, error) {
	if existing, err := s.DedicatedIPForUser(ctx, userID); err == nil {
		return existing, nil
	} else if !errors.Is(err, ErrNotFound) {
		return nil, err
	}

	// Claim-then-verify: the conditional UPDATE is what makes the grab safe,
	// so a racing caller re-reads instead of taking the same address.
	for attempts := 0; attempts < 5; attempts++ {
		var ip string
		err := s.db.QueryRowContext(ctx,
			`SELECT ip FROM dedicated_ips WHERE server_id = ? AND user_id IS NULL ORDER BY ip LIMIT 1`, serverID).
			Scan(&ip)
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrIPPoolDrained
		}
		if err != nil {
			return nil, err
		}
		res, err := s.db.ExecContext(ctx,
			`UPDATE dedicated_ips SET user_id = ?, allocated_at = ? WHERE ip = ? AND user_id IS NULL`,
			userID, time.Now().UTC().Unix(), ip)
		if err != nil {
			return nil, err
		}
		if n, err := res.RowsAffected(); err != nil {
			return nil, err
		} else if n == 1 {
			return &DedicatedIP{IP: ip, ServerID: serverID, UserID: userID}, nil
		}
	}
	return nil, ErrIPPoolDrained
}

func (s *Store) ReleaseDedicatedIP(ctx context.Context, userID string) error {
	res, err := s.db.ExecContext(ctx,
		`UPDATE dedicated_ips SET user_id = NULL, allocated_at = NULL WHERE user_id = ?`, userID)
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// --- multi-hop chains (paid tier) ---

// MultiHopChain returns the user's ordered server IDs, or nil when unset.
func (s *Store) MultiHopChain(ctx context.Context, userID string) ([]string, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT server_id FROM multihop_chains WHERE user_id = ? ORDER BY position`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

// SetMultiHopChain replaces the user's chain. Server IDs must exist and be
// distinct; length is bounded by Min/MaxChainHops.
func (s *Store) SetMultiHopChain(ctx context.Context, userID string, serverIDs []string) error {
	if len(serverIDs) < MinChainHops || len(serverIDs) > MaxChainHops {
		return ErrInvalidChain
	}
	seen := map[string]bool{}
	for _, id := range serverIDs {
		if seen[id] {
			return ErrInvalidChain
		}
		seen[id] = true
		if _, err := s.ServerByID(ctx, id); err != nil {
			return ErrInvalidChain
		}
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `DELETE FROM multihop_chains WHERE user_id = ?`, userID); err != nil {
		return err
	}
	for i, id := range serverIDs {
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO multihop_chains (user_id, position, server_id) VALUES (?, ?, ?)`,
			userID, i, id); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (s *Store) ClearMultiHopChain(ctx context.Context, userID string) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM multihop_chains WHERE user_id = ?`, userID)
	return err
}

// --- panic wipe (paid tier) ---

// PanicWipe revokes everything tied to an account's current identity:
// devices (and their tunnel addresses), all refresh tokens, the dedicated IP
// allocation, and the multi-hop chain. The account itself survives so the
// user can immediately re-provision a fresh identity.
func (s *Store) PanicWipe(ctx context.Context, userID string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, stmt := range []string{
		`DELETE FROM devices WHERE user_id = ?`,
		`DELETE FROM refresh_tokens WHERE user_id = ?`,
		`DELETE FROM multihop_chains WHERE user_id = ?`,
		`UPDATE dedicated_ips SET user_id = NULL, allocated_at = NULL WHERE user_id = ?`,
	} {
		if _, err := tx.ExecContext(ctx, stmt, userID); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

func isUniqueErr(err error) bool {
	return err != nil && strings.Contains(err.Error(), "constraint failed")
}
