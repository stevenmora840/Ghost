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
)

// MaxDevicesPerUser matches the P0 device-limit decision in
// docs/vpn-features-priorities.md.
const MaxDevicesPerUser = 10

type User struct {
	ID           string
	Email        sql.NullString
	PasswordHash sql.NullString
	AppleSub     sql.NullString
	CreatedAt    time.Time
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
	audited      INTEGER NOT NULL DEFAULT 0
);`)
	return err
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
	u := &User{ID: NewID(), CreatedAt: time.Now().UTC()}
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
	u := &User{ID: NewID(), CreatedAt: time.Now().UTC()}
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
	err := s.db.QueryRowContext(ctx,
		`SELECT id, email, password_hash, apple_sub, created_at FROM users WHERE `+where, arg).
		Scan(&u.ID, &u.Email, &u.PasswordHash, &u.AppleSub, &created)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	u.CreatedAt = time.Unix(created, 0).UTC()
	return u, nil
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
INSERT INTO servers (id, city, country, country_code, endpoint, public_key, load_pct, audited)
VALUES (?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
	city = excluded.city, country = excluded.country, country_code = excluded.country_code,
	endpoint = excluded.endpoint, public_key = excluded.public_key,
	load_pct = excluded.load_pct, audited = excluded.audited`,
		sv.ID, sv.City, sv.Country, sv.CountryCode, sv.Endpoint, sv.PublicKey, sv.LoadPct, boolInt(sv.Audited))
	return err
}

func (s *Store) Servers(ctx context.Context) ([]Server, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, city, country, country_code, endpoint, public_key, load_pct, audited FROM servers ORDER BY load_pct`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Server
	for rows.Next() {
		var sv Server
		var audited int
		if err := rows.Scan(&sv.ID, &sv.City, &sv.Country, &sv.CountryCode, &sv.Endpoint, &sv.PublicKey, &sv.LoadPct, &audited); err != nil {
			return nil, err
		}
		sv.Audited = audited != 0
		out = append(out, sv)
	}
	return out, rows.Err()
}

func (s *Store) ServerByID(ctx context.Context, id string) (*Server, error) {
	var sv Server
	var audited int
	err := s.db.QueryRowContext(ctx,
		`SELECT id, city, country, country_code, endpoint, public_key, load_pct, audited FROM servers WHERE id = ?`, id).
		Scan(&sv.ID, &sv.City, &sv.Country, &sv.CountryCode, &sv.Endpoint, &sv.PublicKey, &sv.LoadPct, &audited)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	sv.Audited = audited != 0
	return &sv, nil
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
